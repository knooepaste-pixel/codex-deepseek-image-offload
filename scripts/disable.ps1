[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $HOME ".codex\config.toml"),
    [string]$DeepSeekBaseUrl = "https://api.deepseek.com",
    [switch]$StopService,
    [switch]$KeepAutostart
)

$ErrorActionPreference = "Stop"

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
if (-not [regex]::IsMatch($ProviderBlock, $BaseUrlPattern)) {
    throw "Could not find base_url in [model_providers.custom]"
}

$UpdatedBlock = [regex]::Replace(
    $ProviderBlock,
    $BaseUrlPattern,
    "base_url = `"$DeepSeekBaseUrl`""
)

if ($UpdatedBlock -ne $ProviderBlock) {
    $UpdatedContent = $Content.Remove(
        $ProviderMatch.Index,
        $ProviderMatch.Length
    ).Insert($ProviderMatch.Index, $UpdatedBlock)

    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($ConfigPath, $UpdatedContent, $Utf8NoBom)
}

Write-Output "disabled:$DeepSeekBaseUrl"
Write-Output "restart-codex-thread-required"

if (-not $KeepAutostart) {
    & (Join-Path $PSScriptRoot "remove-autostart.ps1") | Write-Host
}

if ($StopService) {
    & (Join-Path $PSScriptRoot "stop.ps1") | Write-Host
}
