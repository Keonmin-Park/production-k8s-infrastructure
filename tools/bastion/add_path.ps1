$binDir = "$env:USERPROFILE\bin"
$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentPath -notlike "*$binDir*") {
    $newPath = "$currentPath;$binDir"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Host "Added $binDir to User PATH."
} else {
    Write-Host "$binDir is already in User PATH."
}

$env:Path = "$env:Path;$binDir"
& kubectl version --client
