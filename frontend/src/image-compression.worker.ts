/// <reference lib="webworker" />

interface CompressionRequest {
  source: ArrayBuffer;
  mimeType: string;
  quality: number;
}

interface CompressionResponse {
  blob?: Blob;
  error?: string;
}

const workerScope = self as unknown as DedicatedWorkerGlobalScope;

workerScope.onmessage = async (event: MessageEvent<CompressionRequest>) => {
  let bitmap: ImageBitmap | undefined;
  try {
    const source = new Blob([event.data.source], { type: event.data.mimeType });
    bitmap = await createImageBitmap(source);
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const context = canvas.getContext("2d", { alpha: true });
    if (!context) throw new Error("2D canvas unavailable");
    context.drawImage(bitmap, 0, 0);
    const blob = await canvas.convertToBlob({ type: "image/webp", quality: event.data.quality });
    workerScope.postMessage({ blob } satisfies CompressionResponse);
  } catch (reason) {
    const error = reason instanceof Error ? reason.message : "browser image compression failed";
    workerScope.postMessage({ error } satisfies CompressionResponse);
  } finally {
    bitmap?.close();
  }
};
