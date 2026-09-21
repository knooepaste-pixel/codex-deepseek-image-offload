[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $HOME ".codex\config.toml"),
    [string]$ProxyUrl = "http://127.0.0.1:17891",
    [switch]$NoStart,
    [switch]$NoAutostart
)

$ErrorActionPreference = "Stop"

if (-not $NoStart) {
    & (Join-Path $PSScriptRoot "start.ps1") | Write-Host

    $Ready = $false
    for ($Attempt = 0; $Attempt -lt 20; $Attempt += 1) {
        try {
            $Health = Invoke-RestMethod -Uri "$ProxyUrl/health" -TimeoutSec 2
            if ($Health.ok) {
                $Ready = $true
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }

    if (-not $Ready) {
        throw "Image offload proxy did not become healthy at $ProxyUrl"
    }
}

if (-not $NoAutostart) {
    & (Join-Path $PSScriptRoot "install-autostart.ps1") | Write-Host
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Codex config not found: $ConfigPath"
}

$Content = [System.IO.File]::ReadAllText($ConfigPath)
$ProviderPattern = "(?ms)^\[model_providers\.custom\]\s*\r?\n.*?(?=^\[|\z)"
$ProviderMatch = [regex]::Match($Content, $ProviderPattern)
if (-not $ProviderMatch.Success) {
    throw "Could not find [model_providers.custom] in $ConfigPath"
}

$ProviderBlock = $ProviderMatch.Value
$BaseUrlPattern = "(?m)^base_url\s*=.*$"
if ([regex]::IsMatch($ProviderBlock, $BaseUrlPattern)) {
    $UpdatedBlock = [regex]::Replace(
        $ProviderBlock,
        $BaseUrlPattern,
        "base_url = `"$ProxyUrl`""
    )
} else {
    $HeaderEnd = $ProviderBlock.IndexOf("`n")
    if ($HeaderEnd -lt 0) {
        throw "Invalid [model_providers.custom] block in $ConfigPath"
    }
    $InsertAt = $HeaderEnd + 1
    $UpdatedBlock = $ProviderBlock.Insert(
        $InsertAt,
        "base_url = `"$ProxyUrl`"`r`n"
    )
}

if ($UpdatedBlock -eq $ProviderBlock) {
    Write-Output "already-enabled:$ProxyUrl"
    exit 0
}

$BackupPath = "$ConfigPath.deepseek-image-offload.bak"
if (-not (Test-Path -LiteralPath $BackupPath)) {
    Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath
}

$UpdatedContent = $Content.Remove(
    $ProviderMatch.Index,
    $ProviderMatch.Length
).Insert($ProviderMatch.Index, $UpdatedBlock)

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($ConfigPath, $UpdatedContent, $Utf8NoBom)

Write-Output "enabled:$ProxyUrl"
Write-Output "backup:$BackupPath"
Write-Output "restart-codex-thread-required"
