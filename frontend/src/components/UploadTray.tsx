import { CloseIcon, ImageIcon } from "../icons";
import type { UploadTask } from "../types";

interface UploadTrayProps {
  tasks: UploadTask[];
  onClear: () => void;
}

const MAX_VISIBLE_TASKS = 5;

function taskPriority(task: UploadTask): number {
  if (task.state === "optimizing" || task.state === "uploading" || task.state === "processing") return 0;
  if (task.state === "queued") return 1;
  return 2;
}

function formatUploadTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const pad = (part: number) => String(part).padStart(2, "0");
  return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function UploadTray({ tasks, onClear }: UploadTrayProps) {
  if (tasks.length === 0) return null;
  const transferring = tasks.some((task) => task.state === "queued" || task.state === "optimizing" || task.state === "uploading");
  const processing = tasks.some((task) => task.state === "processing");
  const active = transferring || processing;
  const visibleTasks = [...tasks]
    .sort((left, right) => taskPriority(left) - taskPriority(right) || Date.parse(right.uploadedAt) - Date.parse(left.uploadedAt))
    .slice(0, MAX_VISIBLE_TASKS);

  return (
    <aside className="upload-tray" aria-label="上传状态">
      <div className="upload-tray__header">
        <span>{transferring ? "正在上传" : processing ? "正在处理" : "上传结果"}</span>
        <div>
          {!active ? <button className="icon-button" type="button" aria-label="清除上传结果" onClick={onClear}><CloseIcon /></button> : null}
        </div>
      </div>
      <div className="upload-tray__list">
        {visibleTasks.map((task) => (
          <div className="upload-row" key={task.id}>
            <ImageIcon />
            <div className="upload-row__body">
              <div className="upload-row__meta">
                <span>{task.name}</span>
                <time dateTime={task.uploadedAt}>{formatUploadTime(task.uploadedAt)}</time>
              </div>
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
