# DeepSeek Image Offload for Codex

English | [简体中文](README.zh-CN.md)

A local Responses API proxy that strips stale Base64 images from Codex requests
before forwarding them to DeepSeek. It is designed for conversations where
previously inspected images or video frames remain in the transcript and make
later requests exceed the provider's HTTP request-size limit.

DeepSeek continues to see the complete conversation text. Only old image
payloads are replaced with short placeholders, so they are not resent on every
turn.

## What It Does

- Runs only on `127.0.0.1`, with the default port `17891`.
- Protects images in the current user message and the newest three images when
  possible.
- If the request is still too large, removes the oldest Base64 images until it
  fits within the configured request and image budgets.
- Enforces a 590-image request limit by default.
- Leaves remote `https://` image URLs unchanged.
- Does not modify conversation text or require a separate model call.

The request rewriting happens in `src/server.mjs`. Codex continues to use its
custom model provider, but that provider's `base_url` points at the local
proxy.

## Requirements

- Windows
- PowerShell 7 (`pwsh.exe`)
- Node.js 22.19 or newer
- Codex configured with a `[model_providers.custom]` provider for DeepSeek

## Quick Start

```powershell
git clone https://github.com/knooepaste-pixel/codex-deepseek-image-offload.git
Set-Location .\codex-deepseek-image-offload
pwsh.exe -NoLogo -NoProfile -File .\scripts\enable.ps1
```

`enable.ps1` starts the proxy, waits for its health endpoint, points
`[model_providers.custom].base_url` at `http://127.0.0.1:17891`, and installs a
logon shortcut. Open a new Codex conversation after enabling it so Codex loads
the updated provider configuration.

Check status:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\scripts\status.ps1
```

Disable the proxy and restore direct DeepSeek traffic:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\scripts\disable.ps1 -StopService
```

## Commands

```powershell
.\scripts\start.ps1
.\scripts\status.ps1
.\scripts\enable.ps1
.\scripts\disable.ps1
.\scripts\install-autostart.ps1
.\scripts\remove-autostart.ps1
.\scripts\stop.ps1
```

`enable.ps1` creates a one-time backup beside `~/.codex/config.toml` before
changing the provider base URL.

The proxy accepts up to 256 MiB of incoming request data and protects
decompression with a separate 256 MiB limit.

## Configuration

Copy `config.example.json` to `config.json`, or set
`CODEX_IMAGE_OFFLOAD_CONFIG` to another configuration file. Environment
variables override file values. The main limits are:

| Option | Default | Purpose |
| --- | ---: | --- |
| `listenPort` | `17891` | Local proxy port |
| `upstreamBaseUrl` | `https://api.deepseek.com` | DeepSeek API base URL |
| `maxRequestBytes` | `44 MiB` | Maximum upstream request body |
| `maxImagePayloadBytes` | `24 MiB` | Maximum Base64 image budget |
| `maxImagesPerRequest` | `590` | Maximum number of image items |
| `keepLatestImages` | `3` | Newest images protected when possible |

See `config.example.json` and `src/config.mjs` for all supported options and
environment variables.

## Development

```powershell
npm test
```

The project uses only Node.js built-in modules and has no runtime
dependencies.

## Safety

- Keep the proxy bound to `127.0.0.1`; do not expose it to your LAN.
- Do not stop the proxy while the custom provider still points at its local
  URL, because new DeepSeek requests would fail to reach the upstream.
- The proxy can remove old visual evidence from the upstream request. Keep the
  original images locally if they may be needed later.

## License

MIT
