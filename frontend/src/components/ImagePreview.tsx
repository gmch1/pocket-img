import { useEffect } from "react";
import { CloseIcon, CopyIcon, TrashIcon } from "../icons";
import type { ImageItem } from "../types";

interface ImagePreviewProps {
  image: ImageItem;
  onClose: () => void;
  onCopy: () => void;
  onDelete: () => void;
}

export function ImagePreview({ image, onClose, onCopy, onDelete }: ImagePreviewProps) {
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => event.key === "Escape" && onClose();
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose]);

  return (
    <div className="preview-backdrop" role="dialog" aria-modal="true" aria-label="图片预览" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="preview-shell">
        <img src={image.url} alt="" />
        <div className="preview-actions">
          <button className="icon-button" type="button" aria-label="复制图片链接" onClick={onCopy}><CopyIcon /></button>
          <button className="icon-button icon-button--danger" type="button" aria-label="永久删除图片" onClick={onDelete}><TrashIcon /></button>
          <button className="icon-button" type="button" aria-label="关闭预览" onClick={onClose}><CloseIcon /></button>
        </div>
      </div>
    </div>
  );
}
