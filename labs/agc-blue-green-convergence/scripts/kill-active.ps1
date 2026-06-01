param(
    [string]$Namespace = "test-infra",
    [string]$Target = "backend-v1",
    [int]$ScaleUpReplicas = 2
)

function Get-Timestamp {
    return (Get-Date -Format "HH:mm:ss.fff")
}

# Huidige replicas ophalen
try {
    $replicas = kubectl get deploy $Target -n $Namespace -o jsonpath="{.spec.replicas}"
    $replicas = [int]$replicas
}
catch {
    Write-Host "[$(Get-Timestamp)] ERROR: Cannot read current replica count"
    exit 1
}

Write-Host "[$(Get-Timestamp)] Current replicas: $replicas"

if ($replicas -gt 0) {
    Write-Host "[$(Get-Timestamp)] Scaling $Target DOWN to 0 (killing BLUE)..."
    kubectl scale deploy/$Target -n $Namespace --replicas=0
}
else {
    Write-Host "[$(Get-Timestamp)] Scaling $Target UP to $ScaleUpReplicas (restoring BLUE)..."
    kubectl scale deploy/$Target -n $Namespace --replicas=$ScaleUpReplicas
}

Write-Host "[$(Get-Timestamp)] Done.`n"