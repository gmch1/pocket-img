import { useEffect, useState } from "react";
import { revokeClientSetupToken, rotateClientSetupToken } from "../api";
import { copyText } from "../clipboard";
import { CloseIcon, CopyIcon, KeyIcon, LaptopIcon } from "../icons";
import type { ClientSetup } from "../types";

interface ClientSetupGuideProps {
  setup: ClientSetup;
  onClose: () => void;
  onTokenConfigured: (configured: boolean) => void;
  onSessionExpired: () => void;
  onNotify: (message: string, error?: boolean) => void;
}

type PendingAction = "generate" | "revoke" | null;

export function ClientSetupGuide({
  setup,
  onClose,
  onTokenConfigured,
  onSessionExpired,
  onNotify,
}: ClientSetupGuideProps) {
  const [token, setToken] = useState<string | null>(null);
  const [pending, setPending] = useState<PendingAction>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose]);

  async function copyValue(value: string, successMessage: string) {
    try {
      await copyText(value);
      onNotify(successMessage);
    } catch {
      onNotify("复制失败", true);
    }
  }

  async function generateToken() {
    if (pending) return;
    if (setup.token_configured && !window.confirm("重新生成会立即撤销旧 Token，已配置的客户端需要填写新 Token。继续吗？")) return;
    setPending("generate");
    setError("");
    try {
      const generated = await rotateClientSetupToken();
      setToken(generated);
      onTokenConfigured(true);
    } catch (reason) {
      if (isUnauthorized(reason)) onSessionExpired();
      else setError(reason instanceof Error ? reason.message : "生成 Token 失败");
    } finally {
      setPending(null);
    }
  }

  async function revokeToken() {
    if (pending || !setup.token_configured) return;
    if (!window.confirm("撤销后，已经填写此 Token 的客户端将无法继续上传。确定撤销吗？")) return;
    setPending("revoke");
    setError("");
    try {
      await revokeClientSetupToken();
      setToken(null);
      onTokenConfigured(false);
      onNotify("客户端 Token 已撤销");
    } catch (reason) {
      if (isUnauthorized(reason)) onSessionExpired();
      else setError(reason instanceof Error ? reason.message : "撤销 Token 失败");
    } finally {
      setPending(null);
    }
  }

  const download = setup.download;
  const downloadURL = download ? new URL(download.url, document.baseURI).href : null;
  const managementURL = new URL(setup.management_url, window.location.origin).href;

  return (
    <div className="modal-backdrop client-setup-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="client-setup" role="dialog" aria-modal="true" aria-label="客户端设置">
        <header className="client-setup__header">
          <div>
            <span className="client-setup__mark"><LaptopIcon /></span>
            <div>
              <p>PocketIMG {setup.app_version}</p>
              <h1>客户端设置</h1>
            </div>
          </div>
          <button className="icon-button" type="button" aria-label="关闭客户端设置" onClick={onClose}><CloseIcon /></button>
        </header>

        <div className="client-setup__identity">
          <span>当前飞牛用户</span>
          <strong>{setup.user.display_name || setup.user.space_id}</strong>
          {setup.user.is_admin ? <small>管理员</small> : null}
        </div>

        <div className="client-setup__addresses">
          <AddressCard
            title="管理地址"
            description="在浏览器中管理图库，使用当前飞牛账号登录。"
            value={managementURL}
            onCopy={() => void copyValue(managementURL, "管理地址已复制")}
          />
          <AddressCard
            important
            title="macOS 客户端服务地址"
            description="PocketIMG Shot 的“服务器地址”只填写这一项，不要填写上方管理地址。"
            value={setup.service_url}
            onCopy={() => void copyValue(setup.service_url, "客户端服务地址已复制")}
          />
        </div>

        {download ? (
          <section className="client-setup__section client-download">
            <div className="client-setup__section-heading">
              <div><h2>下载 PocketIMG Shot</h2><p>安装包由这台飞牛 NAS 本地提供。</p></div>
              <a className="primary-button client-download__button" href={downloadURL ?? undefined} download={download.filename}>下载 macOS 客户端</a>
            </div>
            <dl className="client-download__facts">
              <div><dt>版本</dt><dd>{download.version}</dd></div>
              <div><dt>设备</dt><dd>Apple Silicon ({download.architecture})</dd></div>
              <div><dt>系统</dt><dd>macOS {download.minimum_macos}+</dd></div>
              <div><dt>大小</dt><dd>{formatBytes(download.size_bytes)}</dd></div>
            </dl>
            <div className="client-download__checksum">
              <span>SHA-256</span>
              <code>{download.sha256}</code>
              <button className="icon-button" type="button" aria-label="复制安装包 SHA-256" onClick={() => void copyValue(download.sha256, "SHA-256 已复制")}><CopyIcon /></button>
            </div>
          </section>
        ) : (
          <section className="client-setup__section client-download client-download--unavailable">
            <h2>macOS 客户端</h2>
            <p>此版本没有附带本地安装包，请联系管理员更新飞牛应用。</p>
          </section>
        )}

        <section className="client-setup__section client-token">
          <div className="client-setup__section-heading">
            <div>
              <h2>客户端 Token</h2>
              <p>在 PocketIMG Shot 的“Token”中填写。不要填写飞牛用户名或密码。</p>
            </div>
            <span className={`client-token__status${setup.token_configured ? " is-configured" : ""}`}>
              {setup.token_configured ? "已配置" : "未配置"}
            </span>
          </div>

          {token ? (
            <div className="client-token__value" role="status">
              <span>请立即复制，关闭此窗口后不会再次显示</span>
              <code>{token}</code>
              <button className="icon-button" type="button" aria-label="复制客户端 Token" onClick={() => void copyValue(token, "客户端 Token 已复制")}><CopyIcon /></button>
            </div>
          ) : setup.token_configured ? (
            <p className="client-token__hint">现有 Token 无法再次查看。需要配置新客户端时，请重新生成。</p>
          ) : (
            <p className="client-token__hint">还没有客户端 Token。生成后只会在当前窗口显示一次。</p>
          )}

          <div className="client-token__actions">
            <button className="primary-button" type="button" disabled={pending !== null} onClick={() => void generateToken()}>
              <KeyIcon />
              {pending === "generate" ? "生成中…" : setup.token_configured ? "重新生成 Token" : "生成 Token"}
            </button>
            {setup.token_configured ? (
              <button className="secondary-button secondary-button--danger" type="button" disabled={pending !== null} onClick={() => void revokeToken()}>
                {pending === "revoke" ? "撤销中…" : "撤销 Token"}
              </button>
            ) : null}
          </div>
          {error ? <p className="form-error" role="alert">{error}</p> : null}
        </section>

        <aside className="client-setup__mobile-note">
          <strong>手机无需安装客户端</strong>
          <span>直接使用浏览器打开上方管理地址即可。</span>
        </aside>
      </section>
    </div>
  );
}

interface AddressCardProps {
  title: string;
  description: string;
  value: string;
  important?: boolean;
  onCopy: () => void;
}

function AddressCard({ title, description, value, important = false, onCopy }: AddressCardProps) {
  return (
    <section className={`client-address${important ? " client-address--important" : ""}`}>
      <div><h2>{title}</h2>{important ? <span>填入客户端</span> : null}</div>
      <p>{description}</p>
      <div className="client-address__value">
        <code>{value}</code>
        <button className="icon-button" type="button" aria-label={`复制${title}`} onClick={onCopy}><CopyIcon /></button>
      </div>
    </section>
  );
}

function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return "未知";
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / (1024 * 1024)).toFixed(1)} MiB`;
}

function isUnauthorized(reason: unknown): boolean {
  return reason instanceof Error && "status" in reason && reason.status === 401;
}
