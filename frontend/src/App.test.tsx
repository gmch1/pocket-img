import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import App from "./App";
import { APIError, createSession, createUser, getClientSetup, listImages, listUsers, uploadImage } from "./api";
import { copyText } from "./clipboard";
import { prepareImageForUpload } from "./image-compression";
import type { ClientSetup, GalleryResponse, ImageItem } from "./types";

vi.mock("./api", async () => {
  const actual = await vi.importActual<typeof import("./api")>("./api");
  return {
    ...actual,
    createSession: vi.fn(),
    createUser: vi.fn(),
    deleteImages: vi.fn(),
    deleteSession: vi.fn(),
    getClientSetup: vi.fn(),
    listImages: vi.fn(),
    listUsers: vi.fn(),
    uploadImage: vi.fn(),
  };
});

vi.mock("./clipboard", () => ({ copyText: vi.fn() }));
vi.mock("./image-compression", () => ({ prepareImageForUpload: vi.fn() }));

const image: ImageItem = {
  id: "0123456789abcdef0123456789abcdef",
  media_type: "image/webp",
  width: 1280,
  height: 720,
  byte_size: 1000,
  thumbnail_size: 200,
  animated: false,
  created_at: "2026-08-12T00:00:00Z",
  url: "/i/0123456789abcdef0123456789abcdef.webp",
  thumbnail_url: "/t/0123456789abcdef0123456789abcdef.webp",
};

const video: ImageItem = {
  ...image,
  id: "abcdefabcdefabcdefabcdefabcdefab",
  media_type: "video/mp4",
  byte_size: 5000,
  thumbnail_size: -2,
  url: "/i/abcdefabcdefabcdefabcdefabcdefab.mp4",
  thumbnail_url: "/i/abcdefabcdefabcdefabcdefabcdefab.mp4",
};

const fnosSetup: ClientSetup = {
  mode: "fnos",
  app_version: "0.5.0",
  management_url: "/app/pocket-img/",
  service_url: "http://192.168.1.20:8080",
  token_configured: false,
  user: {
    space_id: "fnos-user-1000",
    display_name: "小明",
    is_admin: true,
  },
  download: {
    url: "downloads/PocketIMGShot-0.5.0-macos-arm64.zip",
    filename: "PocketIMGShot-0.5.0-macos-arm64.zip",
    version: "0.5.0",
    sha256: "a".repeat(64),
    architecture: "arm64",
    minimum_macos: "14",
    size_bytes: 12 * 1024 * 1024,
  },
};

function gallery(images: ImageItem[], isAdmin = false): GalleryResponse {
  return {
    images,
    account: {
      space_id: "alice",
      is_admin: isAdmin,
      quota_bytes: 10 * 1024 * 1024 * 1024,
      used_bytes: images.reduce((total, item) => total + item.byte_size + Math.max(0, item.thumbnail_size), 0),
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
    vi.mocked(getClientSetup).mockReset();
    vi.mocked(getClientSetup).mockRejectedValue(new APIError(404, "not fnos"));
    vi.mocked(listUsers).mockReset();
    vi.mocked(copyText).mockReset();
    vi.mocked(copyText).mockResolvedValue();
    vi.mocked(prepareImageForUpload).mockReset();
    vi.mocked(prepareImageForUpload).mockImplementation(async (file) => file);
    vi.mocked(uploadImage).mockReset();
    window.localStorage.clear();
  });

  afterEach(() => vi.useRealTimers());

  test("exchanges an in-memory token after an unauthorized gallery request", async () => {
    vi.mocked(listImages)
      .mockRejectedValueOnce(new APIError(401, "session required"))
      .mockResolvedValueOnce(gallery([]));

    render(<App />);
    const input = await screen.findByLabelText("Token");
    fireEvent.change(input, { target: { value: "test-token" } });
    fireEvent.click(screen.getByRole("button", { name: "进入" }));

    await waitFor(() => expect(createSession).toHaveBeenCalledWith("test-token"));
    expect(await screen.findByText("粘贴第一张图片或视频")).toBeTruthy();
    expect(screen.queryByLabelText("Token")).toBeNull();
  });

  test("discovers FNOS after login and opens the per-user client guide once", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([]));
    vi.mocked(getClientSetup).mockResolvedValue(fnosSetup);

    const firstView = render(<App />);

    const dialog = await screen.findByRole("dialog", { name: "客户端设置" });
    expect(dialog.textContent).toContain("管理地址");
    expect(dialog.textContent).toContain(new URL(fnosSetup.management_url, window.location.origin).href);
    expect(dialog.textContent).toContain("macOS 客户端服务地址");
    expect(dialog.textContent).toContain(fnosSetup.service_url);
    expect(dialog.textContent).toContain("不要填写飞牛用户名或密码");
    expect(dialog.textContent).toContain("手机无需安装客户端");
    expect(screen.queryByRole("button", { name: "设置 Token" })).toBeNull();
    expect(screen.queryByRole("button", { name: "退出会话" })).toBeNull();
    const download = screen.getByRole("link", { name: "下载 macOS 客户端" });
    expect(download.getAttribute("href")).toContain("/downloads/PocketIMGShot-0.5.0-macos-arm64.zip");
    expect(download.getAttribute("download")).toBe(fnosSetup.download?.filename);
    expect(window.localStorage.getItem("pocketimg:fnos-client-setup-seen:fnos-user-1000")).toBe("1");

    fireEvent.click(screen.getByRole("button", { name: "关闭客户端设置" }));
    expect(screen.queryByRole("dialog", { name: "客户端设置" })).toBeNull();
    expect(screen.getByRole("button", { name: "客户端设置" })).toBeTruthy();

    firstView.unmount();
    render(<App />);
    expect(await screen.findByRole("button", { name: "客户端设置" })).toBeTruthy();
    expect(screen.queryByRole("dialog", { name: "客户端设置" })).toBeNull();
  });

  test("treats a forbidden client setup probe as a normal non-FNOS deployment", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([]));
    vi.mocked(getClientSetup).mockRejectedValue(new APIError(403, "not available"));

    render(<App />);

    await screen.findByText("粘贴第一张图片或视频");
    await waitFor(() => expect(getClientSetup).toHaveBeenCalled());
    expect(screen.queryByRole("button", { name: "客户端设置" })).toBeNull();
    expect(screen.queryByRole("dialog", { name: "客户端设置" })).toBeNull();
    expect(screen.getByRole("button", { name: "设置 Token" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "退出会话" })).toBeTruthy();
  });

  test("uploads a pasted image and copies its public URL", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([]));
    vi.mocked(uploadImage).mockImplementation(async (_file, onProgress) => {
      onProgress(100);
      return image;
    });

    render(<App />);
    await screen.findByText("粘贴第一张图片或视频");
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
    expect(await screen.findByRole("button", { name: "复制媒体链接" })).toBeTruthy();
  });

  test("uploads a pasted MP4 without running image preparation", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([]));
    vi.mocked(uploadImage).mockImplementation(async (_file, onProgress) => {
      onProgress(100);
      return video;
    });

    const { container } = render(<App />);
    await screen.findByText("粘贴第一张图片或视频");
    const file = new File(["mp4"], "clip.mp4", { type: "video/mp4" });
    fireEvent.paste(window, {
      clipboardData: {
        items: [{ kind: "file", type: "video/mp4", getAsFile: () => file }],
      },
    });

    await waitFor(() => expect(uploadImage).toHaveBeenCalledOnce());
    expect(vi.mocked(uploadImage).mock.calls[0][0]).toBe(file);
    expect(prepareImageForUpload).not.toHaveBeenCalled();
    await waitFor(() => expect(copyText).toHaveBeenCalledOnce());
    expect(container.querySelector(".image-card video")?.getAttribute("src")).toBe(video.url);
    expect(screen.getByText("视频")).toBeTruthy();
  });

  test("keeps the 25 MiB limit for pasted MP4 files", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([]));

    render(<App />);
    await screen.findByText("粘贴第一张图片或视频");
    const file = new File(["mp4"], "too-large.mp4", { type: "video/mp4" });
    Object.defineProperty(file, "size", { value: 25 * 1024 * 1024 + 1 });
    fireEvent.paste(window, {
      clipboardData: {
        items: [{ kind: "file", type: "video/mp4", getAsFile: () => file }],
      },
    });

    expect(await screen.findByText("文件超过 25 MiB")).toBeTruthy();
    expect(uploadImage).not.toHaveBeenCalled();
    expect(prepareImageForUpload).not.toHaveBeenCalled();
  });

  test("renders muted video cards and an opt-in video preview", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([video, image]));

    const { container } = render(<App />);
    await screen.findAllByRole("button", { name: "复制媒体链接" });
    const cardVideo = container.querySelector<HTMLVideoElement>(".image-card video");
    expect(cardVideo).toBeTruthy();
    expect(cardVideo?.getAttribute("src")).toBe(video.url);
    expect(cardVideo?.getAttribute("poster")).toBeNull();
    expect(cardVideo?.muted).toBe(true);
    expect(cardVideo?.preload).toBe("metadata");
    expect(cardVideo?.playsInline).toBe(true);
    expect(cardVideo?.controls).toBe(false);
    expect(container.querySelector(".image-card img")?.getAttribute("src")).toBe(image.thumbnail_url);
    expect(screen.getByText("视频")).toBeTruthy();

    fireEvent.click(cardVideo!.closest(".image-card")!);
    const dialog = screen.getByRole("dialog", { name: "媒体预览" });
    const previewVideo = dialog.querySelector("video");
    expect(previewVideo?.getAttribute("src")).toBe(video.url);
    expect(previewVideo?.controls).toBe(true);
    expect(previewVideo?.playsInline).toBe(true);
    expect(previewVideo?.autoplay).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "下一个媒体" }));
    expect(dialog.querySelector("video")).toBeNull();
    expect(dialog.querySelector("img")?.getAttribute("src")).toBe(image.url);
  });

  test("uses display_url for the FNOS full preview but copies the public url", async () => {
    const proxied = { ...image, display_url: "media/display/0123456789abcdef.webp" };
    vi.mocked(listImages).mockResolvedValue(gallery([proxied]));

    const { container } = render(<App />);
    await screen.findByRole("button", { name: "复制媒体链接" });
    const cardImage = container.querySelector<HTMLImageElement>(".image-card img");
    expect(cardImage?.getAttribute("src")).toBe(proxied.thumbnail_url);

    fireEvent.click(cardImage!.closest(".image-card")!);
    expect(screen.getByRole("dialog", { name: "媒体预览" }).querySelector("img")?.getAttribute("src")).toBe(proxied.display_url);
    fireEvent.click(screen.getAllByRole("button", { name: "复制媒体链接" })[0]);
    await waitFor(() => expect(copyText).toHaveBeenCalled());
    expect(vi.mocked(copyText).mock.calls.at(-1)?.[0]).toContain(proxied.url);
    expect(vi.mocked(copyText).mock.calls.at(-1)?.[0]).not.toContain(proxied.display_url);
  });

  test("uses display_url for FNOS video playback while keeping the prefixed poster", async () => {
    const proxiedVideo = {
      ...video,
      display_url: "media/display/clip.mp4",
      thumbnail_url: "media/display/clip-poster.webp",
    };
    vi.mocked(listImages).mockResolvedValue(gallery([proxiedVideo]));

    const { container } = render(<App />);
    await screen.findByRole("button", { name: "复制媒体链接" });
    const cardVideo = container.querySelector<HTMLVideoElement>(".image-card video");
    expect(cardVideo?.getAttribute("src")).toBe(proxiedVideo.display_url);
    expect(cardVideo?.getAttribute("poster")).toBe(proxiedVideo.thumbnail_url);

    fireEvent.click(cardVideo!.closest(".image-card")!);
    const previewVideo = screen.getByRole("dialog", { name: "媒体预览" }).querySelector("video");
    expect(previewVideo?.getAttribute("src")).toBe(proxiedVideo.display_url);
    expect(previewVideo?.getAttribute("poster")).toBe(proxiedVideo.thumbnail_url);
  });

  test("keeps animated images on the existing image rendering path", async () => {
    const animatedImage: ImageItem = {
      ...image,
      media_type: "image/gif",
      animated: true,
      url: "/i/0123456789abcdef0123456789abcdef.gif",
    };
    vi.mocked(listImages).mockResolvedValue(gallery([animatedImage]));

    const { container } = render(<App />);
    await screen.findByRole("button", { name: "复制媒体链接" });
    expect(container.querySelector(".image-card video")).toBeNull();
    expect(container.querySelector(".image-card img")?.getAttribute("src")).toBe(animatedImage.thumbnail_url);
    expect(screen.getByText("GIF")).toBeTruthy();

    fireEvent.click(container.querySelector(".image-card")!);
    const dialog = screen.getByRole("dialog", { name: "媒体预览" });
    expect(dialog.querySelector("video")).toBeNull();
    expect(dialog.querySelector("img")?.getAttribute("src")).toBe(animatedImage.url);
  });

  test("refreshes the gallery when a hidden tab becomes visible", async () => {
    let visibility: DocumentVisibilityState = "visible";
    vi.spyOn(document, "visibilityState", "get").mockImplementation(() => visibility);
    const newest: ImageItem = {
      ...image,
      id: "fedcba9876543210fedcba9876543210",
      thumbnail_url: "/t/fedcba9876543210fedcba9876543210.webp",
      url: "/i/fedcba9876543210fedcba9876543210.webp",
    };
    vi.mocked(listImages)
      .mockResolvedValueOnce(gallery([image]))
      .mockResolvedValueOnce(gallery([newest]));

    const { container } = render(<App />);
    await screen.findByRole("button", { name: "复制媒体链接" });
    expect(listImages).toHaveBeenCalledTimes(1);

    visibility = "hidden";
    fireEvent(document, new Event("visibilitychange"));
    expect(listImages).toHaveBeenCalledTimes(1);

    visibility = "visible";
    fireEvent(document, new Event("visibilitychange"));
    await waitFor(() => expect(listImages).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(container.querySelector(".image-card img")?.getAttribute("src")).toBe(newest.thumbnail_url));

    fireEvent(document, new Event("visibilitychange"));
    expect(listImages).toHaveBeenCalledTimes(2);
  });

  test("refreshes the gallery when the server announces a change", async () => {
    let galleryListener: EventListener | undefined;
    const close = vi.fn();
    class MockEventSource {
      constructor(readonly url: string, readonly options?: EventSourceInit) {}

      addEventListener(type: string, listener: EventListener) {
        if (type === "gallery") galleryListener = listener;
      }

      removeEventListener(type: string, listener: EventListener) {
        if (type === "gallery" && galleryListener === listener) galleryListener = undefined;
      }

      close() {
        close();
      }
    }
    vi.stubGlobal("EventSource", MockEventSource);
    const newest: ImageItem = {
      ...image,
      id: "abcdef0123456789abcdef0123456789",
      thumbnail_url: "/t/abcdef0123456789abcdef0123456789.webp",
      url: "/i/abcdef0123456789abcdef0123456789.webp",
    };
    vi.mocked(listImages)
      .mockResolvedValueOnce(gallery([image]))
      .mockResolvedValueOnce(gallery([newest]));

    const { container, unmount } = render(<App />);
    await screen.findByRole("button", { name: "复制媒体链接" });
    await waitFor(() => expect(galleryListener).toBeTypeOf("function"));
    galleryListener?.(new MessageEvent("gallery", { data: "{}" }));

    await waitFor(() => expect(listImages).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(container.querySelector(".image-card img")?.getAttribute("src")).toBe(newest.thumbnail_url));
    unmount();
    expect(close).toHaveBeenCalledOnce();
  });

  test("shows a friendly gallery error and retries the request", async () => {
    vi.mocked(listImages)
      .mockResolvedValueOnce(gallery([]))
      .mockRejectedValueOnce(new APIError(502, "请求失败 (502)"))
      .mockResolvedValueOnce(gallery([]));

    render(<App />);
    await screen.findByText("粘贴第一张图片或视频");
    fireEvent.click(screen.getByRole("button", { name: "全部" }));
    expect(await screen.findByRole("heading", { name: "暂时无法加载" })).toBeTruthy();
    expect(screen.getByText("图库连接遇到问题，请稍后重试。")).toBeTruthy();
    expect(screen.getByText("请求失败 (502)")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "重新加载" }));
    expect(await screen.findByText("粘贴第一张图片或视频")).toBeTruthy();
    expect(listImages).toHaveBeenCalledTimes(3);
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
    const { container } = render(<App />);

    expect(await screen.findByRole("button", { name: "复制媒体链接" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "永久删除媒体" })).toBeTruthy();
    expect(screen.queryByText("复制媒体链接")).toBeNull();
    expect(screen.queryByText("永久删除媒体")).toBeNull();
    expect(container.querySelector(".image-grid")).toBeTruthy();
    expect(container.querySelector(".image-card__media > .image-card__actions")).toBeTruthy();
    expect(screen.getByRole("button", { name: "7 天" }).classList.contains("is-active")).toBe(true);
    expect(screen.queryByRole("button", { name: "今天" })).toBeNull();
    expect(screen.queryByRole("button", { name: "30 天" })).toBeNull();
    expect(listImages).toHaveBeenCalledWith("7d", expect.any(AbortSignal));
  });

  test("groups fixed-ratio grids under reverse-chronological date headings", async () => {
    const older = {
      ...image,
      id: "fedcba9876543210fedcba9876543210",
      created_at: "2026-08-11T00:00:00Z",
      url: "/i/fedcba9876543210fedcba9876543210.webp",
      thumbnail_url: "/t/fedcba9876543210fedcba9876543210.webp",
    };
    vi.mocked(listImages).mockResolvedValue(gallery([image, older]));

    const { container } = render(<App />);
    await screen.findAllByRole("button", { name: "复制媒体链接" });
    const groups = container.querySelectorAll(".timeline-group");
    expect(groups).toHaveLength(2);
    expect(groups[0].querySelectorAll(".image-card")).toHaveLength(1);
    expect(groups[1].querySelectorAll(".image-card")).toHaveLength(1);
    expect(groups[0].querySelector(".timeline-group__label")?.textContent).toContain("8月12日 周三");
    expect(groups[1].querySelector(".timeline-group__label")?.textContent).toContain("8月11日 周二");
    expect(groups[0].querySelector(".timeline-group__label")?.textContent).toContain("1 项");
    expect(groups[1].querySelector(".timeline-group__label")?.textContent).toContain("1 项");
  });

  test("navigates between images in the preview", async () => {
    const nextImage = {
      ...image,
      id: "fedcba9876543210fedcba9876543210",
      url: "/i/fedcba9876543210fedcba9876543210.webp",
      thumbnail_url: "/t/fedcba9876543210fedcba9876543210.webp",
    };
    vi.mocked(listImages).mockResolvedValue(gallery([image, nextImage]));

    const { container } = render(<App />);
    await screen.findAllByRole("button", { name: "复制媒体链接" });
    const cards = container.querySelectorAll<HTMLElement>(".image-card");
    fireEvent.click(cards[0]);

    const previewImage = screen.getByRole("dialog", { name: "媒体预览" }).querySelector("img");
    expect(previewImage?.getAttribute("src")).toBe(image.url);
    expect((screen.getByRole("button", { name: "上一个媒体" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "下一个媒体" }));
    expect(previewImage?.getAttribute("src")).toBe(nextImage.url);
    expect((screen.getByRole("button", { name: "下一个媒体" }) as HTMLButtonElement).disabled).toBe(true);

    fireEvent.keyDown(window, { key: "ArrowLeft" });
    expect(previewImage?.getAttribute("src")).toBe(image.url);
  });

  test("keeps the current gallery in place while changing the date range", async () => {
    let finishRefresh: ((result: GalleryResponse) => void) | undefined;
    vi.mocked(listImages)
      .mockResolvedValueOnce(gallery([image]))
      .mockImplementationOnce(() => new Promise((resolve) => { finishRefresh = resolve; }));

    const { container } = render(<App />);
    expect(await screen.findByRole("button", { name: "复制媒体链接" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "全部" }));

    await waitFor(() => expect(listImages).toHaveBeenCalledTimes(2));
    expect(container.querySelector(".gallery-loading")).toBeNull();
    expect(screen.getByLabelText("正在刷新图库")).toBeTruthy();
    expect(screen.getByRole("button", { name: "复制媒体链接" })).toBeTruthy();

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
    await screen.findByText("粘贴第一张图片或视频");
    const file = new File(["webp"], "clipboard.webp", { type: "image/webp" });
    fireEvent.paste(window, {
      clipboardData: {
        items: [{ kind: "file", type: "image/webp", getAsFile: () => file }],
      },
    });

    const progress = await screen.findByRole("progressbar", { name: "正在处理媒体" });
    expect(progress.getAttribute("aria-valuenow")).toBeNull();
    expect(screen.queryByText("上传结果")).toBeNull();

    await act(async () => finishUpload?.(image));
    await waitFor(() => expect(screen.queryByRole("progressbar")).toBeNull());
    expect(screen.queryByText("✓")).toBeNull();
  });

  test("shows multi-select controls in a bottom floating toolbar", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([image]));
    const { container } = render(<App />);
    await screen.findByRole("button", { name: "复制媒体链接" });

    vi.useFakeTimers();
    const card = container.querySelector<HTMLElement>(".image-card");
    expect(card).toBeTruthy();
    fireEvent.pointerDown(card!, { button: 0, clientX: 20, clientY: 20 });
    act(() => vi.advanceTimersByTime(500));
    fireEvent.pointerUp(card!);

    const toolbar = screen.getByRole("toolbar", { name: "批量操作" });
    expect(toolbar.classList.contains("selection-toolbar")).toBe(true);
    expect(toolbar.closest("header")).toBeNull();
    expect(screen.getByRole("navigation", { name: "时间范围" })).toBeTruthy();
    expect(screen.getByText("已选 1 项")).toBeTruthy();
    expect(screen.getByRole("button", { name: "完成" })).toBeTruthy();
    expect(container.querySelector(".selection-mark")).toBeTruthy();
  });

  test("prevents the browser context menu across the page", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([]));
    render(<App />);
    await screen.findByText("粘贴第一张图片或视频");

    const contextMenu = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
    document.body.dispatchEvent(contextMenu);

    expect(contextMenu.defaultPrevented).toBe(true);
  });

  test("selects multiple images by dragging across blank gallery space", async () => {
    const second = {
      ...image,
      id: "11111111111111111111111111111111",
      url: "/i/11111111111111111111111111111111.webp",
      thumbnail_url: "/t/11111111111111111111111111111111.webp",
    };
    const third = {
      ...image,
      id: "22222222222222222222222222222222",
      url: "/i/22222222222222222222222222222222.webp",
      thumbnail_url: "/t/22222222222222222222222222222222.webp",
    };
    vi.mocked(listImages).mockResolvedValue(gallery([image, second, third]));

    const { container } = render(<App />);
    await screen.findAllByRole("button", { name: "复制媒体链接" });
    const timeline = container.querySelector<HTMLElement>(".image-timeline");
    const cards = Array.from(container.querySelectorAll<HTMLElement>(".image-card"));
    expect(timeline).toBeTruthy();
    expect(cards).toHaveLength(3);
    cards[0].getBoundingClientRect = () => ({ left: 20, top: 40, right: 120, bottom: 120, width: 100, height: 80, x: 20, y: 40, toJSON: () => ({}) });
    cards[1].getBoundingClientRect = () => ({ left: 140, top: 40, right: 240, bottom: 120, width: 100, height: 80, x: 140, y: 40, toJSON: () => ({}) });
    cards[2].getBoundingClientRect = () => ({ left: 260, top: 40, right: 360, bottom: 120, width: 100, height: 80, x: 260, y: 40, toJSON: () => ({}) });

    fireEvent.pointerDown(timeline!, { button: 0, pointerId: 7, pointerType: "mouse", clientX: 5, clientY: 20 });
    fireEvent.pointerMove(timeline!, { pointerId: 7, pointerType: "mouse", clientX: 250, clientY: 130 });

    expect(container.querySelector(".marquee-selection")).toBeTruthy();
    expect(screen.getByLabelText("已选择 2 项媒体")).toBeTruthy();
    expect(container.querySelectorAll(".image-card--selected")).toHaveLength(2);

    fireEvent.pointerUp(timeline!, { pointerId: 7, pointerType: "mouse", clientX: 250, clientY: 130 });
    expect(container.querySelector(".marquee-selection")).toBeNull();
    expect(screen.getByRole("toolbar", { name: "批量操作" })).toBeTruthy();

    fireEvent.pointerDown(timeline!, { button: 0, pointerId: 8, pointerType: "mouse", ctrlKey: true, clientX: 370, clientY: 20 });
    fireEvent.pointerMove(timeline!, { pointerId: 8, pointerType: "mouse", clientX: 250, clientY: 130 });
    fireEvent.pointerUp(timeline!, { pointerId: 8, pointerType: "mouse", clientX: 250, clientY: 130 });
    expect(screen.getByLabelText("已选择 3 项媒体")).toBeTruthy();
    expect(container.querySelectorAll(".image-card--selected")).toHaveLength(3);
  });

  test("reports upload failures with a toast and clears global loading", async () => {
    let failUpload: ((reason: APIError) => void) | undefined;
    vi.mocked(listImages).mockResolvedValue(gallery([]));
    vi.mocked(uploadImage).mockImplementation(() => new Promise((_resolve, reject) => { failUpload = reject; }));

    render(<App />);
    await screen.findByText("粘贴第一张图片或视频");
    const file = new File(["webp"], "clipboard.webp", { type: "image/webp" });
    fireEvent.paste(window, {
      clipboardData: {
        items: [{ kind: "file", type: "image/webp", getAsFile: () => file }],
      },
    });

    expect(await screen.findByRole("progressbar", { name: "正在上传媒体" })).toBeTruthy();
    await act(async () => failUpload?.(new APIError(429, "rate limit exceeded")));
    expect(await screen.findByText("rate limit exceeded")).toBeTruthy();
    await waitFor(() => expect(screen.queryByRole("progressbar")).toBeNull());
    expect(screen.queryByText("上传结果")).toBeNull();
  });
});
