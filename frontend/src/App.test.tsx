import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
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
    await screen.findByRole("button", { name: "复制图片链接" });
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

  test("shows a friendly gallery error and retries the request", async () => {
    vi.mocked(listImages)
      .mockResolvedValueOnce(gallery([]))
      .mockRejectedValueOnce(new APIError(502, "请求失败 (502)"))
      .mockResolvedValueOnce(gallery([]));

    render(<App />);
    await screen.findByText("粘贴第一张图片");
    fireEvent.click(screen.getByRole("button", { name: "全部" }));
    expect(await screen.findByRole("heading", { name: "暂时无法加载" })).toBeTruthy();
    expect(screen.getByText("图库连接遇到问题，请稍后重试。")).toBeTruthy();
    expect(screen.getByText("请求失败 (502)")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "重新加载" }));
    expect(await screen.findByText("粘贴第一张图片")).toBeTruthy();
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

    expect(await screen.findByRole("button", { name: "复制图片链接" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "永久删除图片" })).toBeTruthy();
    expect(screen.queryByText("复制图片链接")).toBeNull();
    expect(screen.queryByText("永久删除图片")).toBeNull();
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
    await screen.findAllByRole("button", { name: "复制图片链接" });
    const groups = container.querySelectorAll(".timeline-group");
    expect(groups).toHaveLength(2);
    expect(groups[0].querySelectorAll(".image-card")).toHaveLength(1);
    expect(groups[1].querySelectorAll(".image-card")).toHaveLength(1);
    expect(groups[0].querySelector(".timeline-group__label")?.textContent).toContain("8月12日 周三");
    expect(groups[1].querySelector(".timeline-group__label")?.textContent).toContain("8月11日 周二");
    expect(groups[0].querySelector(".timeline-group__label")?.textContent).toContain("1 张");
    expect(groups[1].querySelector(".timeline-group__label")?.textContent).toContain("1 张");
  });

  test("keeps the current gallery in place while changing the date range", async () => {
    let finishRefresh: ((result: GalleryResponse) => void) | undefined;
    vi.mocked(listImages)
      .mockResolvedValueOnce(gallery([image]))
      .mockImplementationOnce(() => new Promise((resolve) => { finishRefresh = resolve; }));

    const { container } = render(<App />);
    expect(await screen.findByRole("button", { name: "复制图片链接" })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "全部" }));

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

    const progress = await screen.findByRole("progressbar", { name: "正在处理图片" });
    expect(progress.getAttribute("aria-valuenow")).toBeNull();
    expect(screen.queryByText("上传结果")).toBeNull();

    await act(async () => finishUpload?.(image));
    await waitFor(() => expect(screen.queryByRole("progressbar")).toBeNull());
    expect(screen.queryByText("✓")).toBeNull();
  });

  test("moves multi-select controls into the sticky header", async () => {
    vi.mocked(listImages).mockResolvedValue(gallery([image]));
    const { container } = render(<App />);
    await screen.findByRole("button", { name: "复制图片链接" });

    vi.useFakeTimers();
    const card = container.querySelector<HTMLElement>(".image-card");
    expect(card).toBeTruthy();
    fireEvent.pointerDown(card!, { button: 0, clientX: 20, clientY: 20 });
    act(() => vi.advanceTimersByTime(500));
    fireEvent.pointerUp(card!);

    const toolbar = screen.getByRole("toolbar", { name: "批量操作" });
    expect(toolbar.closest("header")).toBeTruthy();
    expect(screen.queryByRole("navigation", { name: "时间范围" })).toBeNull();
    expect(container.querySelector(".selection-mark")).toBeTruthy();
    expect(container.querySelector(".selection-toolbar")).toBeNull();
  });

  test("reports upload failures with a toast and clears global loading", async () => {
    let failUpload: ((reason: APIError) => void) | undefined;
    vi.mocked(listImages).mockResolvedValue(gallery([]));
    vi.mocked(uploadImage).mockImplementation(() => new Promise((_resolve, reject) => { failUpload = reject; }));

    render(<App />);
    await screen.findByText("粘贴第一张图片");
    const file = new File(["webp"], "clipboard.webp", { type: "image/webp" });
    fireEvent.paste(window, {
      clipboardData: {
        items: [{ kind: "file", type: "image/webp", getAsFile: () => file }],
      },
    });

    expect(await screen.findByRole("progressbar", { name: "正在上传图片" })).toBeTruthy();
    await act(async () => failUpload?.(new APIError(429, "rate limit exceeded")));
    expect(await screen.findByText("rate limit exceeded")).toBeTruthy();
    await waitFor(() => expect(screen.queryByRole("progressbar")).toBeNull());
    expect(screen.queryByText("上传结果")).toBeNull();
  });
});
