---
name: deepseek-image-offload
description: 配置、启用、禁用或诊断 Codex 的 DeepSeek 图片请求卸载本地中转。用户提到 DeepSeek 413、请求体过大、旧图片或视频帧反复发送、Codex DeepSeek 代理，或需要管理 deepseek-image-offload 时使用。
---

# DeepSeek Image Offload

This plugin runs a local Responses API proxy. Codex still keeps the full
conversation, but the proxy replaces old Base64 image blocks with short text
placeholders before forwarding a request to DeepSeek.

The plugin is only useful when the Codex custom provider's `base_url` points
to `http://127.0.0.1:17891`.

## Resolve Paths

Resolve all script paths relative to this skill directory:

```text
<plugin-root> = ../..
```

Run scripts with `pwsh.exe`, not Windows PowerShell 5.1.

## Status

Check the service first:

```powershell
pwsh.exe -NoLogo -NoProfile -File "<plugin-root>\scripts\status.ps1"
```

If it is not running, start it:

```powershell
pwsh.exe -NoLogo -NoProfile -File "<plugin-root>\scripts\start.ps1"
```

## Enable

Use the enable script. It starts the proxy, waits for its health endpoint, then
changes only the `base_url` inside `[model_providers.custom]` in
`~/.codex/config.toml`. It also installs a user logon task with a watchdog so
the proxy is restarted if it exits or stops responding. It creates a one-time
backup beside the config file.

```powershell
pwsh.exe -NoLogo -NoProfile -File "<plugin-root>\scripts\enable.ps1"
```

After enabling, tell the user to start a new Codex conversation so the changed
provider configuration is loaded. Do not claim this thread has switched
providers until a new thread is running through the proxy.

## Disable

Restore direct DeepSeek traffic, remove the logon task and watchdog, and stop the local
proxy.

```powershell
pwsh.exe -NoLogo -NoProfile -File "<plugin-root>\scripts\disable.ps1" -StopService
```

## Verify

After a new conversation has sent at least one request through the proxy, check:

```powershell
pwsh.exe -NoLogo -NoProfile -File "<plugin-root>\scripts\status.ps1"
```

The `stats.requests` value should increase. If an image-heavy request is
rewritten, `stats.requestsModified` and `stats.offloadedImages` should also
increase.

The default budgets are 44 MiB for the upstream request, 24 MiB of Base64
image payload, and 590 image items. The current user message and newest three
images are protected first. If the request is still too large, older protected
images are offloaded as well so the final request can stay valid.

## Safety Rules

- Do not edit `config.toml` by hand if `enable.ps1` or `disable.ps1` can do it.
- Do not stop the proxy while `[model_providers.custom]` still points at the
  local URL, because new DeepSeek turns would fail to reach the upstream.
- Use `stop.ps1` to remove the watchdog as well as the proxy. Only use
  `stop.ps1 -KeepAutostart` when a restart is intentional.
- Keep the proxy bound to `127.0.0.1`; do not expose it on the LAN.
- The proxy keeps the newest three images by default. Older images become
  placeholders and stay offloaded on later turns.
- Remote `https://` image URLs are not rewritten.
