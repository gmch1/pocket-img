const ELIGIBLE_TYPES = new Set(["image/jpeg", "image/png"]);
const MIN_SOURCE_BYTES = 256 * 1024;
const MIN_SAVINGS_RATIO = 0.9;
const WEBP_QUALITY = 0.82;
const COMPRESSION_TIMEOUT_MS = 45_000;

interface CompressionResponse {
  blob?: Blob;
  error?: string;
}

export function shouldPrecompressImage(file: File): boolean {
  return ELIGIBLE_TYPES.has(file.type.toLowerCase()) && file.size >= MIN_SOURCE_BYTES;
}

export async function prepareImageForUpload(file: File): Promise<File> {
  if (!shouldPrecompressImage(file) || typeof Worker === "undefined") return file;
  try {
    const compressed = await compressInWorker(file);
    if (
      compressed.type.toLowerCase() !== "image/webp"
      || compressed.size === 0
      || compressed.size >= file.size * MIN_SAVINGS_RATIO
    ) {
      return file;
    }
    return new File([compressed], webPFilename(file.name), {
      type: "image/webp",
      lastModified: file.lastModified,
    });
  } catch {
    return file;
  }
}

async function compressInWorker(file: File): Promise<Blob> {
  const source = await file.arrayBuffer();
  return new Promise<Blob>((resolve, reject) => {
    const worker = new Worker(new URL("./image-compression.worker.ts", import.meta.url), { type: "module" });
    const timeout = window.setTimeout(() => {
      worker.terminate();
      reject(new Error("image compression timed out"));
    }, COMPRESSION_TIMEOUT_MS);

    const finish = () => {
      window.clearTimeout(timeout);
      worker.terminate();
    };
    worker.onmessage = (event: MessageEvent<CompressionResponse>) => {
      finish();
      if (event.data.blob) resolve(event.data.blob);
      else reject(new Error(event.data.error || "image compression failed"));
    };
    worker.onerror = () => {
      finish();
      reject(new Error("image compression worker failed"));
    };
    worker.postMessage({ source, mimeType: file.type, quality: WEBP_QUALITY }, [source]);
  });
}

function webPFilename(original: string): string {
  const name = original.trim() || "clipboard-image";
  const separator = name.lastIndexOf(".");
  return `${separator > 0 ? name.slice(0, separator) : name}.webp`;
}
