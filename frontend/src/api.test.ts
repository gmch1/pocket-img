import { beforeEach, describe, expect, test, vi } from "vitest";
import {
  absoluteImageURL,
  createSession,
  createUser,
  deleteImages,
  deleteSession,
  getClientSetup,
  listImages,
  listUsers,
  revokeClientSetupToken,
  rotateClientSetupToken,
  subscribeGalleryChanges,
  uploadImage,
} from "./api";

describe("API base URL handling", () => {
  beforeEach(() => {
    document.querySelectorAll("base").forEach((element) => element.remove());
    const base = document.createElement("base");
    base.href = "https://nas.example/app/pocket-img/";
    document.head.prepend(base);
  });

  test("resolves every fetch endpoint below document.baseURI", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, _init?: RequestInit) => {
      const url = new URL(String(input));
      const body = url.pathname.endsWith("/api/images")
        ? { images: [], account: {} }
        : url.pathname.endsWith("/api/admin/users")
          ? { users: [], user: {}, token: "created" }
          : url.pathname.endsWith("/api/client-setup/token")
            ? { token: "client-token" }
            : url.pathname.endsWith("/api/client-setup")
              ? { mode: "fnos" }
              : {};
      return jsonResponse(body);
    });
    vi.stubGlobal("fetch", fetchMock);

    await createSession("secret");
    await deleteSession();
    await listImages("7d");
    await listUsers();
    await createUser("alice");
    await deleteImages(["image-id"]);
    await getClientSetup();
    await rotateClientSetupToken();
    await revokeClientSetupToken();

    const urls = fetchMock.mock.calls.map(([input]) => new URL(String(input)));
    expect(urls.every((url) => url.origin === "https://nas.example")).toBe(true);
    expect(urls.every((url) => url.pathname.startsWith("/app/pocket-img/api/"))).toBe(true);
    expect(urls[2].searchParams.get("range")).toBe("7d");
    expect(urls[2].searchParams.get("limit")).toBe("100");
    expect(fetchMock.mock.calls[7][1]?.method).toBe("POST");
    expect(fetchMock.mock.calls[8][1]?.method).toBe("DELETE");
    for (const index of [0, 1, 4, 5, 7, 8]) {
      const headers = new Headers(fetchMock.mock.calls[index][1]?.headers);
      expect(headers.get("X-PocketIMG-Request")).toBe("1");
    }
  });

  test("resolves SSE and XHR endpoints below document.baseURI", () => {
    const sources: FakeEventSource[] = [];
    class TestEventSource extends FakeEventSource {
      constructor(url: string | URL, options?: EventSourceInit) {
        super(url, options);
        sources.push(this);
      }
    }
    vi.stubGlobal("EventSource", TestEventSource);

    const unsubscribe = subscribeGalleryChanges(() => undefined);
    expect(String(sources[0].url)).toBe("https://nas.example/app/pocket-img/api/images/events");
    expect(sources[0].options?.withCredentials).toBe(true);
    unsubscribe();
    expect(sources[0].close).toHaveBeenCalledOnce();

    const open = vi.spyOn(XMLHttpRequest.prototype, "open");
    const setRequestHeader = vi.spyOn(XMLHttpRequest.prototype, "setRequestHeader");
    vi.spyOn(XMLHttpRequest.prototype, "send").mockImplementation(() => undefined);
    void uploadImage(new File(["image"], "image.webp", { type: "image/webp" }), () => undefined);
    expect(open.mock.calls[0][0]).toBe("POST");
    expect(open.mock.calls[0][1]).toBe("https://nas.example/app/pocket-img/api/images");
    expect(setRequestHeader).toHaveBeenCalledWith("X-PocketIMG-Request", "1");
  });

  test("resolves relative public media while preserving absolute public URLs", () => {
    expect(absoluteImageURL("i/image.webp")).toBe("https://nas.example/app/pocket-img/i/image.webp");
    expect(absoluteImageURL("http://192.168.1.20:8080/i/image.webp")).toBe("http://192.168.1.20:8080/i/image.webp");
  });
});

class FakeEventSource {
  readonly url: string | URL;
  readonly options?: EventSourceInit;
  readonly addEventListener = vi.fn();
  readonly removeEventListener = vi.fn();
  readonly close = vi.fn();

  constructor(url: string | URL, options?: EventSourceInit) {
    this.url = url;
    this.options = options;
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: vi.fn(async () => body),
  } as unknown as Response;
}
