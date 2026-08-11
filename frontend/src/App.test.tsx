import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, test, vi } from "vitest";
import App from "./App";
import { APIError, createSession, listImages, uploadImage } from "./api";
import { copyText } from "./clipboard";
import { prepareImageForUpload } from "./image-compression";
import type { ImageItem } from "./types";

vi.mock("./api", async () => {
  const actual = await vi.importActual<typeof import("./api")>("./api");
  return {
    ...actual,
    createSession: vi.fn(),
    deleteImages: vi.fn(),
    deleteSession: vi.fn(),
    listImages: vi.fn(),
    uploadImage: vi.fn(),
  };
});

vi.mock("./clipboard", () => ({ copyText: vi.fn() }));
vi.mock("./image-compression", () => ({ prepareImageForUpload: vi.fn() }));

const image: ImageItem = {
  id: "0123456789abcdef0123456789abcdef",
  width: 1280,
  height: 720,
  byte_size: 1000,
  thumbnail_size: 200,
  animated: false,
  created_at: "2026-08-12T00:00:00Z",
  url: "/i/0123456789abcdef0123456789abcdef.webp",
  thumbnail_url: "/t/0123456789abcdef0123456789abcdef.webp",
};

describe("App", () => {
  beforeEach(() => {
    vi.mocked(createSession).mockResolvedValue();
    vi.mocked(copyText).mockResolvedValue();
    vi.mocked(prepareImageForUpload).mockImplementation(async (file) => file);
    vi.mocked(uploadImage).mockReset();
  });

  test("exchanges an in-memory token after an unauthorized gallery request", async () => {
    vi.mocked(listImages)
      .mockRejectedValueOnce(new APIError(401, "session required"))
      .mockResolvedValueOnce([]);

    render(<App />);
    const input = await screen.findByLabelText("Token");
    fireEvent.change(input, { target: { value: "test-token" } });
    fireEvent.click(screen.getByRole("button", { name: "进入" }));

    await waitFor(() => expect(createSession).toHaveBeenCalledWith("test-token"));
    expect(await screen.findByText("粘贴第一张图片")).toBeTruthy();
    expect(screen.queryByLabelText("Token")).toBeNull();
  });

  test("uploads a pasted image and copies its public URL", async () => {
    vi.mocked(listImages).mockResolvedValue([]);
    vi.mocked(uploadImage).mockImplementation(async (_file, onProgress) => {
      onProgress(100);
      return image;
    });

    render(<App />);
    await screen.findByText("粘贴第一张图片");
    const file = new File(["png"], "clipboard.png", { type: "image/png" });
    fireEvent.paste(window, {
      clipboardData: {
        items: [{ kind: "file", type: "image/png", getAsFile: () => file }],
      },
    });

    await waitFor(() => expect(uploadImage).toHaveBeenCalledOnce());
    expect(prepareImageForUpload).toHaveBeenCalledWith(file);
    await waitFor(() => expect(copyText).toHaveBeenCalledOnce());
    expect(vi.mocked(copyText).mock.calls[0][0]).toContain(image.url);
    expect(await screen.findByRole("button", { name: "复制图片链接" })).toBeTruthy();
  });

  test("renders only icon actions on gallery cards", async () => {
    vi.mocked(listImages).mockResolvedValue([image]);
    render(<App />);

    expect(await screen.findByRole("button", { name: "复制图片链接" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "永久删除图片" })).toBeTruthy();
    expect(screen.queryByText("复制图片链接")).toBeNull();
    expect(screen.queryByText("永久删除图片")).toBeNull();
  });
});
