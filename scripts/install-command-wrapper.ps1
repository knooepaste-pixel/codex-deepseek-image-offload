[CmdletBinding()]
param(
    [string]$RuntimeRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "service-common.ps1")

$Settings = Get-OffloadServiceSettings
New-Item -ItemType Directory -Force -Path $Settings.LogDir | Out-Null

$PluginFamilyRoot = Split-Path -Parent $Settings.Root
$EscapedPluginFamilyRoot = $PluginFamilyRoot.Replace("'", "''")

if ($RuntimeRoot) {
    $ResolvedRuntimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot).Path
    if (-not (Test-Path -LiteralPath (Join-Path $ResolvedRuntimeRoot "src\server.mjs"))) {
        throw "Runtime root does not contain src\server.mjs: $ResolvedRuntimeRoot"
    }

    $EscapedRuntimeRoot = $ResolvedRuntimeRoot.Replace("'", "''")
    $Resolver = "`$PluginRoot = '$EscapedRuntimeRoot'"
} else {
    $Resolver = @'
$Candidates = @(
    Get-ChildItem `
        -LiteralPath $PluginFamilyRoot `
        -Directory `
        -ErrorAction SilentlyContinue |
        Where-Object {
            Test-Path -LiteralPath (
                Join-Path $_.FullName 'src\server.mjs'
            )
        } |
        ForEach-Object {
            $CandidateVersion = [version]'0.0.0'
            try {
                $CandidateVersion = [version](
                    Split-Path -Leaf $_.FullName
                )
            } catch {
                # Keep invalid version folders as the lowest-priority option.
            }
            [pscustomobject]@{
                Path = $_.FullName
                Version = $CandidateVersion
                LastWriteTime = $_.LastWriteTime
            }
        } |
        Sort-Object `
            -Property Version, LastWriteTime `
            -Descending
)

if ($Candidates.Count -eq 0) {
    throw "No installed image offload runtime was found."
}

$PluginRoot = $Candidates[0].Path
'@
}

$Wrapper = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'status',
        'start',
        'stop',
        'restart',
        'enable',
        'direct',
        'disable'
    )]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
$PluginFamilyRoot = '__PLUGIN_FAMILY_ROOT__'

__PLUGIN_ROOT_RESOLVER__

$Scripts = Join-Path $PluginRoot 'scripts'
if (-not (Test-Path -LiteralPath (Join-Path $PluginRoot 'src\server.mjs'))) {
    throw "Image offload runtime is missing: $PluginRoot"
}

switch ($Action) {
    'status' {
        & (Join-Path $Scripts 'status.ps1')
    }
    'start' {
        & (Join-Path $Scripts 'install-autostart.ps1')
        & (Join-Path $Scripts 'start.ps1')
    }
    'stop' {
        & (Join-Path $Scripts 'stop.ps1')
    }
    'restart' {
        & (Join-Path $Scripts 'stop.ps1') -KeepAutostart
        & (Join-Path $Scripts 'install-autostart.ps1')
        & (Join-Path $Scripts 'start.ps1')
    }
    'enable' {
        & (Join-Path $Scripts 'enable.ps1')
    }
    'direct' {
        & (Join-Path $Scripts 'disable.ps1') -KeepAutostart
        & (Join-Path $Scripts 'install-autostart.ps1')
        & (Join-Path $Scripts 'start.ps1')
    }
    'disable' {
        & (Join-Path $Scripts 'disable.ps1') -StopService
    }
}
'@

$Wrapper = $Wrapper.Replace(
    "__PLUGIN_FAMILY_ROOT__",
    $EscapedPluginFamilyRoot
).Replace(
    "__PLUGIN_ROOT_RESOLVER__",
    $Resolver
)

[System.IO.File]::WriteAllText(
    $Settings.OffloadPath,
    $Wrapper,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Output "command-wrapper-installed:$($Settings.OffloadPath)"
