[CmdletBinding()]
param(
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings
if (-not (Test-Path -LiteralPath $Settings.WatchScript)) {
    throw "Watch script not found: $($Settings.WatchScript)"
}

$Pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$StartupDirectory = [Environment]::GetFolderPath("Startup")
$ShortcutPath = Join-Path $StartupDirectory $script:OffloadShortcutName

try {
    $Action = New-ScheduledTaskAction `
        -Execute $Pwsh `
        -Argument (
            "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
            "-File `"$($Settings.WatchScript)`""
        )
    $LogonTrigger = New-ScheduledTaskTrigger `
        -AtLogOn `
        -User "$env:USERDOMAIN\$env:USERNAME"
    $LogonTrigger.Delay = "PT10S"
    $KeepAliveTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration ([TimeSpan]::FromDays(3650))
    $TaskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    $Principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $script:OffloadTaskName `
        -Action $Action `
        -Trigger @($LogonTrigger, $KeepAliveTrigger) `
        -Settings $TaskSettings `
        -Principal $Principal `
        -Force `
        -ErrorAction Stop | Out-Null
} catch {
    Write-Warning (
        "Could not install the scheduled task; falling back to the " +
        "Startup folder. $($_.Exception.Message)"
    )

    $Shell = New-Object -ComObject WScript.Shell
    $Shortcut = $Shell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $Pwsh
    $Shortcut.Arguments = (
        "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
        "-File `"$($Settings.WatchScript)`""
    )
    $Shortcut.WorkingDirectory = $Settings.Root
    $Shortcut.WindowStyle = 7
    $Shortcut.Description = "Keep the Codex DeepSeek image offload proxy running"
    $Shortcut.Save()

    if (-not $NoStart) {
        Start-Process -FilePath $Pwsh `
            -ArgumentList (
                "-NoLogo -NoProfile -ExecutionPolicy Bypass " +
                "-WindowStyle Hidden -File `"$($Settings.WatchScript)`""
            ) `
            -WorkingDirectory $Settings.Root `
            -WindowStyle Hidden
    }
    Write-Output "autostart-installed:startup:$ShortcutPath"
    return
}

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force
}
if (-not $NoStart) {
    try {
        Start-ScheduledTask `
            -TaskName $script:OffloadTaskName `
            -ErrorAction Stop
    } catch {
        Write-Warning (
            "The logon task is registered but could not be started now. " +
            "It will start at the next trigger. $($_.Exception.Message)"
        )
    }
}
Write-Output "autostart-installed:task:$($script:OffloadTaskName)"
