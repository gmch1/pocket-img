import { useEffect, useState, type FormEvent } from "react";
import { APIError, createUser, listUsers } from "../api";
import { copyText } from "../clipboard";
import { CloseIcon, CopyIcon, UsersIcon } from "../icons";
import type { AccountInfo, CreatedUser } from "../types";

interface AdminPanelProps {
  onClose: () => void;
  onSessionExpired: () => void;
  onNotify: (message: string, error?: boolean) => void;
}

export function AdminPanel({ onClose, onSessionExpired, onNotify }: AdminPanelProps) {
  const [users, setUsers] = useState<AccountInfo[]>([]);
  const [spaceID, setSpaceID] = useState("");
  const [created, setCreated] = useState<CreatedUser | null>(null);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    void listUsers()
      .then((result) => { if (active) setUsers(result); })
      .catch((reason) => {
        if (!active) return;
        if (reason instanceof APIError && reason.status === 401) onSessionExpired();
        else setError(reason instanceof Error ? reason.message : "用户列表加载失败");
      })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [onSessionExpired]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    const value = spaceID.trim();
    if (!value || submitting) return;
    setSubmitting(true);
    setError("");
    setCreated(null);
    try {
      const result = await createUser(value);
      setUsers((current) => [...current, result.user]);
      setCreated(result);
      setSpaceID("");
    } catch (reason) {
      if (reason instanceof APIError && reason.status === 401) onSessionExpired();
      else setError(reason instanceof Error ? reason.message : "创建用户失败");
    } finally {
      setSubmitting(false);
    }
  }

  async function copyCreatedToken() {
    if (!created) return;
    try {
      await copyText(created.token);
      onNotify("Token 已复制");
    } catch {
      onNotify("复制 Token 失败", true);
    }
  }

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="admin-panel" role="dialog" aria-modal="true" aria-label="用户管理">
        <header className="admin-panel__header">
          <div><UsersIcon /><h1>用户</h1></div>
          <button className="icon-button" type="button" aria-label="关闭用户管理" onClick={onClose}><CloseIcon /></button>
        </header>

        <form className="admin-create" onSubmit={submit}>
          <input
            aria-label="新用户空间 ID"
            autoComplete="off"
            spellCheck={false}
            value={spaceID}
            onChange={(event) => setSpaceID(event.target.value)}
            placeholder="空间 ID"
          />
          <button className="primary-button" type="submit" disabled={!spaceID.trim() || submitting}>
            {submitting ? "创建中" : "创建 Token"}
          </button>
          <small>默认 10 GiB · 保存 90 天</small>
        </form>

        {created ? (
          <div className="created-token" role="status">
            <span>{created.user.space_id}</span>
            <code>{created.token}</code>
            <button className="icon-button" type="button" aria-label="复制新 Token" onClick={() => void copyCreatedToken()}><CopyIcon /></button>
            <small>Token 只显示这一次</small>
          </div>
        ) : null}
        {error ? <p className="form-error" role="alert">{error}</p> : null}

        <div className="user-list" aria-label="用户列表">
          {loading ? <div className="user-list__loading"><span className="spinner" /></div> : users.map((user) => (
            <div className="user-row" key={user.space_id}>
              <div><strong>{user.space_id}</strong>{user.is_admin ? <span>管理员</span> : null}</div>
              <small>{formatBytes(user.used_bytes)} / {formatBytes(user.quota_bytes)} · {user.image_count} 项 · {user.retention_days} 天</small>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function formatBytes(value: number): string {
  if (value < 1024 * 1024) return `${Math.max(0, value / 1024).toFixed(1)} KiB`;
  if (value < 1024 * 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MiB`;
  return `${(value / (1024 * 1024 * 1024)).toFixed(2)} GiB`;
}
