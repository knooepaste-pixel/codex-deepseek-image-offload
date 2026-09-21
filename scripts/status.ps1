$ErrorActionPreference = "Stop"

$Port = if ($env:CODEX_IMAGE_OFFLOAD_PORT) {
    [int]$env:CODEX_IMAGE_OFFLOAD_PORT
} else {
    17891
}

try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3 |
        ConvertTo-Json -Depth 8
} catch {
    Write-Error "Image offload proxy is not reachable on port $Port"
}
