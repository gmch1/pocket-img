import { useCallback, useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { APIError, absoluteImageURL, createSession, deleteImages, deleteSession, listImages, uploadImage } from "./api";
import { copyText } from "./clipboard";
import { prepareImageForUpload } from "./image-compression";
import { ImageCard } from "./components/ImageCard";
import { ImagePreview } from "./components/ImagePreview";
import { AdminPanel } from "./components/AdminPanel";
import { TokenPanel } from "./components/TokenPanel";
import { GlobalUploadProgress } from "./components/GlobalUploadProgress";
import { AlertIcon, CloseIcon, ImageIcon, KeyIcon, LogoutIcon, TrashIcon, UsersIcon } from "./icons";
import type { AccountInfo, GalleryRange, ImageItem, UploadTask } from "./types";

type AuthState = "checking" | "required" | "authenticated";
type Toast = { id: number; message: string; error: boolean };
type SelectionBox = { left: number; top: number; width: number; height: number };
type MarqueeGesture = {
  pointerId: number;
  originX: number;
  originY: number;
  initialSelection: Set<string>;
  additive: boolean;
  active: boolean;
};

const RANGE_OPTIONS: ReadonlyArray<{ value: GalleryRange; label: string }> = [
  { value: "7d", label: "7 天" },
  { value: "all", label: "全部" },
];

const MAX_PASTE_FILES = 20;
const MAX_FILE_BYTES = 25 * 1024 * 1024;
const MARQUEE_DRAG_THRESHOLD = 5;
const TIMELINE_TIME_ZONE = "Asia/Shanghai";
const TIMELINE_DATE_KEY = new Intl.DateTimeFormat("en-CA", {
  timeZone: TIMELINE_TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
const TIMELINE_MONTH_DAY_LABEL = new Intl.DateTimeFormat("zh-CN", {
  timeZone: TIMELINE_TIME_ZONE,
  month: "numeric",
  day: "numeric",
});
const TIMELINE_WEEKDAY_LABEL = new Intl.DateTimeFormat("zh-CN", {
  timeZone: TIMELINE_TIME_ZONE,
  weekday: "short",
});

interface TimelineGroup {
  key: string;
  label: string;
  images: ImageItem[];
}

function timelineDateLabel(createdAt: Date): string {
  const parts = TIMELINE_MONTH_DAY_LABEL.formatToParts(createdAt);
  const month = parts.find((part) => part.type === "month")?.value ?? "";
  const day = parts.find((part) => part.type === "day")?.value ?? "";
  return `${month}月${day}日 ${TIMELINE_WEEKDAY_LABEL.format(createdAt)}`;
}

function timelineGroups(images: ImageItem[]): TimelineGroup[] {
  const groups = new Map<string, TimelineGroup>();
  for (const image of images) {
    const createdAt = new Date(image.created_at);
    const key = TIMELINE_DATE_KEY.format(createdAt);
    let group = groups.get(key);
    if (!group) {
      group = {
        key,
        label: timelineDateLabel(createdAt),
        images: [],
      };
      groups.set(key, group);
    }
    group.images.push(image);
  }
  return Array.from(groups.values());
}

function selectionBoxBetween(originX: number, originY: number, currentX: number, currentY: number): SelectionBox {
  return {
    left: Math.min(originX, currentX),
    top: Math.min(originY, currentY),
    width: Math.abs(currentX - originX),
    height: Math.abs(currentY - originY),
  };
}

function intersectsSelectionBox(rect: DOMRect, box: SelectionBox): boolean {
  return rect.right > box.left
    && rect.left < box.left + box.width
    && rect.bottom > box.top
    && rect.top < box.top + box.height;
}

export default function App() {
  const [auth, setAuth] = useState<AuthState>("checking");
  const [range, setRange] = useState<GalleryRange>("7d");
  const [images, setImages] = useState<ImageItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [galleryError, setGalleryError] = useState("");
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [adminOpen, setAdminOpen] = useState(false);
  const [account, setAccount] = useState<AccountInfo | null>(null);
  const [preview, setPreview] = useState<ImageItem | null>(null);
  const [selected, setSelected] = useState<Set<string>>(() => new Set());
  const [selectionBox, setSelectionBox] = useState<SelectionBox | null>(null);
  const [uploadTasks, setUploadTasks] = useState<UploadTask[]>([]);
  const [toast, setToast] = useState<Toast | null>(null);
  const authRef = useRef<AuthState>(auth);
  const uploadQueue = useRef<Promise<void>>(Promise.resolve());
  const taskSequence = useRef(0);
  const toastTimer = useRef<number | undefined>(undefined);
  const gallerySelectionSurface = useRef<HTMLElement | null>(null);
  const marqueeGesture = useRef<MarqueeGesture | null>(null);
  const groupedImages = timelineGroups(images);
  authRef.current = auth;

  const notify = useCallback((message: string, error = false) => {
    if (toastTimer.current !== undefined) window.clearTimeout(toastTimer.current);
    setToast({ id: Date.now(), message, error });
    toastTimer.current = window.setTimeout(() => setToast(null), 2800);
  }, []);

  useEffect(() => () => {
    if (toastTimer.current !== undefined) window.clearTimeout(toastTimer.current);
  }, []);

  const expireSession = useCallback(() => {
    setAuth("required");
    setImages([]);
    setSelected(new Set());
    setPreview(null);
    setSettingsOpen(false);
    setAdminOpen(false);
    setAccount(null);
  }, []);

  const refresh = useCallback(async (nextRange: GalleryRange, signal?: AbortSignal): Promise<boolean> => {
    setLoading(true);
    setGalleryError("");
    try {
      const result = await listImages(nextRange, signal);
      setImages(result.images);
      setAccount(result.account);
      setAuth("authenticated");
      setSelected(new Set());
      return true;
    } catch (reason) {
      if (signal?.aborted) return false;
      if (reason instanceof APIError && reason.status === 401) {
        expireSession();
      } else {
        setGalleryError(reason instanceof Error ? reason.message : "图库加载失败");
      }
      return false;
    } finally {
      if (!signal?.aborted) setLoading(false);
    }
  }, [expireSession]);

  useEffect(() => {
    const controller = new AbortController();
    void refresh(range, controller.signal);
    return () => controller.abort();
  }, [range, refresh]);

  useEffect(() => {
    let wasHidden = document.visibilityState === "hidden";
    let controller: AbortController | undefined;
    const handleVisibilityChange = () => {
      if (document.visibilityState === "hidden") {
        wasHidden = true;
        return;
      }
      if (!wasHidden) return;
      wasHidden = false;
      if (authRef.current !== "authenticated") return;
      controller?.abort();
      controller = new AbortController();
      void refresh(range, controller.signal);
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      controller?.abort();
    };
  }, [range, refresh]);

  const authenticate = useCallback(async (token: string) => {
    await createSession(token);
    const loaded = await refresh(range);
    if (!loaded) throw new Error("会话已建立，但图库加载失败");
    setSettingsOpen(false);
  }, [range, refresh]);

  const updateTask = useCallback((id: string, patch: Partial<UploadTask>) => {
    setUploadTasks((current) => {
      const task = current.find((item) => item.id === id);
      if (!task) return current;
      return current.map((item) => item.id === id ? { ...task, ...patch } : item);
    });
  }, []);

  const finishTask = useCallback((id: string) => {
    setUploadTasks((current) => current.filter((item) => item.id !== id));
  }, []);

  const enqueueFiles = useCallback((incoming: File[]) => {
    if (authRef.current !== "authenticated") {
      notify("请先输入 Token", true);
      return;
    }
    const files = incoming.filter((file) => file.type.startsWith("image/")).slice(0, MAX_PASTE_FILES);
    if (files.length === 0) return;
    if (incoming.length > MAX_PASTE_FILES) notify(`一次最多上传 ${MAX_PASTE_FILES} 张`, true);

    const jobs = files.map((file) => {
      const id = `upload-${Date.now()}-${taskSequence.current++}`;
      return { id, file };
    });
    const uploadable = jobs.filter(({ file }) => file.size <= MAX_FILE_BYTES);
    const rejectedCount = jobs.length - uploadable.length;
    if (rejectedCount > 0) notify(rejectedCount === 1 ? "文件超过 25 MiB" : `${rejectedCount} 张图片超过 25 MiB`, true);
    if (uploadable.length === 0) return;
    setUploadTasks((current) => [
      ...current,
      ...uploadable.map(({ id }): UploadTask => ({ id, progress: 0, state: "queued" })),
    ]);

    uploadQueue.current = uploadQueue.current.then(async () => {
      const successful: ImageItem[] = [];
      const failures: string[] = [];
      for (const { id, file } of uploadable) {
        updateTask(id, { state: "optimizing", progress: 0 });
        try {
          const prepared = await prepareImageForUpload(file);
          updateTask(id, { state: "uploading" });
          const image = await uploadImage(
            prepared,
            (progress) => updateTask(id, { progress }),
            () => updateTask(id, { state: "processing", progress: 100 }),
          );
          setImages((current) => [image, ...current.filter((item) => item.id !== image.id)]);
          successful.push(image);
        } catch (reason) {
          const message = reason instanceof Error ? reason.message : "上传失败";
          failures.push(message);
          if (reason instanceof APIError && reason.status === 401) {
            expireSession();
            break;
          }
        } finally {
          finishTask(id);
        }
      }

      const batchIDs = new Set(uploadable.map(({ id }) => id));
      setUploadTasks((current) => current.filter((task) => !batchIDs.has(task.id)));

      if (failures.length > 0) {
        const message = failures.length === 1 && successful.length === 0 && rejectedCount === 0
          ? failures[0]
          : `${successful.length} 张上传完成，${failures.length + rejectedCount} 张失败`;
        notify(message, true);
      } else if (rejectedCount > 0) {
        if (successful.length > 0) notify(`${successful.length} 张上传完成，${rejectedCount} 张失败`, true);
      } else if (files.length === 1 && successful.length === 1) {
        try {
          await copyText(absoluteImageURL(successful[0].url));
          notify("链接已复制");
        } catch {
          notify("上传完成，自动复制失败", true);
        }
      } else if (successful.length > 0) {
        notify(`${successful.length} 张图片上传完成`);
      }
    });
  }, [expireSession, finishTask, notify, updateTask]);

  useEffect(() => {
    const handlePaste = (event: ClipboardEvent) => {
      const files = Array.from(event.clipboardData?.items ?? [])
        .filter((item) => item.kind === "file" && item.type.startsWith("image/"))
        .map((item) => item.getAsFile())
        .filter((file): file is File => file !== null);
      if (files.length === 0) return;
      event.preventDefault();
      enqueueFiles(files);
    };
    window.addEventListener("paste", handlePaste);
    return () => window.removeEventListener("paste", handlePaste);
  }, [enqueueFiles]);

  async function copyImage(image: ImageItem) {
    try {
      await copyText(absoluteImageURL(image.url));
      notify("链接已复制");
    } catch (reason) {
      notify(reason instanceof Error ? reason.message : "复制失败", true);
    }
  }

  async function removeImages(ids: string[]) {
    if (ids.length === 0 || !window.confirm(ids.length === 1 ? "永久删除这张图片？" : `永久删除选中的 ${ids.length} 张图片？`)) return;
    try {
      const deleted = await deleteImages(ids);
      if (deleted === ids.length) {
        const deletedSet = new Set(ids);
        setImages((current) => current.filter((image) => !deletedSet.has(image.id)));
      } else {
        await refresh(range);
      }
      setSelected(new Set());
      if (preview && ids.includes(preview.id)) setPreview(null);
      notify(deleted > 0 ? `已永久删除 ${deleted} 张图片` : "图片不存在或不属于当前空间", deleted === 0);
    } catch (reason) {
      if (reason instanceof APIError && reason.status === 401) expireSession();
      else notify(reason instanceof Error ? reason.message : "删除失败", true);
    }
  }

  function toggleSelected(id: string) {
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  function beginMarqueeSelection(event: ReactPointerEvent<HTMLElement>) {
    if (event.button !== 0 || event.pointerType === "touch") return;
    const target = event.target as Element;
    if (target.closest(".image-card, button, a, input, textarea, select, [contenteditable='true']")) return;

    event.preventDefault();
    marqueeGesture.current = {
      pointerId: event.pointerId,
      originX: event.clientX,
      originY: event.clientY,
      initialSelection: new Set(selected),
      additive: event.metaKey || event.ctrlKey || event.shiftKey,
      active: false,
    };
    event.currentTarget.setPointerCapture?.(event.pointerId);
  }

  function updateMarqueeSelection(event: ReactPointerEvent<HTMLElement>) {
    const gesture = marqueeGesture.current;
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    if (!gesture.active
      && Math.hypot(event.clientX - gesture.originX, event.clientY - gesture.originY) < MARQUEE_DRAG_THRESHOLD) return;

    gesture.active = true;
    event.preventDefault();
    const box = selectionBoxBetween(gesture.originX, gesture.originY, event.clientX, event.clientY);
    const next = gesture.additive ? new Set(gesture.initialSelection) : new Set<string>();
    gallerySelectionSurface.current?.querySelectorAll<HTMLElement>(".image-card[data-image-id]").forEach((card) => {
      if (intersectsSelectionBox(card.getBoundingClientRect(), box)) {
        const id = card.dataset.imageId;
        if (id) next.add(id);
      }
    });
    setSelectionBox(box);
    setSelected(next);
  }

  function finishMarqueeSelection(event: ReactPointerEvent<HTMLElement>, cancelled = false) {
    const gesture = marqueeGesture.current;
    if (!gesture || gesture.pointerId !== event.pointerId) return;

    if (cancelled && gesture.active) setSelected(new Set(gesture.initialSelection));
    else if (!gesture.active && !gesture.additive) setSelected(new Set());
    marqueeGesture.current = null;
    setSelectionBox(null);
    if (event.currentTarget.hasPointerCapture?.(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  }

  async function logout() {
    try {
      await deleteSession();
    } finally {
      expireSession();
    }
  }

  if (auth === "checking") {
    return <main className="loading-screen"><span className="spinner" aria-label="正在加载" /></main>;
  }
  if (auth === "required") {
    return <TokenPanel onAuthenticate={authenticate} />;
  }

  return (
    <div className="app-shell">
      <GlobalUploadProgress tasks={uploadTasks} />
      <header className="topbar">
        <div className="brand"><ImageIcon /><span>图床</span></div>
        {selected.size > 0 ? (
          <div className="selection-controls" role="toolbar" aria-label="批量操作">
            <strong aria-label={`已选择 ${selected.size} 张`}>{selected.size}</strong>
            <button type="button" onClick={() => setSelected(new Set(images.map((image) => image.id)))}>全选</button>
            <button className="icon-button icon-button--danger" type="button" aria-label="永久删除选中图片" onClick={() => void removeImages(Array.from(selected))}><TrashIcon /></button>
            <button className="icon-button" type="button" aria-label="退出多选" onClick={() => setSelected(new Set())}><CloseIcon /></button>
          </div>
        ) : (
          <nav className="range-switch" aria-label="时间范围">
            {RANGE_OPTIONS.map((option) => (
              <button key={option.value} type="button" className={range === option.value ? "is-active" : ""} onClick={() => setRange(option.value)}>
                {option.label}
              </button>
            ))}
          </nav>
        )}
        <div className="topbar__actions">
          {account?.is_admin ? <button className="icon-button" type="button" aria-label="用户管理" onClick={() => setAdminOpen(true)}><UsersIcon /></button> : null}
          <button className="icon-button" type="button" aria-label="设置 Token" onClick={() => setSettingsOpen(true)}><KeyIcon /></button>
          <button className="icon-button" type="button" aria-label="退出会话" onClick={() => void logout()}><LogoutIcon /></button>
        </div>
      </header>

      <main className="gallery-shell">
        <div className="paste-line"><kbd>Ctrl</kbd><span>+</span><kbd>V</kbd><span>粘贴图片即可上传</span></div>
        {galleryError ? (
          <div className="state-panel state-panel--error" role="alert">
            <span className="state-panel__mark"><AlertIcon /></span>
            <div className="state-panel__copy">
              <h1>暂时无法加载</h1>
              <p>图库连接遇到问题，请稍后重试。</p>
              <small>{galleryError}</small>
            </div>
            <button className="primary-button state-panel__retry" type="button" onClick={() => void refresh(range)}>重新加载</button>
          </div>
        ) : null}
        {!galleryError && loading && images.length === 0 ? <div className="gallery-loading"><span className="spinner" /></div> : null}
        {!galleryError && loading && images.length > 0 ? (
          <div className="gallery-refreshing" role="status" aria-label="正在刷新图库"><span className="spinner" /></div>
        ) : null}
        {!galleryError && !loading && images.length === 0 ? (
          <div className="empty-gallery"><ImageIcon /><p>粘贴第一张图片</p></div>
        ) : null}
        {images.length > 0 ? (
          <section
            ref={gallerySelectionSurface}
            className={`image-timeline${loading ? " image-timeline--loading" : ""}${selectionBox ? " image-timeline--selecting" : ""}`}
            aria-label="图库"
            onPointerDown={beginMarqueeSelection}
            onPointerMove={updateMarqueeSelection}
            onPointerUp={(event) => finishMarqueeSelection(event)}
            onPointerCancel={(event) => finishMarqueeSelection(event, true)}
          >
            {groupedImages.map((group) => (
              <div className="timeline-group" key={group.key}>
                <header className="timeline-group__label">
                  <strong>{group.label}</strong>
                  <span>{group.images.length} 张</span>
                </header>
                <div className="image-grid">
                  {group.images.map((image) => (
                    <ImageCard
                      key={image.id}
                      image={image}
                      selected={selected.has(image.id)}
                      selectionMode={selected.size > 0}
                      onOpen={() => setPreview(image)}
                      onCopy={() => void copyImage(image)}
                      onDelete={() => void removeImages([image.id])}
                      onLongSelect={() => setSelected((current) => new Set(current).add(image.id))}
                      onToggleSelect={() => toggleSelected(image.id)}
                    />
                  ))}
                </div>
              </div>
            ))}
            {selectionBox ? (
              <div
                className="marquee-selection"
                aria-hidden="true"
                style={{
                  left: selectionBox.left,
                  top: selectionBox.top,
                  width: selectionBox.width,
                  height: selectionBox.height,
                }}
              />
            ) : null}
          </section>
        ) : null}
        {images.length === 100 ? <p className="list-limit">当前显示最近 100 张</p> : null}
      </main>

      {preview ? <ImagePreview image={preview} onClose={() => setPreview(null)} onCopy={() => void copyImage(preview)} onDelete={() => void removeImages([preview.id])} /> : null}
      {settingsOpen ? <TokenPanel modal onClose={() => setSettingsOpen(false)} onAuthenticate={authenticate} /> : null}
      {adminOpen ? <AdminPanel onClose={() => setAdminOpen(false)} onSessionExpired={expireSession} onNotify={notify} /> : null}
      {toast ? <div key={toast.id} className={`toast${toast.error ? " toast--error" : ""}`} role="status">{toast.message}</div> : null}
    </div>
  );
}
