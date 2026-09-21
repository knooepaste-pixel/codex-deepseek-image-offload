import { readFile } from "node:fs/promises";
import path from "node:path";

const DEFAULTS = {
  listenHost: "127.0.0.1",
  listenPort: 17891,
  upstreamBaseUrl: "https://api.deepseek.com",
  maxRequestBytes: 44 * 1024 * 1024,
  maxImagePayloadBytes: 24 * 1024 * 1024,
  maxImagesPerRequest: 590,
  keepLatestImages: 3,
  maxIncomingBytes: 256 * 1024 * 1024,
  maxDecompressedBytes: 256 * 1024 * 1024,
  upstreamConnectTimeoutMs: 30_000,
  upstreamIdleTimeoutMs: 120_000,
  logLevel: "info",
};

function parseInteger(value, name) {
  if (value === undefined || value === null || value === "") {
    return undefined;
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

function normalizeBaseUrl(value) {
  const url = new URL(value);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("upstreamBaseUrl must use http or https");
  }
  return url.toString().replace(/\/+$/, "");
}

export async function loadConfig({ configPath, env = process.env } = {}) {
  let fileConfig = {};
  const resolvedConfigPath = configPath
    ? path.resolve(configPath)
    : env.CODEX_IMAGE_OFFLOAD_CONFIG
      ? path.resolve(env.CODEX_IMAGE_OFFLOAD_CONFIG)
      : undefined;

  if (resolvedConfigPath) {
    const raw = await readFile(resolvedConfigPath, "utf8");
    fileConfig = JSON.parse(raw);
  }

  const config = {
    ...DEFAULTS,
    ...fileConfig,
  };

  config.listenHost =
    env.CODEX_IMAGE_OFFLOAD_HOST ?? config.listenHost;
  config.listenPort =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_PORT,
      "CODEX_IMAGE_OFFLOAD_PORT",
    ) ?? parseInteger(config.listenPort, "listenPort");
  config.upstreamBaseUrl = normalizeBaseUrl(
    env.CODEX_IMAGE_OFFLOAD_UPSTREAM ?? config.upstreamBaseUrl,
  );
  config.maxRequestBytes =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_MAX_REQUEST_BYTES,
      "CODEX_IMAGE_OFFLOAD_MAX_REQUEST_BYTES",
    ) ?? parseInteger(config.maxRequestBytes, "maxRequestBytes");
  config.maxImagePayloadBytes =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_MAX_IMAGE_BYTES,
      "CODEX_IMAGE_OFFLOAD_MAX_IMAGE_BYTES",
    ) ?? parseInteger(config.maxImagePayloadBytes, "maxImagePayloadBytes");
  config.maxImagesPerRequest =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_MAX_IMAGES,
      "CODEX_IMAGE_OFFLOAD_MAX_IMAGES",
    ) ?? parseInteger(config.maxImagesPerRequest, "maxImagesPerRequest");
  config.keepLatestImages =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_KEEP_LATEST,
      "CODEX_IMAGE_OFFLOAD_KEEP_LATEST",
    ) ?? parseInteger(config.keepLatestImages, "keepLatestImages");
  config.maxIncomingBytes =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_MAX_INCOMING_BYTES,
      "CODEX_IMAGE_OFFLOAD_MAX_INCOMING_BYTES",
    ) ?? parseInteger(config.maxIncomingBytes, "maxIncomingBytes");
  config.maxDecompressedBytes =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_MAX_DECOMPRESSED_BYTES,
      "CODEX_IMAGE_OFFLOAD_MAX_DECOMPRESSED_BYTES",
    ) ?? parseInteger(config.maxDecompressedBytes, "maxDecompressedBytes");
  config.upstreamConnectTimeoutMs =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_CONNECT_TIMEOUT_MS,
      "CODEX_IMAGE_OFFLOAD_CONNECT_TIMEOUT_MS",
    ) ?? parseInteger(
      config.upstreamConnectTimeoutMs,
      "upstreamConnectTimeoutMs",
    );
  config.upstreamIdleTimeoutMs =
    parseInteger(
      env.CODEX_IMAGE_OFFLOAD_IDLE_TIMEOUT_MS,
      "CODEX_IMAGE_OFFLOAD_IDLE_TIMEOUT_MS",
    ) ?? parseInteger(
      config.upstreamIdleTimeoutMs,
      "upstreamIdleTimeoutMs",
    );
  config.logLevel =
    env.CODEX_IMAGE_OFFLOAD_LOG_LEVEL ?? config.logLevel;
  config.configPath = resolvedConfigPath;

  if (config.maxImagePayloadBytes >= config.maxRequestBytes) {
    throw new Error(
      "maxImagePayloadBytes must be smaller than maxRequestBytes",
    );
  }
  if (config.maxDecompressedBytes < config.maxRequestBytes) {
    throw new Error(
      "maxDecompressedBytes must be at least maxRequestBytes",
    );
  }

  return config;
}

export { DEFAULTS };
