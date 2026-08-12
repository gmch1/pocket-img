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

export interface AccountInfo {
  space_id: string;
  is_admin: boolean;
  quota_bytes: number;
  used_bytes: number;
  image_count: number;
  retention_days: number;
  enabled: boolean;
  created_at?: string;
}

export interface GalleryResponse {
  images: ImageItem[];
  account: AccountInfo;
}

export interface CreatedUser {
  user: AccountInfo;
  token: string;
}

export type UploadState = "queued" | "optimizing" | "uploading" | "processing";

export interface UploadTask {
  id: string;
  progress: number;
  state: UploadState;
}
