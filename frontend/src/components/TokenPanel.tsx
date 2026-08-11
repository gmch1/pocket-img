import { useState, type FormEvent } from "react";
import { CloseIcon, KeyIcon } from "../icons";

interface TokenPanelProps {
  modal?: boolean;
  onClose?: () => void;
  onAuthenticate: (token: string) => Promise<void>;
}

export function TokenPanel({ modal = false, onClose, onAuthenticate }: TokenPanelProps) {
  const [token, setToken] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");

  async function submit(event: FormEvent) {
    event.preventDefault();
    const value = token.trim();
    if (!value || submitting) return;
    setSubmitting(true);
    setError("");
    try {
      await onAuthenticate(value);
      setToken("");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Token 无效");
    } finally {
      setSubmitting(false);
    }
  }

  const content = (
    <section className={`token-panel${modal ? " token-panel--modal" : ""}`} aria-label="Token 设置">
      {modal && onClose ? (
        <button className="icon-button token-panel__close" type="button" aria-label="关闭" onClick={onClose}>
          <CloseIcon />
        </button>
      ) : null}
      <div className="token-panel__mark"><KeyIcon /></div>
      <h1>访问图库</h1>
      <form onSubmit={submit}>
        <input
          autoFocus
          autoComplete="off"
          spellCheck={false}
          type="password"
          value={token}
          onChange={(event) => setToken(event.target.value)}
          placeholder="Token"
          aria-label="Token"
        />
        <button className="primary-button" type="submit" disabled={!token.trim() || submitting}>
          {submitting ? "验证中" : "进入"}
        </button>
      </form>
      {error ? <p className="form-error" role="alert">{error}</p> : null}
    </section>
  );

  if (!modal) return <main className="token-screen">{content}</main>;
  return <div className="modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose?.()}>{content}</div>;
}
