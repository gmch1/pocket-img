import type { UploadTask } from "../types";

interface GlobalUploadProgressProps {
  tasks: UploadTask[];
}

function taskProgress(task: UploadTask): number {
  if (task.state === "processing") return 100;
  if (task.state !== "uploading") return 0;
  return Math.min(99, Math.max(0, task.progress));
}

export function GlobalUploadProgress({ tasks }: GlobalUploadProgressProps) {
  if (tasks.length === 0) return null;

  const processing = tasks.some((task) => task.state === "processing");
  const preparing = tasks.some((task) => task.state === "optimizing");
  const indeterminate = processing || preparing;
  const progress = Math.round(tasks.reduce((total, task) => total + taskProgress(task), 0) / tasks.length);
  const label = processing ? "正在处理媒体" : preparing ? "正在准备图片" : "正在上传媒体";

  return (
    <div
      className={`global-upload-progress${indeterminate ? " global-upload-progress--indeterminate" : ""}`}
      role="progressbar"
      aria-label={label}
      aria-valuemin={indeterminate ? undefined : 0}
      aria-valuemax={indeterminate ? undefined : 100}
      aria-valuenow={indeterminate ? undefined : progress}
    >
      <i style={indeterminate ? undefined : { width: `${progress}%` }} />
    </div>
  );
}
