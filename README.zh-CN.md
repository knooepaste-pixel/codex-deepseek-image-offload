# 给 Codex 用的 DeepSeek 图片卸载代理

[English](README.md) | 简体中文

这是一个运行在本机的 Responses API 代理。它会在 Codex 把请求转发给
DeepSeek 之前，把历史消息里过期的 Base64 图片替换成短文本占位符，避免图片
或视频帧在后续每一轮对话中反复发送，最终触发 HTTP 413“请求体过大”。

DeepSeek 仍然可以看到完整的对话文字。被卸载的是旧图片，不是当前对话内容，
也不需要额外调用模型来总结或压缩上下文。

## 解决什么问题

视频抽帧、截图或连续图片进入上下文后，即使后续问题已经不再需要这些画面，
它们仍可能以 Base64 形式保留在对话历史中。随着对话继续，请求体会不断增加，
最终超过 DeepSeek 接口的请求大小限制。

本代理只处理发往 DeepSeek 的请求：

- 优先保留当前用户消息中的图片；
- 优先保留最新的三张图片；
- 如果请求仍然过大，从最早的历史图片开始替换，直到请求符合配置上限；
- 默认最多允许 590 个图片项；
- 远程 `https://` 图片 URL 不会被改写；
- 修改仅发生在本地请求转发阶段，不需要改变 Codex 的工作方式。

## 运行方式

代理默认只监听本机地址 `127.0.0.1:17891`。Codex 仍然使用自己的
`[model_providers.custom]` 配置，只是把其中的 `base_url` 指向本地代理。

```text
Codex -> 127.0.0.1:17891 -> https://api.deepseek.com
```

## 环境要求

- Windows
- PowerShell 7（`pwsh.exe`）
- Node.js 22.19 或更高版本
- Codex 已配置用于 DeepSeek 的 `[model_providers.custom]`

## 快速开始

```powershell
git clone https://github.com/knooepaste-pixel/codex-deepseek-image-offload.git
Set-Location .\codex-deepseek-image-offload
pwsh.exe -NoLogo -NoProfile -File .\scripts\enable.ps1
```

`enable.ps1` 会完成以下操作：

1. 启动本地代理并等待健康检查通过；
2. 把 `[model_providers.custom].base_url` 改为
   `http://127.0.0.1:17891`；
3. 安装登录时自动启动代理的快捷方式；
4. 在修改配置前创建一次备份。

启用后请新建一个 Codex 对话，让 Codex 重新读取 provider 配置。

检查运行状态：

```powershell
pwsh.exe -NoLogo -NoProfile -File .\scripts\status.ps1
```

关闭代理并恢复直连 DeepSeek：

```powershell
pwsh.exe -NoLogo -NoProfile -File .\scripts\disable.ps1 -StopService
```

## 常用命令

```powershell
.\scripts\start.ps1
.\scripts\status.ps1
.\scripts\enable.ps1
.\scripts\disable.ps1
.\scripts\install-autostart.ps1
.\scripts\remove-autostart.ps1
.\scripts\stop.ps1
```

代理最多接收 256 MiB 的压缩请求数据，并单独限制解压后的内容为 256 MiB。

## 配置

可以把 `config.example.json` 复制为 `config.json`，也可以通过
`CODEX_IMAGE_OFFLOAD_CONFIG` 指向其他配置文件。环境变量会覆盖文件中的值。

主要配置项：

| 配置项 | 默认值 | 作用 |
| --- | ---: | --- |
| `listenPort` | `17891` | 本地代理端口 |
| `upstreamBaseUrl` | `https://api.deepseek.com` | DeepSeek API 地址 |
| `maxRequestBytes` | `44 MiB` | 最大上游请求体 |
| `maxImagePayloadBytes` | `24 MiB` | 最大 Base64 图片预算 |
| `maxImagesPerRequest` | `590` | 最大图片项数量 |
| `keepLatestImages` | `3` | 优先保留的最新图片数量 |

完整配置和环境变量说明见 `config.example.json` 与 `src/config.mjs`。

## 开发

```powershell
npm test
```

项目只使用 Node.js 内置模块，不包含运行时依赖。

## 安全注意

- 保持代理只绑定 `127.0.0.1`，不要暴露到局域网；
- 当 custom provider 仍指向本地代理时，不要直接停止代理；
- 代理会从上游请求中移除旧图片。如果后续仍可能需要这些图片，请保留本地原图。

## 许可证

MIT
