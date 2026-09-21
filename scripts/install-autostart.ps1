[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$StartScript = Join-Path $PSScriptRoot "start.ps1"
if (-not (Test-Path -LiteralPath $StartScript)) {
    throw "Start script not found: $StartScript"
}

$Pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$StartupDirectory = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDirectory "DeepSeek Image Offload.lnk"

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $Pwsh
$Shortcut.Arguments = (
    "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
    "-File `"$StartScript`""
)
$Shortcut.WorkingDirectory = $PSScriptRoot
$Shortcut.WindowStyle = 7
$Shortcut.Description = "Start the Codex DeepSeek image offload proxy"
$Shortcut.Save()

Write-Output "autostart-installed:$ShortcutPath"
