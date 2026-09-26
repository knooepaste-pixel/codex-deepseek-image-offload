[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $HOME ".codex\config.toml"),
    [string]$ProxyUrl,
    [switch]$NoStart,
    [switch]$NoAutostart
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings
if (-not $ProxyUrl) {
    $ProxyUrl = "http://127.0.0.1:$($Settings.Port)"
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
$BaseUrlMatch = [regex]::Match($ProviderBlock, $BaseUrlPattern)
if ($BaseUrlMatch.Success) {
    $CurrentBaseUrl = [regex]::Match(
        $BaseUrlMatch.Value,
        '=\s*"(?<url>[^"]+)"'
    ).Groups["url"].Value
    $IsProxyUrl = Test-OffloadProxyUrl -Url $CurrentBaseUrl
    if (-not $IsProxyUrl -and -not (Test-DeepSeekBaseUrl -Url $CurrentBaseUrl)) {
        throw (
            "Refusing to enable image offload: [model_providers.custom] " +
            "currently points to '$CurrentBaseUrl', not DeepSeek. " +
            "Set that provider to https://api.deepseek.com first. " +
            "The plugin will not redirect another provider's traffic."
        )
    }

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

if (-not $NoStart) {
    & (Join-Path $PSScriptRoot "start.ps1") | Write-Host
    if (-not (Test-OffloadHealth -Settings $Settings -TimeoutSec 3)) {
        throw "Image offload proxy did not become healthy at $ProxyUrl"
    }
}

if (-not $NoAutostart) {
    & (Join-Path $PSScriptRoot "install-autostart.ps1") | Write-Host
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
