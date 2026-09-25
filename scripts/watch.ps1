[CmdletBinding()]
param(
    [int]$IntervalSeconds = 5
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings
New-Item -ItemType Directory -Force -Path $Settings.LogDir | Out-Null
Set-Content `
    -LiteralPath $Settings.WatchPidFile `
    -Value $PID `
    -Encoding ascii

$LastError = $null

try {
    while ($true) {
        try {
            if (-not (Test-OffloadHealth -Settings $Settings -TimeoutSec 3)) {
                & $Settings.StartScript | Out-Null
            }
            $LastError = $null
        } catch {
            $Message = $_.Exception.Message
            if ($Message -ne $LastError) {
                $Line = (
                    "[{0}] {1}" -f
                    (Get-Date).ToString("o"),
                    $Message
                )
                Add-Content `
                    -LiteralPath $Settings.WatchLog `
                    -Value $Line `
                    -Encoding utf8
                $LastError = $Message
            }
        }

        Start-Sleep -Seconds ([Math]::Max(1, $IntervalSeconds))
    }
} finally {
    Remove-Item `
        -LiteralPath $Settings.WatchPidFile `
        -Force `
        -ErrorAction SilentlyContinue
}
