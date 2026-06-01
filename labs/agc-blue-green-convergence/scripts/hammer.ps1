param(
    [Parameter(Mandatory = $true)]
    [string]$FQDN,
    [double]$Interval = 0.1
)

# Normalize URL
if ($FQDN -notmatch "^https?://") {
    $URL = "http://$FQDN"
} else {
    $URL = $FQDN
}

# Counters
$total = 0
$ok = 0
$fail = 0
$blue = 0
$green = 0
$last = ""
$start = Get-Date

Write-Host "Hammering $URL every $Interval seconds. Press Ctrl+C to stop.`n"

# Trap Ctrl+C netjes af
$script:running = $true
Register-EngineEvent PowerShell.Exiting -Action {
    $script:running = $false
}

try {
    while ($true) {
        $total++

        try {
            $response = Invoke-WebRequest -Uri $URL -TimeoutSec 3 -ErrorAction Stop
            $statusCode = [int]$response.StatusCode
            $content = $response.Content

            if ($statusCode -ge 200 -and $statusCode -lt 400) {
                $ok++

                if ($content -match "GREEN") {
                    $green++
                    $last = "GREEN"
                }
                elseif ($content -match "BLUE") {
                    $blue++
                    $last = "BLUE"
                }
                else {
                    $last = "?($statusCode)"
                }
            }
            else {
                $fail++
                $last = "FAIL($statusCode)"
            }
        }
        catch {
            $fail++
            $last = "FAIL"
        }

        Write-Host -NoNewline "`rtotal=$total OK=$ok FAIL=$fail BLUE=$blue GREEN=$green last=$last"

        Start-Sleep -Seconds $Interval
    }
}
finally {
    $duration = (Get-Date) - $start

    Write-Host "`n------------------------------------------------------------"
    Write-Host "Final tally after $([int]$duration.TotalSeconds)s"
    Write-Host "total requests : $total"
    Write-Host "OK (2xx/3xx)   : $ok"
    Write-Host "FAIL (errors)  : $fail"
    Write-Host "served by BLUE : $blue"
    Write-Host "served by GREEN: $green"
    Write-Host "------------------------------------------------------------"
}
