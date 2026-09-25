$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings

try {
    Invoke-RestMethod -Uri $Settings.HealthUrl -TimeoutSec 3 |
        ConvertTo-Json -Depth 8
} catch {
    $RecordedPid = Get-RecordedOffloadProcessId -Settings $Settings
    $ProcessText = if (
        $RecordedPid -and
        (Test-OffloadProcess -Settings $Settings -ProcessId $RecordedPid)
    ) {
        " Recorded PID $RecordedPid exists but is not healthy."
    } else {
        ""
    }
    Write-Error (
        "Image offload proxy is not reachable at $($Settings.HealthUrl)." +
        $ProcessText +
        " Check $($Settings.StderrLog) and $($Settings.WatchLog), " +
        "then run start.ps1."
    )
}
