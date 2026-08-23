import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { revokeClientSetupToken, rotateClientSetupToken } from "../api";
import { copyText } from "../clipboard";
import type { ClientSetup } from "../types";
import { ClientSetupGuide } from "./ClientSetupGuide";

vi.mock("../api", () => ({
  revokeClientSetupToken: vi.fn(),
  rotateClientSetupToken: vi.fn(),
}));

vi.mock("../clipboard", () => ({ copyText: vi.fn() }));

const setup: ClientSetup = {
  mode: "fnos",
  app_version: "0.5.0",
  management_url: "https://nas.example/app/pocket-img/",
  service_url: "http://192.168.1.20:8080",
  token_configured: false,
  user: {
    space_id: "fnos-user-1000",
    display_name: "Alice",
    is_admin: false,
  },
  download: {
    url: "downloads/PocketIMGShot-0.5.0-macos-arm64.zip",
    filename: "PocketIMGShot-0.5.0-macos-arm64.zip",
    version: "0.5.0",
    sha256: "b".repeat(64),
    architecture: "arm64",
    minimum_macos: "14",
    size_bytes: 8 * 1024 * 1024,
  },
};

describe("ClientSetupGuide", () => {
  beforeEach(() => {
    vi.mocked(rotateClientSetupToken).mockReset();
    vi.mocked(revokeClientSetupToken).mockReset();
    vi.mocked(copyText).mockReset();
    vi.mocked(copyText).mockResolvedValue();
    vi.spyOn(window, "confirm").mockReturnValue(true);
  });

  test("binds a one-time Mac connection credential to the current FNOS gallery", async () => {
    vi.mocked(rotateClientSetupToken).mockResolvedValue("client-secret-token");
    vi.mocked(revokeClientSetupToken).mockResolvedValue();
    const notify = vi.fn();

    render(<Harness onNotify={notify} />);
    expect(screen.getByText("PocketIMG Shot 将连接到「Alice」的同一图库。网页继续使用飞牛账号登录，Mac 使用独立连接凭证。")).toBeTruthy();
    expect(screen.getByText("此凭证只可查看、上传和删除「Alice」自己的图库，不包含飞牛登录态、密码或用户管理权限。")).toBeTruthy();
    expect(screen.getByText("飞牛网页登录不会自动生成 Mac 连接凭证。点击生成后，凭证只会在当前窗口显示一次。")).toBeTruthy();
    expect(rotateClientSetupToken).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "生成连接凭证" }));

    expect(await screen.findByText("client-secret-token")).toBeTruthy();
    expect(screen.getByText("这是「Alice」的 Mac 连接凭证，请立即复制；关闭窗口后不会再次显示。")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "复制连接凭证" }));
    await waitFor(() => expect(copyText).toHaveBeenCalledWith("client-secret-token"));

    fireEvent.click(screen.getByRole("button", { name: "关闭 Mac 连接引导" }));
    fireEvent.click(screen.getByRole("button", { name: "重新打开客户端设置" }));
    expect(screen.queryByText("client-secret-token")).toBeNull();
    expect(screen.getByText("凭证明文无法再次查看。如果当时没有保存，只能重新生成；所有已连接的 Mac 都需要填写新凭证。")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "撤销连接凭证" }));
    await waitFor(() => expect(revokeClientSetupToken).toHaveBeenCalledOnce());
    expect(screen.getByText("尚未生成")).toBeTruthy();
    expect(screen.getByRole("button", { name: "生成连接凭证" })).toBeTruthy();
    expect(notify).toHaveBeenCalledWith("Mac 连接凭证已撤销");
  });

  test("keeps FNOS web administration separate and warns before replacing a credential", async () => {
    vi.mocked(rotateClientSetupToken).mockResolvedValue("replacement-token");

    render(
      <ClientSetupGuide
        setup={{ ...setup, token_configured: true, user: { ...setup.user, is_admin: true } }}
        onClose={() => undefined}
        onTokenConfigured={() => undefined}
        onSessionExpired={() => undefined}
        onNotify={() => undefined}
      />,
    );
    expect(screen.getByText("网页管理员")).toBeTruthy();
    expect(screen.getByText(/不包含飞牛登录态、密码或用户管理权限/)).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "重新生成连接凭证" }));

    await waitFor(() => expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining("所有已连接的 Mac")));
    expect(await screen.findByText("replacement-token")).toBeTruthy();
  });

  test("does not rotate an existing credential when the user cancels", () => {
    vi.mocked(window.confirm).mockReturnValue(false);

    render(
      <ClientSetupGuide
        setup={{ ...setup, token_configured: true }}
        onClose={() => undefined}
        onTokenConfigured={() => undefined}
        onSessionExpired={() => undefined}
        onNotify={() => undefined}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "重新生成连接凭证" }));

    expect(rotateClientSetupToken).not.toHaveBeenCalled();
  });
});

function Harness({ onNotify }: { onNotify: (message: string, error?: boolean) => void }) {
  const [open, setOpen] = useState(true);
  const [configured, setConfigured] = useState(false);
  if (!open) return <button type="button" onClick={() => setOpen(true)}>重新打开客户端设置</button>;
  return (
    <ClientSetupGuide
      setup={{ ...setup, token_configured: configured }}
      onClose={() => setOpen(false)}
      onTokenConfigured={setConfigured}
      onSessionExpired={() => undefined}
      onNotify={onNotify}
    />
  );
}
