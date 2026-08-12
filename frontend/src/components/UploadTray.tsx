import { CloseIcon, CopyIcon, ImageIcon } from "../icons";
import type { UploadTask } from "../types";

interface UploadTrayProps {
  tasks: UploadTask[];
  onCopyAll: () => void;
  onClear: () => void;
}

export function UploadTray({ tasks, onCopyAll, onClear }: UploadTrayProps) {
  if (tasks.length === 0) return null;
  const completed = tasks.filter((task) => task.state === "done");
  const transferring = tasks.some((task) => task.state === "queued" || task.state === "optimizing" || task.state === "uploading");
  const processing = tasks.some((task) => task.state === "processing");
  const active = transferring || processing;

  return (
    <aside className="upload-tray" aria-label="上传状态">
      <div className="upload-tray__header">
        <span>{transferring ? "正在上传" : processing ? "正在处理" : "上传结果"}</span>
        <div>
          {completed.length > 1 ? <button className="icon-button" type="button" aria-label="复制全部链接" onClick={onCopyAll}><CopyIcon /></button> : null}
          {!active ? <button className="icon-button" type="button" aria-label="清除上传结果" onClick={onClear}><CloseIcon /></button> : null}
        </div>
      </div>
      <div className="upload-tray__list">
        {tasks.map((task) => (
          <div className="upload-row" key={task.id}>
            <ImageIcon />
            <div className="upload-row__body">
              <span>{task.name}</span>
              <div className={`progress-track${task.state === "error" ? " progress-track--error" : ""}${task.state === "processing" ? " progress-track--processing" : ""}`}>
                <i style={{ width: `${task.state === "error" ? 100 : task.progress}%` }} />
              </div>
              {task.error ? <small>{task.error}</small> : null}
            </div>
            <b>{task.state === "done" ? "✓" : task.state === "error" ? "!" : task.state === "optimizing" ? "…" : task.state === "processing" ? "处理中" : `${task.progress}%`}</b>
          </div>
        ))}
      </div>
    </aside>
  );
}
