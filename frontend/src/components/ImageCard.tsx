import { useRef, type KeyboardEvent, type PointerEvent } from "react";
import { CheckIcon, CopyIcon, TrashIcon } from "../icons";
import type { ImageItem } from "../types";

interface ImageCardProps {
  image: ImageItem;
  selected: boolean;
  selectionMode: boolean;
  onOpen: () => void;
  onCopy: () => void;
  onDelete: () => void;
  onLongSelect: () => void;
  onToggleSelect: () => void;
}

export function ImageCard({ image, selected, selectionMode, onOpen, onCopy, onDelete, onLongSelect, onToggleSelect }: ImageCardProps) {
  const timer = useRef<number | undefined>(undefined);
  const origin = useRef({ x: 0, y: 0 });
  const suppressClick = useRef(false);
  const isVideo = image.media_type === "video/mp4";
  const displayURL = image.display_url ?? image.url;

  function cancelLongPress() {
    if (timer.current !== undefined) window.clearTimeout(timer.current);
    timer.current = undefined;
  }

  function pointerDown(event: PointerEvent<HTMLElement>) {
    if (event.button !== 0) return;
    origin.current = { x: event.clientX, y: event.clientY };
    suppressClick.current = false;
    timer.current = window.setTimeout(() => {
      suppressClick.current = true;
      onLongSelect();
    }, 500);
  }

  function pointerMove(event: PointerEvent<HTMLElement>) {
    if (Math.abs(event.clientX - origin.current.x) > 8 || Math.abs(event.clientY - origin.current.y) > 8) cancelLongPress();
  }

  function activate() {
    if (suppressClick.current) {
      suppressClick.current = false;
      return;
    }
    if (selectionMode) onToggleSelect();
    else onOpen();
  }

  function keyDown(event: KeyboardEvent<HTMLElement>) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      activate();
    }
  }

  return (
    <article
      className={`image-card${selected ? " image-card--selected" : ""}`}
      data-image-id={image.id}
      tabIndex={0}
      role="button"
      aria-pressed={selectionMode ? selected : undefined}
      onPointerDown={pointerDown}
      onPointerMove={pointerMove}
      onPointerUp={cancelLongPress}
      onPointerCancel={cancelLongPress}
      onClick={activate}
      onKeyDown={keyDown}
    >
      <div className="image-card__media">
        {isVideo ? (
          <video
            src={displayURL}
            poster={image.thumbnail_url !== displayURL ? image.thumbnail_url : undefined}
            muted
            preload="metadata"
            playsInline
            draggable={false}
          />
        ) : <img src={image.thumbnail_url} alt="" loading="lazy" draggable={false} />}
        {selected ? <span className="selection-mark"><CheckIcon /></span> : null}
        {isVideo
          ? <span className="media-type-mark">视频</span>
          : image.animated ? <span className="media-type-mark">GIF</span> : null}
        {!selectionMode ? (
          <div className="image-card__actions" onClick={(event) => event.stopPropagation()} onPointerDown={(event) => event.stopPropagation()}>
            <button className="icon-button" type="button" aria-label="复制媒体链接" onClick={onCopy}><CopyIcon /></button>
            <button className="icon-button icon-button--danger" type="button" aria-label="永久删除媒体" onClick={onDelete}><TrashIcon /></button>
          </div>
        ) : null}
      </div>
    </article>
  );
}
