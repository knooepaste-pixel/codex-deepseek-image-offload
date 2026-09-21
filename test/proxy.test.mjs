import assert from "node:assert/strict";
import http from "node:http";
import { gzip } from "node:zlib";
import { promisify } from "node:util";
import test from "node:test";

import { createServer } from "../src/server.mjs";
import { createLogger } from "../src/logger.mjs";

const gzipAsync = promisify(gzip);

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function close(server) {
  return new Promise((resolve) => server.close(resolve));
}

function dataUrl(payload) {
  return `data:image/png;base64,${payload}`;
}

test("rewrites compressed responses request and streams upstream response", async () => {
  let receivedBody;
  let receivedEncoding;
  let receivedAuthorization;
  const upstream = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) {
      chunks.push(chunk);
    }
    receivedEncoding = req.headers["content-encoding"];
    receivedAuthorization = req.headers.authorization;
    const body = Buffer.concat(chunks);
    const { gunzip: gunzipCallback } = await import("node:zlib");
    receivedBody = await promisify(gunzipCallback)(body);
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "x-test-upstream": "yes",
    });
    res.write("data: one\n\n");
    res.end("data: two\n\n");
  });
  const upstreamPort = await listen(upstream);

  const config = {
    listenHost: "127.0.0.1",
    listenPort: 0,
    upstreamBaseUrl: `http://127.0.0.1:${upstreamPort}`,
    maxRequestBytes: 1200,
    maxImagePayloadBytes: 500,
    maxImagesPerRequest: 600,
    keepLatestImages: 1,
    maxIncomingBytes: 1024 * 1024,
    maxDecompressedBytes: 1024 * 1024,
    upstreamConnectTimeoutMs: 5000,
    upstreamIdleTimeoutMs: 5000,
    logLevel: "silent",
  };

  const proxy = await createServer(config, createLogger("silent"));
  const proxyPort = await listen(proxy);
  const requestBody = {
    model: "deepseek-flash",
    input: [
      { type: "input_image", image_url: dataUrl("A".repeat(300)) },
      { type: "input_image", image_url: dataUrl("B".repeat(300)) },
    ],
  };
  const compressed = await gzipAsync(Buffer.from(JSON.stringify(requestBody)));

  const response = await fetch(`http://127.0.0.1:${proxyPort}/responses`, {
    method: "POST",
    headers: {
      "content-encoding": "gzip",
      "content-type": "application/json",
      "authorization": "Bearer test-token",
    },
    body: compressed,
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-test-upstream"), "yes");
  assert.equal(receivedEncoding, "gzip");
  assert.equal(receivedAuthorization, "Bearer test-token");
  const forwarded = JSON.parse(receivedBody.toString("utf8"));
  assert.equal(forwarded.input[0].type, "input_text");
  assert.equal(forwarded.input[1].type, "input_image");
  assert.equal(await response.text(), "data: one\n\ndata: two\n\n");
  assert.equal(proxy.stats.requestsModified, 1);
  assert.equal(proxy.stats.offloadedImages, 1);

  await close(proxy);
  await close(upstream);
});

test("health endpoint reports configuration and stats", async () => {
  const config = {
    listenHost: "127.0.0.1",
    listenPort: 0,
    upstreamBaseUrl: "https://api.deepseek.com",
    maxRequestBytes: 1000,
    maxImagePayloadBytes: 500,
    maxImagesPerRequest: 590,
    keepLatestImages: 2,
    maxIncomingBytes: 1024,
    maxDecompressedBytes: 1024,
    upstreamConnectTimeoutMs: 5000,
    upstreamIdleTimeoutMs: 5000,
    logLevel: "silent",
  };
  const proxy = await createServer(config, createLogger("silent"));
  const port = await listen(proxy);
  const response = await fetch(`http://127.0.0.1:${port}/health`);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.upstreamBaseUrl, "https://api.deepseek.com");
  assert.equal(body.maxImagesPerRequest, 590);
  assert.equal(body.stats.requests, 0);
  await close(proxy);
});

test("rejects a compressed request that exceeds the decompressed safety limit", async () => {
  const config = {
    listenHost: "127.0.0.1",
    listenPort: 0,
    upstreamBaseUrl: "http://127.0.0.1:1",
    maxRequestBytes: 50,
    maxImagePayloadBytes: 40,
    maxImagesPerRequest: 590,
    keepLatestImages: 3,
    maxIncomingBytes: 1024,
    maxDecompressedBytes: 100,
    upstreamConnectTimeoutMs: 5000,
    upstreamIdleTimeoutMs: 5000,
    logLevel: "silent",
  };
  const proxy = await createServer(config, createLogger("silent"));
  const port = await listen(proxy);
  const compressed = await gzipAsync(Buffer.from("x".repeat(500)));

  const response = await fetch(`http://127.0.0.1:${port}/responses`, {
    method: "POST",
    headers: {
      "content-encoding": "gzip",
      "content-type": "application/json",
    },
    body: compressed,
  });

  assert.equal(response.status, 413);
  await close(proxy);
});
