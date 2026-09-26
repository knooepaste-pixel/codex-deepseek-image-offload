[CmdletBinding()]
param(
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings
New-Item -ItemType Directory -Force -Path $Settings.LogDir | Out-Null

& (Join-Path $PSScriptRoot "install-command-wrapper.ps1") | Write-Host

$PluginFamilyRoot = Split-Path -Parent $Settings.Root
$EscapedPluginFamilyRoot = $PluginFamilyRoot.Replace("'", "''")
$Launcher = @'
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$PluginFamilyRoot = '__PLUGIN_FAMILY_ROOT__'
$LogDir = Join-Path $env:LOCALAPPDATA 'Codex\deepseek-image-offload'
$WatchLog = Join-Path $LogDir 'watchdog.log'

try {
    $Candidates = @(
        Get-ChildItem `
            -LiteralPath $PluginFamilyRoot `
            -Directory `
            -ErrorAction SilentlyContinue |
            Where-Object {
                Test-Path -LiteralPath (
                    Join-Path $_.FullName 'scripts\watch.ps1'
                )
            } |
            ForEach-Object {
                $CandidatePath = $_.FullName
                $CandidateVersion = [version]'0.0.0'
                try {
                    $CandidateVersion = [version](
                        Split-Path -Leaf $CandidatePath
                    )
                } catch {
                    # Keep the invalid directory as the lowest-priority option.
                }
                [pscustomobject]@{
                    Path = $CandidatePath
                    Version = $CandidateVersion
                    LastWriteTime = $_.LastWriteTime
                }
            } |
            Sort-Object `
                -Property Version, LastWriteTime `
                -Descending
    )

    if ($Candidates.Count -eq 0) {
        throw "No installed image offload watch script was found."
    }

    & (Join-Path $Candidates[0].Path 'scripts\watch.ps1')
} catch {
    $Line = (
        "[{0}] {1}" -f
        (Get-Date).ToString("o"),
        $_.Exception.Message
    )
    Add-Content -LiteralPath $WatchLog -Value $Line -Encoding utf8
    throw
}
'@

$Launcher = $Launcher.Replace(
    "__PLUGIN_FAMILY_ROOT__",
    $EscapedPluginFamilyRoot
)
[System.IO.File]::WriteAllText(
    $Settings.LauncherPath,
    $Launcher,
    [System.Text.UTF8Encoding]::new($false)
)

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
            "-File `"$($Settings.LauncherPath)`""
        )
    $LogonTrigger = New-ScheduledTaskTrigger `
        -AtLogOn `
        -User "$env:USERDOMAIN\$env:USERNAME"
    $LogonTrigger.Delay = "PT10S"
    $TaskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    $Principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $script:OffloadTaskName `
        -Action $Action `
        -Trigger @($LogonTrigger) `
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
        "-File `"$($Settings.LauncherPath)`""
    )
    $Shortcut.WorkingDirectory = $Settings.Root
    $Shortcut.WindowStyle = 7
    $Shortcut.Description = "Keep the Codex DeepSeek image offload proxy running"
    $Shortcut.Save()

    if (-not $NoStart) {
        Start-Process -FilePath $Pwsh `
            -ArgumentList (
                "-NoLogo -NoProfile -ExecutionPolicy Bypass " +
                "-WindowStyle Hidden -File `"$($Settings.LauncherPath)`""
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
