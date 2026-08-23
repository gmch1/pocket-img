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

  test("keeps a generated Token only in the mounted guide and supports revocation", async () => {
    vi.mocked(rotateClientSetupToken).mockResolvedValue("client-secret-token");
    vi.mocked(revokeClientSetupToken).mockResolvedValue();
    const notify = vi.fn();

    render(<Harness onNotify={notify} />);
    fireEvent.click(screen.getByRole("button", { name: "生成 Token" }));

    expect(await screen.findByText("client-secret-token")).toBeTruthy();
    expect(screen.getByText("请立即复制，关闭此窗口后不会再次显示")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "复制客户端 Token" }));
    await waitFor(() => expect(copyText).toHaveBeenCalledWith("client-secret-token"));

    fireEvent.click(screen.getByRole("button", { name: "关闭客户端设置" }));
    fireEvent.click(screen.getByRole("button", { name: "重新打开客户端设置" }));
    expect(screen.queryByText("client-secret-token")).toBeNull();
    expect(screen.getByText("现有 Token 无法再次查看。需要配置新客户端时，请重新生成。")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "撤销 Token" }));
    await waitFor(() => expect(revokeClientSetupToken).toHaveBeenCalledOnce());
    expect(screen.getByText("未配置")).toBeTruthy();
    expect(screen.getByRole("button", { name: "生成 Token" })).toBeTruthy();
    expect(notify).toHaveBeenCalledWith("客户端 Token 已撤销");
  });

  test("warns before replacing an existing Token", async () => {
    vi.mocked(rotateClientSetupToken).mockResolvedValue("replacement-token");

    render(
      <ClientSetupGuide
        setup={{ ...setup, token_configured: true }}
        onClose={() => undefined}
        onTokenConfigured={() => undefined}
        onSessionExpired={() => undefined}
        onNotify={() => undefined}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: "重新生成 Token" }));

    await waitFor(() => expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining("立即撤销旧 Token")));
    expect(await screen.findByText("replacement-token")).toBeTruthy();
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
