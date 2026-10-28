$binDir = "$env:USERPROFILE\bin"
if (!(Test-Path $binDir)) {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
}

$kubectlPath = "$binDir\kubectl.exe"
if (!(Test-Path $kubectlPath)) {
    Write-Host "Downloading kubectl v1.28.15 for Windows..."
    $url = "https://dl.k8s.io/release/v1.28.15/bin/windows/amd64/kubectl.exe"
    Invoke-WebRequest -Uri $url -OutFile $kubectlPath -UseBasicParsing
}

Write-Host "kubectl downloaded to: $kubectlPath"
& $kubectlPath version --client
