[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$StartupDirectory = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDirectory "DeepSeek Image Offload.lnk"

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
    Write-Output "autostart-removed:$ShortcutPath"
} else {
    Write-Output "autostart-not-installed"
}
