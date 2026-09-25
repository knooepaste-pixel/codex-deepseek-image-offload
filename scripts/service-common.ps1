$ErrorActionPreference = "Stop"

$script:OffloadServiceName = "codex-deepseek-image-offload"
$script:OffloadTaskName = "Codex DeepSeek Image Offload"
$script:OffloadShortcutName = "DeepSeek Image Offload.lnk"

function Get-OffloadServiceSettings {
    $Root = Split-Path -Parent $PSScriptRoot
    $LogDir = Join-Path $env:LOCALAPPDATA "Codex\deepseek-image-offload"
    $ConfigPath = if ($env:CODEX_IMAGE_OFFLOAD_CONFIG) {
        [System.IO.Path]::GetFullPath($env:CODEX_IMAGE_OFFLOAD_CONFIG)
    } else {
        Join-Path $Root "config.json"
    }

    $Port = 17891
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $FileConfig = Get-Content -Raw -LiteralPath $ConfigPath |
                ConvertFrom-Json
            if ($FileConfig.listenPort) {
                $Port = [int]$FileConfig.listenPort
            }
        } catch {
            throw "Could not read image offload config: $ConfigPath"
        }
    }

    if ($env:CODEX_IMAGE_OFFLOAD_PORT) {
        $Port = [int]$env:CODEX_IMAGE_OFFLOAD_PORT
    }

    [pscustomobject]@{
        Root = $Root
        Port = $Port
        HealthUrl = "http://127.0.0.1:$Port/health"
        LogDir = $LogDir
        StdoutLog = Join-Path $LogDir "service.stdout.log"
        StderrLog = Join-Path $LogDir "service.stderr.log"
        PidFile = Join-Path $LogDir "service.pid"
        WatchPidFile = Join-Path $LogDir "watch.pid"
        WatchLog = Join-Path $LogDir "watchdog.log"
        ServerPath = Join-Path $Root "src\server.mjs"
        StartScript = Join-Path $Root "scripts\start.ps1"
        WatchScript = Join-Path $Root "scripts\watch.ps1"
        StopScript = Join-Path $Root "scripts\stop.ps1"
    }
}

function Test-OffloadHealth {
    param(
        [Parameter(Mandatory)]
        $Settings,
        [int]$TimeoutSec = 2
    )

    try {
        $Health = Invoke-RestMethod `
            -Uri $Settings.HealthUrl `
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop
        return (
            $Health.ok -eq $true -and
            $Health.service -eq $script:OffloadServiceName
        )
    } catch {
        return $false
    }
}

function Get-OffloadProcessInfo {
    param([int]$ProcessId)

    return Get-CimInstance Win32_Process `
        -Filter "ProcessId = $ProcessId" `
        -ErrorAction SilentlyContinue
}

function Test-OffloadProcess {
    param(
        [Parameter(Mandatory)]
        $Settings,
        [int]$ProcessId
    )

    $ProcessInfo = Get-OffloadProcessInfo -ProcessId $ProcessId
    if (-not $ProcessInfo) {
        return $false
    }

    return (
        $ProcessInfo.Name -eq "node.exe" -and
        $ProcessInfo.CommandLine -like "*$($Settings.ServerPath)*"
    )
}

function Get-RecordedOffloadProcessId {
    param(
        [Parameter(Mandatory)]
        $Settings
    )

    if (-not (Test-Path -LiteralPath $Settings.PidFile)) {
        return $null
    }

    $RecordedPid = Get-Content `
        -LiteralPath $Settings.PidFile `
        -ErrorAction SilentlyContinue
    $ParsedPid = 0
    if (
        $RecordedPid -and
        [int]::TryParse($RecordedPid.Trim(), [ref]$ParsedPid)
    ) {
        return $ParsedPid
    }
    return $null
}

function Clear-OffloadPidFile {
    param(
        [Parameter(Mandatory)]
        $Settings
    )

    Remove-Item `
        -LiteralPath $Settings.PidFile `
        -Force `
        -ErrorAction SilentlyContinue
}

function Get-OffloadServerProcesses {
    param(
        [Parameter(Mandatory)]
        $Settings
    )

    return @(
        Get-CimInstance Win32_Process `
            -Filter "Name = 'node.exe'" `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -like "*$($Settings.ServerPath)*"
            }
    )
}

function Get-AllOffloadServerProcesses {
    return @(
        Get-CimInstance Win32_Process `
            -Filter "Name = 'node.exe'" `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -like "*deepseek-image-offload*" -and
                $_.CommandLine -like "*src\server.mjs*"
            }
    )
}

function Get-NodePath {
    if ($env:CODEX_IMAGE_OFFLOAD_NODE) {
        if (Test-Path -LiteralPath $env:CODEX_IMAGE_OFFLOAD_NODE) {
            return (Resolve-Path -LiteralPath $env:CODEX_IMAGE_OFFLOAD_NODE).Path
        }
        throw "CODEX_IMAGE_OFFLOAD_NODE does not exist: $env:CODEX_IMAGE_OFFLOAD_NODE"
    }

    $NodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($NodeCommand) {
        return $NodeCommand.Source
    }

    $Candidates = @()
    if ($env:ProgramFiles) {
        $Candidates += Join-Path $env:ProgramFiles "nodejs\node.exe"
    }
    if (${env:ProgramFiles(x86)}) {
        $Candidates += Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe"
    }
    if ($env:LOCALAPPDATA) {
        $Candidates += Join-Path $env:LOCALAPPDATA "Programs\nodejs\node.exe"
    }
    if ($env:APPDATA) {
        $Candidates += Join-Path $env:APPDATA "nvm\node.exe"
    }
    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path -LiteralPath $Candidate)) {
            return $Candidate
        }
    }

    throw "Node.js was not found. Install Node.js 22.19 or newer, or set CODEX_IMAGE_OFFLOAD_NODE."
}

function Get-OffloadWatchProcesses {
    param(
        [Parameter(Mandatory)]
        $Settings
    )

    return @(
        Get-CimInstance Win32_Process `
            -Filter "Name = 'pwsh.exe'" `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -match '(?i)-File\s+"?[^"]*deepseek-image-offload[^"]*watch\.ps1"?'
            }
    )
}
