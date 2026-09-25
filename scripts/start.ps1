[CmdletBinding()]
param(
    [int]$HealthTimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings
New-Item -ItemType Directory -Force -Path $Settings.LogDir | Out-Null

if (Test-OffloadHealth -Settings $Settings) {
    $ExistingPid = Get-RecordedOffloadProcessId -Settings $Settings
    if (-not $ExistingPid) {
        $RunningProcess = Get-OffloadServerProcesses -Settings $Settings |
            Select-Object -First 1
        $ExistingPid = $RunningProcess.ProcessId
        if ($ExistingPid) {
            Set-Content `
                -LiteralPath $Settings.PidFile `
                -Value $ExistingPid `
                -Encoding ascii
        }
    }
    Write-Output "already-running:$ExistingPid"
    return
}

$Mutex = [System.Threading.Mutex]::new(
    $false,
    "Local\CodexDeepSeekImageOffloadStart"
)
$HasMutex = $false

try {
    $HasMutex = $Mutex.WaitOne([TimeSpan]::FromSeconds(20))
    if (-not $HasMutex) {
        throw "Timed out waiting for another image offload start operation."
    }

    if (Test-OffloadHealth -Settings $Settings) {
        Write-Output "already-running"
        return
    }

    # Clear only hung processes that belong to this checkout.
    foreach ($ExistingProcess in (Get-OffloadServerProcesses -Settings $Settings)) {
        Stop-Process -Id $ExistingProcess.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Clear-OffloadPidFile -Settings $Settings

    $Node = Get-NodePath
    $Process = Start-Process -FilePath $Node `
        -ArgumentList @($Settings.ServerPath) `
        -WorkingDirectory $Settings.Root `
        -WindowStyle Hidden `
        -RedirectStandardOutput $Settings.StdoutLog `
        -RedirectStandardError $Settings.StderrLog `
        -PassThru

    Set-Content `
        -LiteralPath $Settings.PidFile `
        -Value $Process.Id `
        -Encoding ascii

    $Deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    while ((Get-Date) -lt $Deadline) {
        if (Test-OffloadHealth -Settings $Settings) {
            Write-Output "started:$($Process.Id)"
            return
        }
        if ($Process.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    }
    Clear-OffloadPidFile -Settings $Settings

    $Detail = ""
    if (Test-Path -LiteralPath $Settings.StderrLog) {
        $Detail = (
            Get-Content -Tail 20 -LiteralPath $Settings.StderrLog
        ) -join [Environment]::NewLine
    }
    if (-not $Detail) {
        $Detail = (
            Get-Content -Tail 20 -LiteralPath $Settings.StdoutLog
        ) -join [Environment]::NewLine
    }
    throw (
        "Image offload proxy did not become healthy at " +
        "$($Settings.HealthUrl) within $HealthTimeoutSeconds seconds." +
        $(if ($Detail) { "`n$Detail" } else { "" })
    )
} finally {
    if ($HasMutex) {
        $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
}
