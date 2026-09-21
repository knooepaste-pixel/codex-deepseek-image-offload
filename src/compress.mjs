import {
  brotliCompress,
  brotliDecompress,
  deflate,
  gunzip,
  gzip,
  inflate,
  zstdCompress,
  zstdDecompress,
} from "node:zlib";
import { promisify } from "node:util";

const brotliCompressAsync = promisify(brotliCompress);
const brotliDecompressAsync = promisify(brotliDecompress);
const deflateAsync = promisify(deflate);
const gunzipAsync = promisify(gunzip);
const gzipAsync = promisify(gzip);
const inflateAsync = promisify(inflate);
const zstdCompressAsync = zstdCompress ? promisify(zstdCompress) : undefined;
const zstdDecompressAsync = zstdDecompress
  ? promisify(zstdDecompress)
  : undefined;

function normalizeEncoding(value) {
  return String(value ?? "")
    .split(",")
    .map((part) => part.trim().toLowerCase())
    .filter(Boolean);
}

export function getContentEncoding(headers) {
  const value = headers["content-encoding"];
  const encodings = normalizeEncoding(Array.isArray(value) ? value[0] : value);
  if (encodings.length > 1) {
    return encodings.join(",");
  }
  return encodings[0] ?? "identity";
}

function requestTooLarge(message) {
  const error = new Error(message);
  error.code = "ERR_REQUEST_TOO_LARGE";
  return error;
}

async function decompressWithLimit(
  decompress,
  buffer,
  maxOutputLength,
) {
  const options = maxOutputLength ? { maxOutputLength } : undefined;
  try {
    return await decompress(buffer, options);
  } catch (error) {
    if (
      error.code === "ERR_BUFFER_TOO_LARGE" ||
      error.code === "ERR_OUT_OF_RANGE"
    ) {
      throw requestTooLarge(
        `Decompressed request exceeds ${maxOutputLength} bytes`,
      );
    }
    throw error;
  }
}

export async function decompressBody(
  buffer,
  encoding,
  { maxOutputLength } = {},
) {
  switch (normalizeEncoding(encoding)[0] ?? "identity") {
    case "identity":
    case undefined:
      if (maxOutputLength && buffer.length > maxOutputLength) {
        throw requestTooLarge(
          `Decompressed request exceeds ${maxOutputLength} bytes`,
        );
      }
      return buffer;
    case "gzip":
    case "x-gzip":
      return decompressWithLimit(gunzipAsync, buffer, maxOutputLength);
    case "deflate":
      return decompressWithLimit(inflateAsync, buffer, maxOutputLength);
    case "br":
      return decompressWithLimit(
        brotliDecompressAsync,
        buffer,
        maxOutputLength,
      );
    case "zstd":
      if (!zstdDecompressAsync) {
        throw new Error("Node.js zstd decompression is unavailable");
      }
      return decompressWithLimit(
        zstdDecompressAsync,
        buffer,
        maxOutputLength,
      );
    default:
      throw new Error(`Unsupported content encoding: ${encoding}`);
  }
}

export async function compressBody(buffer, encoding) {
  switch (normalizeEncoding(encoding)[0] ?? "identity") {
    case "identity":
    case undefined:
      return buffer;
    case "gzip":
    case "x-gzip":
      return gzipAsync(buffer);
    case "deflate":
      return deflateAsync(buffer);
    case "br":
      return brotliCompressAsync(buffer);
    case "zstd":
      if (!zstdCompressAsync) {
        throw new Error("Node.js zstd compression is unavailable");
      }
      return zstdCompressAsync(buffer);
    default:
      throw new Error(`Unsupported content encoding: ${encoding}`);
  }
}

export function supportsContentEncoding(encoding) {
  const first = normalizeEncoding(encoding)[0] ?? "identity";
  if (first === "zstd") {
    return Boolean(zstdCompressAsync && zstdDecompressAsync);
  }
  return ["identity", "gzip", "x-gzip", "deflate", "br"].includes(first);
}
