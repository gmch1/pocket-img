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
    if (setup.token_configured && !window.confirm("重新生成会让旧连接凭证和已有客户端会话立即失效，所有已连接的 Mac 都需要填写新凭证。继续吗？")) return;
    setPending("generate");
    setError("");
    try {
      const generated = await rotateClientSetupToken();
      setToken(generated);
      onTokenConfigured(true);
    } catch (reason) {
      if (isUnauthorized(reason)) onSessionExpired();
      else setError(reason instanceof Error ? reason.message : "生成连接凭证失败");
    } finally {
      setPending(null);
    }
  }

  async function revokeToken() {
    if (pending || !setup.token_configured) return;
    if (!window.confirm("撤销后，所有使用此连接凭证的 Mac 都将无法访问当前图库。确定撤销吗？")) return;
    setPending("revoke");
    setError("");
    try {
      await revokeClientSetupToken();
      setToken(null);
      onTokenConfigured(false);
      onNotify("Mac 连接凭证已撤销");
    } catch (reason) {
      if (isUnauthorized(reason)) onSessionExpired();
      else setError(reason instanceof Error ? reason.message : "撤销连接凭证失败");
    } finally {
      setPending(null);
    }
  }

  const download = setup.download;
  const downloadURL = download ? new URL(download.url, document.baseURI).href : null;
  const managementURL = new URL(setup.management_url, window.location.origin).href;
  const userLabel = setup.user.display_name || setup.user.space_id;

  return (
    <div className="modal-backdrop client-setup-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="client-setup" role="dialog" aria-modal="true" aria-label="连接 Mac 客户端">
        <header className="client-setup__header">
          <div>
            <span className="client-setup__mark"><LaptopIcon /></span>
            <div>
              <p>PocketIMG {setup.app_version}</p>
              <h1>连接 Mac 客户端</h1>
            </div>
          </div>
          <button className="icon-button" type="button" aria-label="关闭 Mac 连接引导" onClick={onClose}><CloseIcon /></button>
        </header>

        <section className="client-setup__identity">
          <div>
            <span>当前飞牛用户</span>
            <strong>{userLabel}</strong>
            {setup.user.is_admin ? <small>网页管理员</small> : null}
          </div>
          <p>PocketIMG Shot 将连接到「{userLabel}」的同一图库。网页继续使用飞牛账号登录，Mac 使用独立连接凭证。</p>
        </section>

        <ol className="client-setup__steps" aria-label="Mac 客户端连接步骤">
          <li><span>1</span><div><strong>下载客户端</strong><small>从当前 NAS 获取</small></div></li>
          <li><span>2</span><div><strong>复制服务器地址</strong><small>填写到 Mac 设置</small></div></li>
          <li><span>3</span><div><strong>生成连接凭证</strong><small>绑定当前用户图库</small></div></li>
        </ol>

        {download ? (
          <section className="client-setup__section client-download">
            <div className="client-setup__section-heading">
              <div><h2><span className="client-setup__step-number">1</span>下载 PocketIMG Shot</h2><p>安装包由这台飞牛 NAS 本地提供。</p></div>
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

        <div className="client-setup__addresses client-setup__addresses--single">
          <AddressCard
            important
            step={2}
            title="填入 Mac：服务器地址"
            description="PocketIMG Shot 的“服务器地址”只填写这一项，不要填写飞牛网页管理地址。"
            value={setup.service_url}
            onCopy={() => void copyValue(setup.service_url, "Mac 服务器地址已复制")}
          />
        </div>

        <section className="client-setup__section client-token">
          <div className="client-setup__section-heading">
            <div>
              <h2><span className="client-setup__step-number">3</span>Mac 客户端连接凭证</h2>
              <p>在 PocketIMG Shot 的“连接凭证（Token）”中填写。</p>
            </div>
            <span className={`client-token__status${setup.token_configured ? " is-configured" : ""}`}>
              {setup.token_configured ? "凭证已生成" : "尚未生成"}
            </span>
          </div>

          <p className="client-token__scope">此凭证只可查看、上传和删除「{userLabel}」自己的图库，不包含飞牛登录态、密码或用户管理权限。</p>

          {token ? (
            <div className="client-token__value" role="status">
              <span>这是「{userLabel}」的 Mac 连接凭证，请立即复制；关闭窗口后不会再次显示。</span>
              <code>{token}</code>
              <button className="secondary-button client-token__copy-button" type="button" onClick={() => void copyValue(token, "Mac 连接凭证已复制")}><CopyIcon />复制连接凭证</button>
            </div>
          ) : setup.token_configured ? (
            <p className="client-token__hint">凭证明文无法再次查看。如果当时没有保存，只能重新生成；所有已连接的 Mac 都需要填写新凭证。</p>
          ) : (
            <p className="client-token__hint">飞牛网页登录不会自动生成 Mac 连接凭证。点击生成后，凭证只会在当前窗口显示一次。</p>
          )}

          <div className="client-token__actions">
            <button className="primary-button" type="button" disabled={pending !== null} onClick={() => void generateToken()}>
              <KeyIcon />
              {pending === "generate" ? "生成中…" : setup.token_configured ? "重新生成连接凭证" : "生成连接凭证"}
            </button>
            {setup.token_configured ? (
              <button className="secondary-button secondary-button--danger" type="button" disabled={pending !== null} onClick={() => void revokeToken()}>
                {pending === "revoke" ? "撤销中…" : "撤销连接凭证"}
              </button>
            ) : null}
          </div>
          {error ? <p className="form-error" role="alert">{error}</p> : null}
        </section>

        <div className="client-setup__addresses client-setup__addresses--single client-setup__web-address">
          <AddressCard
            title="网页管理地址（飞牛 SSO）"
            description="网页由飞牛账号直接登录，不使用也不会显示上面的 Mac 连接凭证。"
            value={managementURL}
            onCopy={() => void copyValue(managementURL, "网页管理地址已复制")}
          />
        </div>

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
  step?: number;
  important?: boolean;
  onCopy: () => void;
}

function AddressCard({ title, description, value, step, important = false, onCopy }: AddressCardProps) {
  return (
    <section className={`client-address${important ? " client-address--important" : ""}`}>
      <div><h2>{step ? <span className="client-setup__step-number">{step}</span> : null}{title}</h2>{important ? <span>填入客户端</span> : null}</div>
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
