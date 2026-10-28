param (
    [string]$TargetIp = "10.40.101.184",
    [string]$HostHeader = "chat.infra.internal"
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Enterprise SRE Module 3: Live Zero-Downtime Traffic Probe" -ForegroundColor Green
Write-Host "  Target: http://$TargetIp/ (Host: $HostHeader)" -ForegroundColor Yellow
Write-Host "  Press Ctrl+C to Stop." -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

$total = 0
$success = 0
$failed = 0

while ($true) {
    $total++
    try {
        $code = curl.exe -s -w "%{http_code}" -o NUL -H "Host: $HostHeader" --connect-timeout 2 --max-time 3 "http://$TargetIp/"
        if ($code -eq "200") {
            $success++
            if ($total % 10 -eq 0) {
                $now = Get-Date -Format "HH:mm:ss"
                Write-Host "[$now] TOTAL: $total | SUCCESS(200): $success | FAILED(5xx): $failed | ErrorRate: 0.00%" -ForegroundColor Green
            }
        } else {
            $failed++
            $now = Get-Date -Format "HH:mm:ss"
            Write-Host "[$now] ALERT: HTTP $code (FAILED: $failed / TOTAL: $total)" -ForegroundColor Red
        }
    } catch {
        $failed++
        $now = Get-Date -Format "HH:mm:ss"
        Write-Host "[$now] ERROR: Connection Failed! (FAILED: $failed / TOTAL: $total)" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 100
}
