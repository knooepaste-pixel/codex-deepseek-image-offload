const IMAGE_TYPE = "input_image";
const TEXT_TYPE = "input_text";
const SIZE_MARGIN_BYTES = 64 * 1024;

function utf8Bytes(value) {
  return Buffer.byteLength(value, "utf8");
}

function isDataImageUrl(value) {
  return (
    typeof value === "string" &&
    /^data:image\/[a-z0-9.+-]+;base64,/i.test(value)
  );
}

function makePlaceholder({ index, bytes }) {
  return (
    `[Image ${index + 1} was offloaded by Codex DeepSeek Image Offload ` +
    `to keep the request below the provider body limit. ` +
    `Original encoded image payload: ${bytes} bytes. ` +
    `The image was previously available in this conversation but is no ` +
    `longer included in this request.]`
  );
}

export function collectInputImages(root) {
  const images = [];
  let messageIndex = -1;

  function visit(value, context) {
    if (!value || typeof value !== "object") {
      return;
    }

    if (Array.isArray(value)) {
      for (const item of value) {
        visit(item, context);
      }
      return;
    }

    let nextContext = context;
    if (typeof value.role === "string") {
      messageIndex += 1;
      nextContext = {
        messageIndex,
        role: value.role,
      };
    }

    if (
      value.type === IMAGE_TYPE &&
      typeof value.image_url === "string"
    ) {
      images.push({
        node: value,
        imageUrl: value.image_url,
        bytes: utf8Bytes(value.image_url),
        base64Image: isDataImageUrl(value.image_url),
        messageIndex: nextContext.messageIndex,
        role: nextContext.role,
        userMessage: nextContext.role === "user",
      });
    }

    for (const child of Object.values(value)) {
      if (child && typeof child === "object") {
        visit(child, nextContext);
      }
    }
  }

  visit(root, {
    messageIndex: -1,
    role: null,
  });

  const latestUserMessageIndex = images.reduce(
    (latest, image) =>
      image.userMessage ? Math.max(latest, image.messageIndex) : latest,
    -1,
  );
  for (const image of images) {
    image.latestUserMessage =
      image.userMessage && image.messageIndex === latestUserMessageIndex;
  }

  return images;
}

export function totalImagePayloadBytes(images) {
  return images.reduce((sum, image) => sum + image.bytes, 0);
}

function replaceImage(image, index) {
  const node = image.node;
  const placeholder = makePlaceholder({
    index,
    bytes: image.bytes,
  });
  delete node.image_url;
  delete node.detail;
  node.type = TEXT_TYPE;
  node.text = placeholder;
  return utf8Bytes(placeholder);
}

export function offloadImages(
  body,
  {
    maxImagePayloadBytes,
    maxImagesPerRequest = Number.POSITIVE_INFINITY,
    keepLatestImages,
    estimatedBodyBytes = 0,
    maxRequestBytes = Number.POSITIVE_INFINITY,
  },
) {
  const images = collectInputImages(body);
  const originalImageBytes = totalImagePayloadBytes(images);
  const originalImageCount = images.length;
  const originalEstimatedBodyBytes = estimatedBodyBytes;
  let imageBytes = originalImageBytes;
  let imageCount = originalImageCount;
  let estimatedCurrentBodyBytes = estimatedBodyBytes;
  let serializedBody;
  const offloaded = [];
  const offloadedIndexes = new Set();

  const preferredIndexes = new Set();
  const newestProtectedStart = Math.max(
    0,
    images.length - keepLatestImages,
  );
  for (let index = newestProtectedStart; index < images.length; index += 1) {
    preferredIndexes.add(index);
  }
  for (let index = 0; index < images.length; index += 1) {
    if (images[index].latestUserMessage) {
      preferredIndexes.add(index);
    }
  }

  const nonPreferredIndexes = [];
  const preferredIndexesInOrder = [];
  for (let index = 0; index < images.length; index += 1) {
    if (preferredIndexes.has(index)) {
      preferredIndexesInOrder.push(index);
    } else {
      nonPreferredIndexes.push(index);
    }
  }

  function needsCountReduction() {
    return imageCount > maxImagesPerRequest;
  }

  function cheapWithinLimits() {
    return (
      imageBytes <= maxImagePayloadBytes &&
      imageCount <= maxImagesPerRequest &&
      estimatedCurrentBodyBytes <= maxRequestBytes
    );
  }

  function serializeBody() {
    if (serializedBody === undefined) {
      serializedBody = JSON.stringify(body);
    }
    return utf8Bytes(serializedBody);
  }

  function offloadOne(index) {
    if (offloadedIndexes.has(index)) {
      return false;
    }
    const image = images[index];
    const countReductionNeeded = needsCountReduction();
    const payloadReductionNeeded = imageBytes > maxImagePayloadBytes;
    if (!image.base64Image && !countReductionNeeded) {
      return false;
    }
    const estimatedPlaceholderBytes = utf8Bytes(
      makePlaceholder({
        index,
        bytes: image.bytes,
      }),
    );
    if (
      !countReductionNeeded &&
      !payloadReductionNeeded &&
      estimatedPlaceholderBytes >= image.bytes
    ) {
      return false;
    }

    const placeholderBytes = replaceImage(image, index);
    offloadedIndexes.add(index);
    imageBytes -= image.bytes;
    imageCount -= 1;
    estimatedCurrentBodyBytes = Math.max(
      0,
      estimatedCurrentBodyBytes -
        Math.max(0, image.bytes - placeholderBytes),
    );
    serializedBody = undefined;
    offloaded.push({
      index,
      bytes: image.bytes,
      userMessage: image.userMessage,
      latestUserMessage: image.latestUserMessage,
    });
    return true;
  }

  for (const candidates of [
    nonPreferredIndexes,
    preferredIndexesInOrder,
  ]) {
    for (const index of candidates) {
      if (cheapWithinLimits()) {
        break;
      }
      offloadOne(index);
    }
  }

  if (offloaded.length > 0 && maxRequestBytes !== Number.POSITIVE_INFINITY) {
    let exactBodyBytes = serializeBody();
    if (exactBodyBytes > maxRequestBytes) {
      const remainingCandidates = [
        ...nonPreferredIndexes,
        ...preferredIndexesInOrder,
      ].filter((index) => !offloadedIndexes.has(index));
      let projectedBodyBytes = exactBodyBytes;

      for (const index of remainingCandidates) {
        if (
          imageBytes <= maxImagePayloadBytes &&
          imageCount <= maxImagesPerRequest &&
          projectedBodyBytes <= maxRequestBytes - SIZE_MARGIN_BYTES
        ) {
          break;
        }
        if (!offloadOne(index)) {
          continue;
        }
        const placeholderBytes = utf8Bytes(images[index].node.text);
        projectedBodyBytes = Math.max(
          0,
          projectedBodyBytes -
            Math.max(0, images[index].bytes - placeholderBytes),
        );
        if (projectedBodyBytes <= maxRequestBytes - SIZE_MARGIN_BYTES) {
          exactBodyBytes = serializeBody();
          if (exactBodyBytes <= maxRequestBytes) {
            break;
          }
          projectedBodyBytes = exactBodyBytes;
        }
      }
    }
  }

  const finalBodyBytes =
    offloaded.length > 0
      ? serializeBody()
      : originalEstimatedBodyBytes;
  const withinLimits =
    imageBytes <= maxImagePayloadBytes &&
    imageCount <= maxImagesPerRequest &&
    finalBodyBytes <= maxRequestBytes;
  const targetImageBytes = Math.min(
    maxImagePayloadBytes,
    Math.max(
      0,
      maxRequestBytes - estimatedBodyBytes + originalImageBytes,
    ),
  );

  return {
    images,
    originalImageBytes,
    originalImageCount,
    remainingImageBytes: imageBytes,
    remainingImageCount: imageCount,
    targetImageBytes,
    originalEstimatedBodyBytes,
    finalBodyBytes,
    withinLimits,
    serializedBody,
    preferredImageCount: preferredIndexes.size,
    offloaded,
    modified: offloaded.length > 0,
  };
}
