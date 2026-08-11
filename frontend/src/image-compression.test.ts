import { afterEach, describe, expect, test, vi } from "vitest";
import { prepareImageForUpload, shouldPrecompressImage } from "./image-compression";

afterEach(() => vi.unstubAllGlobals());

describe("image precompression", () => {
  test("only selects large static PNG and JPEG files", () => {
    expect(shouldPrecompressImage(testFile(300 * 1024, "large.png", "image/png"))).toBe(true);
    expect(shouldPrecompressImage(testFile(300 * 1024, "large.jpg", "image/jpeg"))).toBe(true);
    expect(shouldPrecompressImage(testFile(10 * 1024, "small.png", "image/png"))).toBe(false);
    expect(shouldPrecompressImage(testFile(300 * 1024, "animation.gif", "image/gif"))).toBe(false);
    expect(shouldPrecompressImage(testFile(300 * 1024, "animation.webp", "image/webp"))).toBe(false);
  });

  test("returns a smaller WebP file produced by the worker", async () => {
    let terminated = false;
    class FakeWorker {
      onmessage: ((event: MessageEvent) => void) | null = null;
      onerror: (() => void) | null = null;
      postMessage() {
        const blob = new Blob([new Uint8Array(100 * 1024)], { type: "image/webp" });
        queueMicrotask(() => this.onmessage?.({ data: { blob } } as MessageEvent));
      }
      terminate() { terminated = true; }
    }
    vi.stubGlobal("Worker", FakeWorker);
    const source = testFile(300 * 1024, "screenshot.png", "image/png");

    const result = await prepareImageForUpload(source);

    expect(result).not.toBe(source);
    expect(result.name).toBe("screenshot.webp");
    expect(result.type).toBe("image/webp");
    expect(result.size).toBe(100 * 1024);
    expect(terminated).toBe(true);
  });

  test("falls back when the browser returns another format", async () => {
    class FakeWorker {
      onmessage: ((event: MessageEvent) => void) | null = null;
      onerror: (() => void) | null = null;
      postMessage() {
        const blob = new Blob([new Uint8Array(100 * 1024)], { type: "image/png" });
        queueMicrotask(() => this.onmessage?.({ data: { blob } } as MessageEvent));
      }
      terminate() {}
    }
    vi.stubGlobal("Worker", FakeWorker);
    const source = testFile(300 * 1024, "screenshot.png", "image/png");

    expect(await prepareImageForUpload(source)).toBe(source);
  });
});

function testFile(size: number, name: string, type: string): File {
  const file = new File([new Uint8Array(size)], name, { type, lastModified: 123 });
  Object.defineProperty(file, "arrayBuffer", {
    value: async () => new ArrayBuffer(size),
  });
  return file;
}
