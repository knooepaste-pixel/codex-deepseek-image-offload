#!/usr/bin/env node

import http from "node:http";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import path from "node:path";

import {
  compressBody,
  decompressBody,
  getContentEncoding,
  supportsContentEncoding,
} from "./compress.mjs";
import { loadConfig } from "./config.mjs";
import { createLogger } from "./logger.mjs";
import { offloadImages } from "./offload.mjs";

const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

function requestTooLarge(message) {
  const error = new Error(message);
  error.code = "ERR_REQUEST_TOO_LARGE";
  return error;
}

function copyResponseHeaders(headers) {
  const result = {};
  for (const [name, value] of headers.entries()) {
    if (!HOP_BY_HOP_HEADERS.has(name.toLowerCase())) {
      result[name] = value;
    }
  }
  return result;
}

async function readRequestBody(req, maxBytes) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > maxBytes) {
      throw requestTooLarge(`Incoming request exceeds ${maxBytes} bytes`);
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function buildUpstreamUrl(baseUrl, requestUrl) {
  const base = new URL(`${baseUrl}/`);
  const incoming = new URL(requestUrl, "http://localhost");
  const basePath = base.pathname.replace(/\/+$/, "");
  const incomingPath = incoming.pathname.startsWith("/")
    ? incoming.pathname
    : `/${incoming.pathname}`;
  base.pathname = `${basePath}${incomingPath}`.replace(/\/{2,}/g, "/");
  base.search = incoming.search;
  return base;
}

function buildUpstreamHeaders(req, bodyBuffer) {
  const headers = {};
  for (const [name, value] of Object.entries(req.headers)) {
    if (value === undefined) {
      continue;
    }
    const lower = name.toLowerCase();
    if (
      lower === "host" ||
      lower === "content-length" ||
      lower === "accept-encoding" ||
      HOP_BY_HOP_HEADERS.has(lower)
    ) {
      continue;
    }
    headers[name] = value;
  }
  headers["accept-encoding"] = "identity";
  headers["content-length"] = String(bodyBuffer.length);
  return headers;
}

function shouldProcessRequest(req) {
  return req.method === "POST";
}

function sendJson(res, statusCode, body) {
  const payload = Buffer.from(`${JSON.stringify(body, null, 2)}\n`);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "content-length": String(payload.length),
    "cache-control": "no-store",
  });
  res.end(payload);
}

async function proxyRequest(req, res, config, logger, stats) {
  const requestStartedAt = performance.now();
  const originalBody = await readRequestBody(req, config.maxIncomingBytes);
  const originalEncoding = getContentEncoding(req.headers);
  let bodyForUpstream = originalBody;
  let encodingForUpstream = originalEncoding;
  let offloadResult;

  if (shouldProcessRequest(req) && originalBody.length > 0) {
    if (!supportsContentEncoding(originalEncoding)) {
      logger.warn("Unsupported request content encoding; forwarding unchanged", {
        contentEncoding: originalEncoding,
        path: req.url,
      });
    } else {
      try {
        const decompressed = await decompressBody(
          originalBody,
          originalEncoding,
          {
            maxOutputLength: config.maxDecompressedBytes,
          },
        );
        const parsed = JSON.parse(decompressed.toString("utf8"));

        offloadResult = offloadImages(parsed, {
          maxImagePayloadBytes: config.maxImagePayloadBytes,
          maxImagesPerRequest: config.maxImagesPerRequest,
          keepLatestImages: config.keepLatestImages,
          estimatedBodyBytes: decompressed.length,
          maxRequestBytes: config.maxRequestBytes,
        });

        if (offloadResult.modified) {
          const rewritten = Buffer.from(
            offloadResult.serializedBody ?? JSON.stringify(parsed),
            "utf8",
          );
          bodyForUpstream = await compressBody(rewritten, originalEncoding);
          stats.offloadedImages += offloadResult.offloaded.length;
        }
      } catch (error) {
        if (error.code === "ERR_REQUEST_TOO_LARGE") {
          throw error;
        }
        logger.warn("Request could not be inspected; forwarding unchanged", {
          path: req.url,
          error: error.message,
        });
      }
    }
  }

  stats.requests += 1;
  stats.lastRequestAt = new Date().toISOString();
  if (offloadResult?.modified) {
    stats.requestsModified += 1;
    stats.lastOffload = {
      at: stats.lastRequestAt,
      path: req.url,
      count: offloadResult.offloaded.length,
      originalImageBytes: offloadResult.originalImageBytes,
      remainingImageBytes: offloadResult.remainingImageBytes,
      remainingImageCount: offloadResult.remainingImageCount,
      finalBodyBytes: offloadResult.finalBodyBytes,
      withinLimits: offloadResult.withinLimits,
      upstreamBodyBytes: bodyForUpstream.length,
    };
    logger.info("Offloaded stale request images", {
      path: req.url,
      count: offloadResult.offloaded.length,
      originalImageBytes: offloadResult.originalImageBytes,
      remainingImageBytes: offloadResult.remainingImageBytes,
      remainingImageCount: offloadResult.remainingImageCount,
      finalBodyBytes: offloadResult.finalBodyBytes,
      withinLimits: offloadResult.withinLimits,
      upstreamBodyBytes: bodyForUpstream.length,
    });
    if (!offloadResult.withinLimits) {
      logger.warn("Image offload could not bring request within all limits", {
        path: req.url,
        remainingImageBytes: offloadResult.remainingImageBytes,
        remainingImageCount: offloadResult.remainingImageCount,
        finalBodyBytes: offloadResult.finalBodyBytes,
      });
    }
  } else {
    logger.debug("Forwarding request unchanged", {
      path: req.url,
      requestBytes: originalBody.length,
    });
  }

  const upstreamUrl = buildUpstreamUrl(config.upstreamBaseUrl, req.url);
  const upstreamHeaders = buildUpstreamHeaders(req, bodyForUpstream);
  if (encodingForUpstream !== "identity") {
    upstreamHeaders["content-encoding"] = encodingForUpstream;
  }

  const controller = new AbortController();
  let clientAborted = false;
  req.on("aborted", () => {
    clientAborted = true;
    controller.abort();
  });
  res.on("close", () => {
    if (!res.writableEnded) {
      clientAborted = true;
      controller.abort();
    }
  });

  let headerTimeout;
  let upstreamResponse;
  try {
    headerTimeout = setTimeout(
      () => controller.abort(new Error("Upstream response headers timed out")),
      config.upstreamConnectTimeoutMs,
    );
    upstreamResponse = await fetch(upstreamUrl, {
      method: req.method,
      headers: upstreamHeaders,
      body: bodyForUpstream,
      signal: controller.signal,
      redirect: "manual",
    });
  } catch (error) {
    if (clientAborted) {
      return;
    }
    const timedOut = controller.signal.aborted;
    logger.error("Upstream request failed", {
      path: req.url,
      error: error.message,
    });
    sendJson(res, timedOut ? 504 : 502, {
      error: {
        message: "Codex DeepSeek Image Offload could not reach upstream",
        detail: error.message,
      },
    });
    return;
  } finally {
    clearTimeout(headerTimeout);
  }

  res.writeHead(
    upstreamResponse.status,
    copyResponseHeaders(upstreamResponse.headers),
  );

  if (!upstreamResponse.body) {
    res.end();
  } else {
    let idleTimeout;
    const source = Readable.fromWeb(upstreamResponse.body);
    const armIdleTimeout = () => {
      clearTimeout(idleTimeout);
      idleTimeout = setTimeout(
        () => controller.abort(new Error("Upstream response stream timed out")),
        config.upstreamIdleTimeoutMs,
      );
    };
    source.on("data", armIdleTimeout);
    armIdleTimeout();
    try {
      await pipeline(source, res);
    } finally {
      clearTimeout(idleTimeout);
    }
  }

  const elapsedMs = Math.round(performance.now() - requestStartedAt);
  logger.debug("Proxy request complete", {
    path: req.url,
    status: upstreamResponse.status,
    elapsedMs,
  });
}

export async function createServer(config, logger = createLogger(config.logLevel)) {
  const stats = {
    startedAt: new Date().toISOString(),
    requests: 0,
    requestsModified: 0,
    offloadedImages: 0,
    lastRequestAt: null,
    lastOffload: null,
  };

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, "http://localhost");
      if (req.method === "GET" && url.pathname === "/health") {
        sendJson(res, 200, {
          ok: true,
          service: "codex-deepseek-image-offload",
          upstreamBaseUrl: config.upstreamBaseUrl,
          maxRequestBytes: config.maxRequestBytes,
          maxImagePayloadBytes: config.maxImagePayloadBytes,
          maxImagesPerRequest: config.maxImagesPerRequest,
          keepLatestImages: config.keepLatestImages,
          stats,
        });
        return;
      }

      if (
        req.method === "GET" &&
        url.pathname === "/__codex-image-offload/stats"
      ) {
        sendJson(res, 200, stats);
        return;
      }

      await proxyRequest(req, res, config, logger, stats);
    } catch (error) {
      logger.error("Proxy request error", {
        path: req.url,
        error: error.message,
      });
      if (!res.headersSent) {
        const statusCode = error.code === "ERR_REQUEST_TOO_LARGE"
          ? 413
          : 500;
        sendJson(res, statusCode, {
          error: {
            message: error.message,
          },
        });
      } else {
        res.destroy(error);
      }
    }
  });

  server.stats = stats;
  return server;
}

export async function startServer({
  configPath,
  env = process.env,
} = {}) {
  const config = await loadConfig({ configPath, env });
  const logger = createLogger(config.logLevel);
  const server = await createServer(config, logger);

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.listenPort, config.listenHost, resolve);
  });

  logger.info("Codex DeepSeek Image Offload listening", {
    url: `http://${config.listenHost}:${config.listenPort}`,
    upstreamBaseUrl: config.upstreamBaseUrl,
    maxRequestBytes: config.maxRequestBytes,
    maxImagePayloadBytes: config.maxImagePayloadBytes,
    maxImagesPerRequest: config.maxImagesPerRequest,
    keepLatestImages: config.keepLatestImages,
  });

  return {
    config,
    logger,
    server,
  };
}

const isDirectRun =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isDirectRun) {
  const { server, logger } = await startServer();
  const shutdown = async () => {
    logger.info("Shutting down");
    await new Promise((resolve) => server.close(resolve));
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}
