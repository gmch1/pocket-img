import { useEffect } from "react";
import { ChevronLeftIcon, ChevronRightIcon, CloseIcon, CopyIcon, TrashIcon } from "../icons";
import type { ImageItem } from "../types";

interface ImagePreviewProps {
  image: ImageItem;
  onClose: () => void;
  onCopy: () => void;
  onDelete: () => void;
  onPrevious?: () => void;
  onNext?: () => void;
}

export function ImagePreview({ image, onClose, onCopy, onDelete, onPrevious, onNext }: ImagePreviewProps) {
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
      else if (event.key === "ArrowLeft" && onPrevious) {
        event.preventDefault();
        onPrevious();
      } else if (event.key === "ArrowRight" && onNext) {
        event.preventDefault();
        onNext();
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose, onNext, onPrevious]);

  const showNavigation = Boolean(onPrevious || onNext);

  return (
    <div className="preview-backdrop" role="dialog" aria-modal="true" aria-label="图片预览" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="preview-shell">
        <img src={image.url} alt="" />
        {showNavigation ? (
          <>
            <button className="preview-nav preview-nav--previous" type="button" aria-label="上一张图片" disabled={!onPrevious} onClick={onPrevious}><ChevronLeftIcon /></button>
            <button className="preview-nav preview-nav--next" type="button" aria-label="下一张图片" disabled={!onNext} onClick={onNext}><ChevronRightIcon /></button>
          </>
        ) : null}
        <div className="preview-actions">
          <button className="icon-button" type="button" aria-label="复制图片链接" onClick={onCopy}><CopyIcon /></button>
          <button className="icon-button icon-button--danger" type="button" aria-label="永久删除图片" onClick={onDelete}><TrashIcon /></button>
          <button className="icon-button" type="button" aria-label="关闭预览" onClick={onClose}><CloseIcon /></button>
        </div>
      </div>
    </div>
  );
}
