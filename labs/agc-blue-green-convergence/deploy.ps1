#Requires -Version 7.0
<#
============================================================================
  Deploy the AGC "sub-second convergence" lab (Managed-by-ALB).
  PowerShell variant of deploy.sh.

  Bicep (main.bicep) stands up AKS + the managed identity + federation.
  This wrapper does the imperative steps AGC Managed mode requires:
    1. add a delegated `subnet-alb` to the AKS-managed VNet
    2. assign the controller identity its 3 roles
    3. install the ALB controller via Helm
    4. apply the Gateway API objects (AGC, app, Gateway, weighted HTTPRoute)
    5. wait for everything to go Programmed and print the demo instructions

  Usage:
    ./deploy.ps1
    ./deploy.ps1 -Location westeurope
    $env:LOCATION='westeurope'; ./deploy.ps1

  Requires: az, kubectl, helm. (Unlike deploy.sh this does NOT need envsubst —
  the manifest substitution is done natively in PowerShell.)
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg                   = ($env:RG                     ?? 'rg-agc-convergence-lab'),
  [string]$Location             = ($env:LOCATION               ?? 'northeurope'),        # must be an AGC-supported region
  [string]$AksName              = ($env:AKS_NAME               ?? 'aks-agc-lab'),
  [string]$AlbIdentityName      = ($env:ALB_IDENTITY_NAME      ?? 'azure-alb-identity'),
  [string]$AlbSubnetName        = ($env:ALB_SUBNET_NAME        ?? 'subnet-alb'),
  [string]$AlbSubnetPrefix      = ($env:ALB_SUBNET_PREFIX      ?? '10.225.0.0/24'),      # inside the AKS-managed VNet (10.224.0.0/12)
  [string]$AlbControllerVersion = ($env:ALB_CONTROLLER_VERSION ?? '1.10.28'),
  [string]$HelmNamespace        = ($env:HELM_NAMESPACE         ?? 'azure-alb-system')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Helpers --------------------------------------------------------------
# Plain functions using $args (NOT advanced) so `-o`/`-g`/`-e` pass through to az.
function Invoke-AzNone {
  & az @args; if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
}
function Invoke-AzOut {
  $out = & az @args; if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }; return $out
}
function ConvertTo-IpInt { param([string]$Ip)
  $o = $Ip.Split('.'); return ([uint32]$o[0] -shl 24) -bor ([uint32]$o[1] -shl 16) -bor ([uint32]$o[2] -shl 8) -bor [uint32]$o[3]
}
function Test-InCidr { param([string]$Ip,[string]$Cidr)  # true if $Ip is inside $Cidr
  $net,$bits = $Cidr.Split('/'); $bits = [int]$bits
  $mask = if ($bits -eq 0) { [uint32]0 } else { [uint32]((0xFFFFFFFFL -shl (32 - $bits)) -band 0xFFFFFFFFL) }
  return (((ConvertTo-IpInt $Ip) -band $mask) -eq ((ConvertTo-IpInt $net) -band $mask))
}

$ControllerNamespace = 'azure-alb-system'   # must match the federated-credential subject in main.bicep
$ScriptDir  = $PSScriptRoot
$DeployName = "agc-convergence-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

# Built-in role definition IDs (stable GUIDs — same in every tenant)
$RoleReader             = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
$RoleAgcConfigManager   = 'fbc52c3f-28ad-4303-a892-8a056630b8f1'   # AppGw for Containers Configuration Manager
$RoleNetworkContributor = '4d97b98b-1d4f-4787-a291-c67834d212e7'

# ---- Prereqs --------------------------------------------------------------

# Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI not found. Install the Azure CLI first."
    exit 1
}

# kubectl
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error "kubectl not found. Install kubectl first (for example: 'az aks install-cli')."
    exit 1
}

# Helm
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {

    Write-Host "Helm not found. Installing Helm via Winget..." -ForegroundColor Yellow

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Error "Winget is not available. Please install Helm manually."
        exit 1
    }

    & winget install Helm.Helm `
        --accept-package-agreements `
        --accept-source-agreements `

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Helm installation failed."
        exit 1
    }

    # Refresh PATH in the current PowerShell session
    $env:PATH = (
        [System.Environment]::GetEnvironmentVariable("PATH", "Machine") +
        ";" +
        [System.Environment]::GetEnvironmentVariable("PATH", "User")
    )

    # Verify installation
    if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
        Write-Warning "Helm was installed but is not yet available in the current session."
        Write-Warning "Please restart PowerShell and run the script again."
        exit 1
    }

    Write-Host "Helm successfully installed." -ForegroundColor Green
}

# Validate Azure login
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged in. Run: az login"
    exit 1
}

Write-Host "Subscription: $(Invoke-AzOut account show --query name -o tsv)"
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }
Write-Host "Subscription: $(Invoke-AzOut account show --query name -o tsv)"

# ---- Register resource providers + AGC CLI extension ----------------------
Write-Host "Registering resource providers (idempotent)..."
foreach ($ns in 'Microsoft.ContainerService','Microsoft.Network','Microsoft.NetworkFunction','Microsoft.ServiceNetworking') {
  Invoke-AzNone provider register --namespace $ns -o none
}
& az extension add --name alb --only-show-errors -o none 2>$null
if ($LASTEXITCODE -ne 0) { & az extension update --name alb --only-show-errors -o none 2>$null }

# ---- Resource group -------------------------------------------------------
Write-Host "Creating resource group '$Rg' in '$Location'..."
Invoke-AzNone group create -n $Rg -l $Location -o none

# ---- Deploy Bicep (AKS + identity + federation) ---------------------------
Write-Host "Deploying AKS + managed identity via Bicep (this is the slow part, ~5-8 min)..."
Invoke-AzNone deployment group create -g $Rg -n $DeployName -f (Join-Path $ScriptDir 'main.bicep') `
  -p "location=$Location" "aksName=$AksName" "albIdentityName=$AlbIdentityName" -o none

function Get-Out { param([string]$Name) Invoke-AzOut deployment group show -g $Rg -n $DeployName --query "properties.outputs.$Name.value" -o tsv }
$AksName        = Get-Out aksName
$McRg           = Get-Out nodeResourceGroup
$AlbClientId    = Get-Out albIdentityClientId
$AlbPrincipalId = Get-Out albIdentityPrincipalId
Write-Host "  AKS cluster        : $AksName"
Write-Host "  Node resource group: $McRg"

# ---- Add a delegated subnet for AGC into the AKS-managed VNet --------------
Write-Host "Locating the AKS-managed VNet..."
$ClusterSubnetId = Invoke-AzOut vmss list --resource-group $McRg `
  --query '[0].virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id' -o tsv
$VnetId   = $ClusterSubnetId -replace '/subnets/.*$',''
$VnetName = $VnetId.Split('/')[-1]
$VnetRg   = ($VnetId -replace '^.*/resourceGroups/','').Split('/')[0]
Write-Host "  Managed VNet: $VnetName (rg: $VnetRg)"

$VnetCidr = Invoke-AzOut network vnet show -g $VnetRg -n $VnetName --query 'addressSpace.addressPrefixes[0]' -o tsv
Write-Host "  Managed VNet address space: $VnetCidr"
if (-not (Test-InCidr ($AlbSubnetPrefix.Split('/')[0]) $VnetCidr)) {
  Write-Error "ALB_SUBNET_PREFIX ($AlbSubnetPrefix) is not inside the AKS-managed VNet ($VnetCidr). Re-run with -AlbSubnetPrefix <net>/24 inside that range."
  exit 1
}

Write-Host "Creating delegated subnet '$AlbSubnetName' ($AlbSubnetPrefix)..."
Invoke-AzNone network vnet subnet create --resource-group $VnetRg --vnet-name $VnetName --name $AlbSubnetName `
  --address-prefixes $AlbSubnetPrefix --delegations 'Microsoft.ServiceNetworking/trafficControllers' -o none
$AlbSubnetId = Invoke-AzOut network vnet subnet show --name $AlbSubnetName --resource-group $VnetRg --vnet-name $VnetName --query id -o tsv

# ---- Assign the 3 roles the ALB controller needs (Managed mode) -----------
$McResourceGroupId = Invoke-AzOut group show --name $McRg --query id -o tsv
function Add-RoleAssignment { param($RoleId,$Scope,$Friendly)
  Write-Host "  -> $Friendly"
  for ($a=1; $a -le 6; $a++) {
    & az role assignment create --assignee-object-id $AlbPrincipalId --assignee-principal-type ServicePrincipal --scope $Scope --role $RoleId -o none 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    Write-Host "     (identity not replicated yet — retrying in 15s, attempt $a/6)"
    Start-Sleep 15
  }
  throw "could not assign role $Friendly after retries."
}
Write-Host "Assigning roles to the ALB controller identity..."
Add-RoleAssignment $RoleReader             $McResourceGroupId "Reader on node RG"
Add-RoleAssignment $RoleAgcConfigManager   $McResourceGroupId "AppGw for Containers Configuration Manager on node RG"
Add-RoleAssignment $RoleNetworkContributor $AlbSubnetId       "Network Contributor on $AlbSubnetName"

# ---- Cluster credentials --------------------------------------------------
Write-Host "Fetching AKS credentials..."
Invoke-AzNone aks get-credentials --resource-group $Rg --name $AksName --overwrite-existing -o none

# ---- Install the ALB controller via Helm ----------------------------------
Write-Host "Installing the ALB controller (chart $AlbControllerVersion)..."
& helm upgrade --install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller `
  --namespace $HelmNamespace --create-namespace --version $AlbControllerVersion `
  --set "albController.namespace=$ControllerNamespace" --set "albController.podIdentity.clientID=$AlbClientId" `
  --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "helm install of the ALB controller failed (exit $LASTEXITCODE)" }

Write-Host "Waiting for the GatewayClass 'azure-alb-external' to register..."
for ($i=0; $i -lt 30; $i++) {
  & kubectl get gatewayclass azure-alb-external 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { break }
  Start-Sleep 5
}
& kubectl wait --for=condition=Accepted gatewayclass/azure-alb-external --timeout=120s
if ($LASTEXITCODE -ne 0) { throw "GatewayClass azure-alb-external did not become Accepted" }

# ---- Create the AGC (ApplicationLoadBalancer) -----------------------------
# Native substitution of ${ALB_SUBNET_ID} (deploy.sh uses envsubst, absent on Windows).
Write-Host "Creating the Application Gateway for Containers resource (Managed mode)..."
$albManifest = (Get-Content (Join-Path $ScriptDir 'k8s/00-alb.yaml') -Raw).Replace('${ALB_SUBNET_ID}', $AlbSubnetId)
$albManifest | & kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "kubectl apply of 00-alb.yaml failed" }

Write-Host "Waiting for the AGC to reach 'Programmed' (ARM provisioning, ~5-6 min)..."
for ($i=0; $i -lt 90; $i++) {
  $dep = (& kubectl get applicationloadbalancer alb-test -n alb-test-infra -o jsonpath='{.status.conditions[?(@.type=="Deployment")].status}' 2>$null)
  if ($dep -eq 'True') { Write-Host "  AGC is Programmed."; break }
  Start-Sleep 10
}

# ---- Deploy the blue/green app + Gateway + weighted HTTPRoute -------------
Write-Host "Deploying the blue/green app, Gateway and weighted HTTPRoute..."
& kubectl apply -f (Join-Path $ScriptDir 'k8s/10-app-bluegreen.yaml'); if ($LASTEXITCODE -ne 0) { throw "apply 10-app-bluegreen.yaml failed" }
& kubectl rollout status deploy/backend-v1 -n test-infra --timeout=120s; if ($LASTEXITCODE -ne 0) { throw "backend-v1 rollout failed" }
& kubectl rollout status deploy/backend-v2 -n test-infra --timeout=120s; if ($LASTEXITCODE -ne 0) { throw "backend-v2 rollout failed" }
& kubectl apply -f (Join-Path $ScriptDir 'k8s/20-gateway.yaml');   if ($LASTEXITCODE -ne 0) { throw "apply 20-gateway.yaml failed" }
& kubectl apply -f (Join-Path $ScriptDir 'k8s/30-httproute.yaml'); if ($LASTEXITCODE -ne 0) { throw "apply 30-httproute.yaml failed" }

Write-Host "Waiting for the Gateway listener to be Programmed and assigned an FQDN..."
$Fqdn = ''
for ($i=0; $i -lt 60; $i++) {
  $Fqdn = (& kubectl get gateway gateway-01 -n test-infra -o jsonpath='{.status.addresses[0].value}' 2>$null)
  $prog = (& kubectl get gateway gateway-01 -n test-infra -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>$null)
  if ($Fqdn -and $prog -eq 'True') { break }
  Start-Sleep 10
}
if (-not $Fqdn) { Write-Warning "Gateway FQDN not assigned yet. Check: kubectl get gateway gateway-01 -n test-infra -o yaml" }

$fqdnShown = if ($Fqdn) { $Fqdn } else { '<pending — re-check in a minute>' }
Write-Host @"

============================================================
  AGC convergence lab deployed.
============================================================
  AGC frontend FQDN : $fqdnShown

  1) In TERMINAL A, start the traffic hammer:
       bash $ScriptDir/scripts/hammer.sh $fqdnShown
       (demo drivers are bash; on Windows run them via WSL/Git-Bash)

  2) In TERMINAL B, kill the active (BLUE) backend live:
       bash $ScriptDir/scripts/kill-active.sh

     Watch Terminal A: BLUE freezes, GREEN takes over in <1s,
     and the FAIL counter stays at 0. That's the whole point.

  Reset for another run:
       kubectl scale deploy/backend-v1 -n test-infra --replicas=2

  Tear everything down when done:
       ./cleanup.ps1 -Rg $Rg
============================================================
"@
