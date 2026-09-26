[CmdletBinding()]
param(
    [switch]$KeepWatchdog
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings
$StartupDirectory = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDirectory $script:OffloadShortcutName
$RemovedTask = $false
$RemovedShortcut = $false
$RemovedLauncher = $false

if (Get-ScheduledTask -TaskName $script:OffloadTaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask `
        -TaskName $script:OffloadTaskName `
        -ErrorAction SilentlyContinue
    Unregister-ScheduledTask `
        -TaskName $script:OffloadTaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    $RemovedTask = $true
}

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
    $RemovedShortcut = $true
}

if (-not $KeepWatchdog) {
    foreach ($WatchProcess in (Get-OffloadWatchProcesses -Settings $Settings)) {
        Stop-Process `
            -Id $WatchProcess.ProcessId `
            -Force `
            -ErrorAction SilentlyContinue
    }
    Remove-Item `
        -LiteralPath $Settings.WatchPidFile `
        -Force `
        -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $Settings.LauncherPath) {
        Remove-Item `
            -LiteralPath $Settings.LauncherPath `
            -Force `
            -ErrorAction SilentlyContinue
        $RemovedLauncher = $true
    }
}

if ($RemovedTask) {
    Write-Output "autostart-removed:task:$($script:OffloadTaskName)"
}
if ($RemovedShortcut) {
    Write-Output "autostart-removed:startup:$ShortcutPath"
}
if ($RemovedLauncher) {
    Write-Output "autostart-removed:launcher:$($Settings.LauncherPath)"
}
if (
    -not $RemovedTask -and
    -not $RemovedShortcut -and
    -not $RemovedLauncher
) {
    Write-Output "autostart-not-installed"
}
