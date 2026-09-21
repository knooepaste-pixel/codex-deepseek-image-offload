$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $env:LOCALAPPDATA "Codex\deepseek-image-offload"
$StdoutLog = Join-Path $LogDir "service.stdout.log"
$StderrLog = Join-Path $LogDir "service.stderr.log"
$PidFile = Join-Path $LogDir "service.pid"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

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

if (Test-Path -LiteralPath $PidFile) {
    $ExistingPid = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue
    if ($ExistingPid) {
        if (Test-OffloadProcess -ProcessId ([int]$ExistingPid)) {
            Write-Output "already-running:$ExistingPid"
            exit 0
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

$Node = (Get-Command node -ErrorAction Stop).Source
$Server = Join-Path $Root "src\server.mjs"
$Process = Start-Process -FilePath $Node `
    -ArgumentList @($Server) `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog `
    -PassThru

Set-Content -LiteralPath $PidFile -Value $Process.Id -Encoding ascii
Write-Output "started:$($Process.Id)"
