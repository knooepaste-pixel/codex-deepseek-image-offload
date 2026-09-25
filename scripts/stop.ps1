[CmdletBinding()]
param(
    [switch]$KeepAutostart
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings

if (-not $KeepAutostart) {
    & (Join-Path $PSScriptRoot "remove-autostart.ps1") | Write-Host
}

$StoppedPids = @()
$RecordedPid = Get-RecordedOffloadProcessId -Settings $Settings
if (
    $RecordedPid -and
    (Test-OffloadProcess -Settings $Settings -ProcessId $RecordedPid)
) {
    Stop-Process -Id $RecordedPid -Force -ErrorAction SilentlyContinue
    $StoppedPids += $RecordedPid
}

foreach ($Process in (Get-AllOffloadServerProcesses)) {
    if ($StoppedPids -notcontains $Process.ProcessId) {
        Stop-Process `
            -Id $Process.ProcessId `
            -Force `
            -ErrorAction SilentlyContinue
        $StoppedPids += $Process.ProcessId
    }
}
Clear-OffloadPidFile -Settings $Settings

if ($StoppedPids.Count -eq 0) {
    Write-Output "not-running"
} else {
    Write-Output "stopped:$($StoppedPids -join ',')"
}
