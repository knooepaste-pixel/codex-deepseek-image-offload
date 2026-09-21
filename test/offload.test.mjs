import assert from "node:assert/strict";
import test from "node:test";

import {
  collectInputImages,
  offloadImages,
  totalImagePayloadBytes,
} from "../src/offload.mjs";

function dataUrl(payload, type = "image/png") {
  return `data:${type};base64,${payload}`;
}

test("collects nested input images", () => {
  const body = {
    input: [
      {
        role: "user",
        content: [
          { type: "input_image", image_url: dataUrl("AAAA") },
          {
            type: "function_call_output",
            output: [
              { type: "input_image", image_url: dataUrl("BBBB") },
            ],
          },
        ],
      },
    ],
  };

  const images = collectInputImages(body);
  assert.equal(images.length, 2);
  assert.equal(totalImagePayloadBytes(images), 52);
});

test("offloads oldest images until the image budget fits", () => {
  const body = {
    input: [
      { type: "input_image", image_url: dataUrl("A".repeat(100)) },
      { type: "input_image", image_url: dataUrl("B".repeat(100)) },
      { type: "input_image", image_url: dataUrl("C".repeat(100)) },
      { type: "input_image", image_url: dataUrl("D".repeat(100)) },
    ],
  };

  const result = offloadImages(body, {
    maxImagePayloadBytes: 250,
    keepLatestImages: 2,
    estimatedBodyBytes: 10,
    maxRequestBytes: 1000,
  });

  assert.equal(result.modified, true);
  assert.equal(result.offloaded.length, 2);
  assert.equal(body.input[0].type, "input_text");
  assert.match(body.input[0].text, /offloaded/i);
  assert.equal(body.input[1].type, "input_text");
  assert.equal(body.input[2].type, "input_image");
  assert.equal(body.input[3].type, "input_image");
});

test("keeps latest images when the body budget is already close", () => {
  const body = {
    input: [
      { type: "input_image", image_url: dataUrl("A".repeat(500)) },
      { type: "input_image", image_url: dataUrl("B".repeat(500)) },
    ],
  };

  const result = offloadImages(body, {
    maxImagePayloadBytes: 1000,
    keepLatestImages: 1,
    estimatedBodyBytes: 1200,
    maxRequestBytes: 1100,
  });

  assert.equal(result.modified, true);
  assert.equal(result.offloaded.length, 1);
  assert.equal(body.input[0].type, "input_text");
  assert.equal(body.input[1].type, "input_image");
});

test("can force the last protected image out when it alone exceeds the limit", () => {
  const body = {
    input: [
      { type: "input_image", image_url: dataUrl("A".repeat(100)) },
      { type: "input_image", image_url: dataUrl("B".repeat(100)) },
      { type: "input_image", image_url: dataUrl("C".repeat(100)) },
    ],
  };

  const result = offloadImages(body, {
    maxImagePayloadBytes: 250,
    maxImagesPerRequest: 600,
    keepLatestImages: 3,
    estimatedBodyBytes: 400,
    maxRequestBytes: 1000,
  });

  assert.equal(result.modified, true);
  assert.equal(result.offloaded.length, 1);
  assert.equal(body.input[0].type, "input_text");
  assert.equal(body.input[1].type, "input_image");
  assert.equal(body.input[2].type, "input_image");
  assert.equal(result.withinLimits, true);
});

test("enforces the provider image count limit", () => {
  const body = {
    input: Array.from({ length: 5 }, (_, index) => ({
      type: "input_image",
      image_url: dataUrl(`${index}`.repeat(10)),
    })),
  };

  const result = offloadImages(body, {
    maxImagePayloadBytes: 10_000,
    maxImagesPerRequest: 3,
    keepLatestImages: 2,
    estimatedBodyBytes: 500,
    maxRequestBytes: 10_000,
  });

  assert.equal(result.modified, true);
  assert.equal(result.offloaded.length, 2);
  assert.equal(result.remainingImageCount, 3);
  assert.equal(body.input[0].type, "input_text");
  assert.equal(body.input[1].type, "input_text");
  assert.equal(body.input[2].type, "input_image");
  assert.equal(body.input[3].type, "input_image");
  assert.equal(body.input[4].type, "input_image");
});

test("prefers tool screenshots over the latest user image", () => {
  const body = {
    input: [
      {
        role: "user",
        content: [
          { type: "input_image", image_url: dataUrl("U".repeat(100)) },
        ],
      },
      { role: "assistant", content: [
        { type: "input_image", image_url: dataUrl("T1".repeat(50)) },
      ] },
      { role: "assistant", content: [
        { type: "input_image", image_url: dataUrl("T2".repeat(50)) },
      ] },
      { role: "assistant", content: [
        { type: "input_image", image_url: dataUrl("T3".repeat(50)) },
      ] },
      { role: "assistant", content: [
        { type: "input_image", image_url: dataUrl("T4".repeat(50)) },
      ] },
    ],
  };

  const images = collectInputImages(body);
  assert.equal(images[0].latestUserMessage, true);

  const result = offloadImages(body, {
    maxImagePayloadBytes: 500,
    maxImagesPerRequest: 600,
    keepLatestImages: 2,
    estimatedBodyBytes: 1000,
    maxRequestBytes: 10_000,
  });

  assert.equal(result.modified, true);
  assert.equal(body.input[0].content[0].type, "input_image");
  assert.equal(body.input[1].content[0].type, "input_text");
});

test("does not offload remote image URLs unless the count limit requires it", () => {
  const body = {
    input: [
      {
        type: "input_image",
        image_url: "https://example.com/image.png",
      },
      { type: "input_image", image_url: dataUrl("B".repeat(100)) },
    ],
  };

  const result = offloadImages(body, {
    maxImagePayloadBytes: 10,
    maxImagesPerRequest: 600,
    keepLatestImages: 1,
    estimatedBodyBytes: 10,
    maxRequestBytes: 1000,
  });

  assert.equal(result.modified, true);
  assert.equal(body.input[0].type, "input_image");
  assert.equal(body.input[1].type, "input_text");
});

test("reports the exact serialized body size after rewriting", () => {
  const body = {
    input: [
      { type: "input_image", image_url: dataUrl("A".repeat(300)) },
      { type: "input_image", image_url: dataUrl("B".repeat(300)) },
      { type: "input_image", image_url: dataUrl("C".repeat(300)) },
    ],
  };
  const originalBodyBytes = Buffer.byteLength(JSON.stringify(body));

  const result = offloadImages(body, {
    maxImagePayloadBytes: 500,
    maxImagesPerRequest: 600,
    keepLatestImages: 1,
    estimatedBodyBytes: originalBodyBytes,
    maxRequestBytes: 1200,
  });

  assert.equal(result.modified, true);
  assert.equal(result.withinLimits, true);
  assert.equal(
    result.finalBodyBytes,
    Buffer.byteLength(result.serializedBody, "utf8"),
  );
  assert.ok(result.finalBodyBytes <= 1200);
});
