$ErrorActionPreference = "Stop"

$LogDir = Join-Path $env:LOCALAPPDATA "Codex\deepseek-image-offload"
$PidFile = Join-Path $LogDir "service.pid"

function Test-OffloadProcess {
    param([int]$ProcessId)

    $ProcessInfo = Get-CimInstance Win32_Process `
        -Filter "ProcessId = $ProcessId" `
        -ErrorAction SilentlyContinue
    if (-not $ProcessInfo) {
        return $false
    }

    return (
        $ProcessInfo.Name -eq "node.exe" -and
        $ProcessInfo.CommandLine -like "*deepseek-image-offload*" -and
        $ProcessInfo.CommandLine -like "*src\server.mjs*"
    )
}

if (-not (Test-Path -LiteralPath $PidFile)) {
    Write-Output "not-running"
    exit 0
}

$ServicePid = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue
if ($ServicePid) {
    if (Test-OffloadProcess -ProcessId ([int]$ServicePid)) {
        Stop-Process -Id ([int]$ServicePid)
        Write-Output "stopped:$ServicePid"
    } else {
        Write-Output "stale-pid"
    }
}

Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
