import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, test, vi } from "vitest";
import App from "./App";
import { APIError, createSession, createUser, listImages, listUsers, uploadImage } from "./api";
import { copyText } from "./clipboard";
import { prepareImageForUpload } from "./image-compression";
import type { GalleryResponse, ImageItem } from "./types";

vi.mock("./api", async () => {
  const actual = await vi.importActual<typeof import("./api")>("./api");
  return {
    ...actual,
    createSession: vi.fn(),
    createUser: vi.fn(),
    deleteImages: vi.fn(),
    deleteSession: vi.fn(),
    listImages: vi.fn(),
    listUsers: vi.fn(),
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

function gallery(images: ImageItem[], isAdmin = false): GalleryResponse {
  return {
    images,
    account: {
      space_id: "alice",
      is_admin: isAdmin,
      quota_bytes: 10 * 1024 * 1024 * 1024,
      used_bytes: images.reduce((total, item) => total + item.byte_size + item.thumbnail_size, 0),
      image_count: images.length,
      retention_days: 90,
      enabled: true,
    },
  };
}

describe("App", () => {
  beforeEach(() => {
    vi.mocked(listImages).mockReset();
    vi.mocked(createSession).mockResolvedValue();
    vi.mocked(createUser).mockReset();
    vi.mocked(listUsers).mockReset();
    vi.mocked(copyText).mockReset();
    vi.mocked(copyText).mockResolvedValue();
    vi.mocked(prepareImageForUpload).mockImplementation(async (file) => file);
    vi.mocked(uploadImage).mockReset();
  });

  test("exchanges an in-memory token after an unauthorized gallery request", async () => {
    vi.mocked(listImages)
      .mockRejectedValueOnce(new APIError(401, "session required"))
      .mockResolvedValueOnce(gallery([]));

    render(<App />);
    const input = await screen.findByLabelText("Token");
    fireEvent.change(input, { target: { value: "test-token" } });
    fireEvent.click(screen.getByRole("button", { name: "进入" }));

    await waitFor(() => expect(createSession).toHaveBeenCalledWith("test-token"));
    expect(await screen.findByText("粘贴第一张图片")).toBeTruthy();
    expect(screen.queryByLabelText("Token")).toBeNull();
  });

  test("uploads a pasted image and copies its public URL", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([]));
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

  test("lets an administrator create a user token", async () => {
    const account = gallery([], true).account;
    vi.mocked(listImages).mockResolvedValue(gallery([], true));
    vi.mocked(listUsers).mockResolvedValue([account]);
    vi.mocked(createUser).mockResolvedValue({
      user: { ...account, space_id: "guest", is_admin: false },
      token: "a".repeat(64),
    });

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "用户管理" }));
    fireEvent.change(await screen.findByLabelText("新用户空间 ID"), { target: { value: "guest" } });
    fireEvent.click(screen.getByRole("button", { name: "创建 Token" }));

    await waitFor(() => expect(createUser).toHaveBeenCalledWith("guest"));
    expect(await screen.findByText("a".repeat(64))).toBeTruthy();
    expect(screen.getByText("Token 只显示这一次")).toBeTruthy();
  });

  test("renders only icon actions on gallery cards", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([image]));
    render(<App />);

    expect(await screen.findByRole("button", { name: "复制图片链接" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "永久删除图片" })).toBeTruthy();
    expect(screen.queryByText("复制图片链接")).toBeNull();
    expect(screen.queryByText("永久删除图片")).toBeNull();
  });

  test("keeps the current gallery in place while changing the date range", async () => {
    let finishRefresh: ((result: GalleryResponse) => void) | undefined;
    vi.mocked(listImages)
      .mockResolvedValueOnce(gallery([image]))
      .mockImplementationOnce(() => new Promise((resolve) => { finishRefresh = resolve; }));

    const { container } = render(<App />);
    expect(await screen.findByRole("button", { name: "复制图片链接" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "7 天" }));

    await waitFor(() => expect(listImages).toHaveBeenCalledTimes(2));
    expect(container.querySelector(".gallery-loading")).toBeNull();
    expect(screen.getByLabelText("正在刷新图库")).toBeTruthy();
    expect(screen.getByRole("button", { name: "复制图片链接" })).toBeTruthy();

    await act(async () => finishRefresh?.(gallery([image])));
    await waitFor(() => expect(screen.queryByLabelText("正在刷新图库")).toBeNull());
  });

  test("shows server processing instead of a premature 100 percent", async () => {
    let finishUpload: ((image: ImageItem) => void) | undefined;
    vi.mocked(listImages).mockResolvedValue(gallery([]));
    vi.mocked(uploadImage).mockImplementation((_file, onProgress, onProcessing) => {
      onProgress(99);
      onProcessing?.();
      return new Promise((resolve) => { finishUpload = resolve; });
    });

    render(<App />);
    await screen.findByText("粘贴第一张图片");
    const file = new File(["webp"], "clipboard.webp", { type: "image/webp" });
    fireEvent.paste(window, {
      clipboardData: {
        items: [{ kind: "file", type: "image/webp", getAsFile: () => file }],
      },
    });

    expect(await screen.findByText("处理中")).toBeTruthy();
    expect(screen.queryByText("100%")).toBeNull();

    await act(async () => finishUpload?.(image));
    await waitFor(() => expect(screen.queryByText("处理中")).toBeNull());
    expect(screen.getByText("✓")).toBeTruthy();
  });
});
