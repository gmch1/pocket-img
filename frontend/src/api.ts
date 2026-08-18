import type { AccountInfo, CreatedUser, GalleryRange, GalleryResponse, ImageItem } from "./types";

export class APIError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "APIError";
    this.status = status;
  }
}

async function responseError(response: Response): Promise<APIError> {
  let message = `请求失败 (${response.status})`;
  try {
    const body = (await response.json()) as { error?: string };
    if (body.error) message = body.error;
  } catch {
    // Keep the status-based fallback for non-JSON failures.
  }
  return new APIError(response.status, message);
}

export async function createSession(token: string): Promise<void> {
  const response = await fetch("/api/auth/session", {
    method: "POST",
    credentials: "same-origin",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw await responseError(response);
}

export async function deleteSession(): Promise<void> {
  const response = await fetch("/api/auth/session", {
    method: "DELETE",
    credentials: "same-origin",
  });
  if (!response.ok && response.status !== 401) throw await responseError(response);
}

export async function listImages(range: GalleryRange, signal?: AbortSignal): Promise<GalleryResponse> {
  const query = new URLSearchParams({ range, limit: "100" });
  const response = await fetch(`/api/images?${query}`, {
    credentials: "same-origin",
    signal,
  });
  if (!response.ok) throw await responseError(response);
  return (await response.json()) as GalleryResponse;
}

export function subscribeGalleryChanges(onChange: () => void): () => void {
  if (typeof EventSource === "undefined") return () => undefined;
  const source = new EventSource("/api/images/events", { withCredentials: true });
  source.addEventListener("gallery", onChange);
  return () => {
    source.removeEventListener("gallery", onChange);
    source.close();
  };
}

export async function listUsers(): Promise<AccountInfo[]> {
  const response = await fetch("/api/admin/users", { credentials: "same-origin" });
  if (!response.ok) throw await responseError(response);
  const body = (await response.json()) as { users: AccountInfo[] };
  return body.users;
}

export async function createUser(spaceID: string): Promise<CreatedUser> {
  const response = await fetch("/api/admin/users", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ space_id: spaceID }),
  });
  if (!response.ok) throw await responseError(response);
  return (await response.json()) as CreatedUser;
}

export async function deleteImages(ids: string[]): Promise<number> {
  const response = await fetch("/api/images", {
    method: "DELETE",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ids }),
  });
  if (!response.ok) throw await responseError(response);
  const body = (await response.json()) as { deleted: number };
  return body.deleted;
}

export function uploadImage(
  file: File,
  onProgress: (progress: number) => void,
  onProcessing?: () => void,
): Promise<ImageItem> {
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open("POST", "/api/images");
    request.withCredentials = true;
    request.upload.addEventListener("progress", (event) => {
      if (event.lengthComputable) onProgress(Math.min(99, Math.round((event.loaded / event.total) * 100)));
    });
    request.upload.addEventListener("load", () => onProcessing?.());
    request.addEventListener("load", () => {
      let body: { image?: ImageItem; error?: string } = {};
      try {
        body = JSON.parse(request.responseText) as typeof body;
      } catch {
        // The status-based error below is enough for a malformed response.
      }
      if (request.status >= 200 && request.status < 300 && body.image) {
        onProgress(100);
        resolve(body.image);
        return;
      }
      reject(new APIError(request.status, body.error ?? `上传失败 (${request.status})`));
    });
    request.addEventListener("error", () => reject(new APIError(0, "无法连接后端")));
    request.addEventListener("abort", () => reject(new APIError(0, "上传已取消")));

    const form = new FormData();
    form.append("file", file, file.name || "clipboard-image");
    request.send(form);
  });
}

export function absoluteImageURL(path: string): string {
  return new URL(path, window.location.origin).href;
}
