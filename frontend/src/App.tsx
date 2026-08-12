import { useCallback, useEffect, useRef, useState } from "react";
import { APIError, absoluteImageURL, createSession, deleteImages, deleteSession, listImages, uploadImage } from "./api";
import { copyText } from "./clipboard";
import { prepareImageForUpload } from "./image-compression";
import { ImageCard } from "./components/ImageCard";
import { ImagePreview } from "./components/ImagePreview";
import { TokenPanel } from "./components/TokenPanel";
import { UploadTray } from "./components/UploadTray";
import { CloseIcon, ImageIcon, KeyIcon, LogoutIcon, TrashIcon } from "./icons";
import type { GalleryRange, ImageItem, UploadTask } from "./types";

type AuthState = "checking" | "required" | "authenticated";
type Toast = { id: number; message: string; error: boolean };

const RANGE_OPTIONS: ReadonlyArray<{ value: GalleryRange; label: string }> = [
  { value: "today", label: "今天" },
  { value: "7d", label: "7 天" },
  { value: "30d", label: "30 天" },
  { value: "all", label: "全部" },
];

const MAX_PASTE_FILES = 20;
const MAX_FILE_BYTES = 25 * 1024 * 1024;

export default function App() {
  const [auth, setAuth] = useState<AuthState>("checking");
  const [range, setRange] = useState<GalleryRange>("today");
  const [images, setImages] = useState<ImageItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [galleryError, setGalleryError] = useState("");
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [preview, setPreview] = useState<ImageItem | null>(null);
  const [selected, setSelected] = useState<Set<string>>(() => new Set());
  const [uploadTasks, setUploadTasks] = useState<UploadTask[]>([]);
  const [toast, setToast] = useState<Toast | null>(null);
  const uploadQueue = useRef<Promise<void>>(Promise.resolve());
  const taskSequence = useRef(0);
  const toastTimer = useRef<number | undefined>(undefined);

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
  }, []);

  const refresh = useCallback(async (nextRange: GalleryRange, signal?: AbortSignal): Promise<boolean> => {
    setLoading(true);
    setGalleryError("");
    try {
      const nextImages = await listImages(nextRange, signal);
      setImages(nextImages);
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

  const authenticate = useCallback(async (token: string) => {
    await createSession(token);
    const loaded = await refresh(range);
    if (!loaded) throw new Error("会话已建立，但图库加载失败");
    setSettingsOpen(false);
  }, [range, refresh]);

  const updateTask = useCallback((id: string, patch: Partial<UploadTask>) => {
    setUploadTasks((current) => current.map((task) => task.id === id ? { ...task, ...patch } : task));
  }, []);

  const enqueueFiles = useCallback((incoming: File[]) => {
    if (auth !== "authenticated") {
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
    setUploadTasks((current) => [
      ...current,
      ...jobs.map(({ id, file }): UploadTask => file.size > MAX_FILE_BYTES
        ? { id, name: file.name || "剪贴板图片", progress: 100, state: "error", error: "文件超过 25 MiB" }
        : { id, name: file.name || "剪贴板图片", progress: 0, state: "queued" }),
    ]);

    const uploadable = jobs.filter(({ file }) => file.size <= MAX_FILE_BYTES);
    if (uploadable.length === 0) return;
    uploadQueue.current = uploadQueue.current.then(async () => {
      const successful: ImageItem[] = [];
      for (const { id, file } of uploadable) {
        updateTask(id, { state: "optimizing", progress: 0, error: undefined });
        try {
          const prepared = await prepareImageForUpload(file);
          updateTask(id, { state: "uploading" });
          const image = await uploadImage(
            prepared,
            (progress) => updateTask(id, { progress }),
            () => updateTask(id, { state: "processing", progress: 100 }),
          );
          updateTask(id, { state: "done", progress: 100, image });
          setImages((current) => [image, ...current.filter((item) => item.id !== image.id)]);
          successful.push(image);
        } catch (reason) {
          const message = reason instanceof Error ? reason.message : "上传失败";
          updateTask(id, { state: "error", progress: 100, error: message });
          if (reason instanceof APIError && reason.status === 401) {
            expireSession();
            break;
          }
        }
      }

      if (files.length === 1 && successful.length === 1) {
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
  }, [auth, expireSession, notify, updateTask]);

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

  async function logout() {
    try {
      await deleteSession();
    } finally {
      expireSession();
    }
  }

  async function copyAllUploads() {
    const links = uploadTasks
      .filter((task): task is UploadTask & { image: ImageItem } => task.state === "done" && task.image !== undefined)
      .map((task) => absoluteImageURL(task.image.url));
    if (links.length === 0) return;
    try {
      await copyText(links.join("\n"));
      notify(`已复制 ${links.length} 个链接`);
    } catch (reason) {
      notify(reason instanceof Error ? reason.message : "复制失败", true);
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
      <header className="topbar">
        <div className="brand"><ImageIcon /><span>图床</span></div>
        <nav className="range-switch" aria-label="时间范围">
          {RANGE_OPTIONS.map((option) => (
            <button key={option.value} type="button" className={range === option.value ? "is-active" : ""} onClick={() => setRange(option.value)}>
              {option.label}
            </button>
          ))}
        </nav>
        <div className="topbar__actions">
          <button className="icon-button" type="button" aria-label="设置 Token" onClick={() => setSettingsOpen(true)}><KeyIcon /></button>
          <button className="icon-button" type="button" aria-label="退出会话" onClick={() => void logout()}><LogoutIcon /></button>
        </div>
      </header>

      <main className="gallery-shell">
        <div className="paste-line"><kbd>Ctrl</kbd><span>+</span><kbd>V</kbd><span>粘贴图片即可上传</span></div>
        {galleryError ? (
          <div className="state-panel state-panel--error"><p>{galleryError}</p><button type="button" onClick={() => void refresh(range)}>重试</button></div>
        ) : null}
        {!galleryError && loading && images.length === 0 ? <div className="gallery-loading"><span className="spinner" /></div> : null}
        {!galleryError && loading && images.length > 0 ? (
          <div className="gallery-refreshing" role="status" aria-label="正在刷新图库"><span className="spinner" /></div>
        ) : null}
        {!galleryError && !loading && images.length === 0 ? (
          <div className="empty-gallery"><ImageIcon /><p>粘贴第一张图片</p></div>
        ) : null}
        {images.length > 0 ? (
          <section className={`waterfall${loading ? " waterfall--loading" : ""}`} aria-label="图库">
            {images.map((image) => (
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
          </section>
        ) : null}
        {images.length === 100 ? <p className="list-limit">当前显示最近 100 张</p> : null}
      </main>

      {selected.size > 0 ? (
        <div className="selection-toolbar" role="toolbar" aria-label="批量操作">
          <strong>{selected.size}</strong>
          <button type="button" onClick={() => setSelected(new Set(images.map((image) => image.id)))}>全选</button>
          <button className="selection-toolbar__danger" type="button" aria-label="永久删除选中图片" onClick={() => void removeImages(Array.from(selected))}><TrashIcon /></button>
          <button className="icon-button" type="button" aria-label="退出多选" onClick={() => setSelected(new Set())}><CloseIcon /></button>
        </div>
      ) : null}

      <UploadTray tasks={uploadTasks} onCopyAll={() => void copyAllUploads()} onClear={() => setUploadTasks([])} />
      {preview ? <ImagePreview image={preview} onClose={() => setPreview(null)} onCopy={() => void copyImage(preview)} onDelete={() => void removeImages([preview.id])} /> : null}
      {settingsOpen ? <TokenPanel modal onClose={() => setSettingsOpen(false)} onAuthenticate={authenticate} /> : null}
      {toast ? <div key={toast.id} className={`toast${toast.error ? " toast--error" : ""}`} role="status">{toast.message}</div> : null}
    </div>
  );
}
