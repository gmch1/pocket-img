export type GalleryRange = "today" | "7d" | "30d" | "all";

export interface ImageItem {
  id: string;
  width: number;
  height: number;
  byte_size: number;
  thumbnail_size: number;
  animated: boolean;
  created_at: string;
  url: string;
  thumbnail_url: string;
}

export type UploadState = "queued" | "uploading" | "done" | "error";

export interface UploadTask {
  id: string;
  name: string;
  progress: number;
  state: UploadState;
  image?: ImageItem;
  error?: string;
}
