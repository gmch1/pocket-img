import { render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import type { UploadTask } from "../types";
import { UploadTray } from "./UploadTray";

function completedTask(index: number): UploadTask {
  return {
    id: `upload-${index}`,
    name: `image-${index}.png`,
    uploadedAt: `2026-08-12T0${index}:00:00+08:00`,
    progress: 100,
    state: "done",
  };
}

describe("UploadTray", () => {
  test("shows the latest five uploads with their time and no copy-all action", () => {
    const { container } = render(
      <UploadTray tasks={[1, 2, 3, 4, 5, 6].map(completedTask)} onClear={vi.fn()} />,
    );

    const names = Array.from(container.querySelectorAll(".upload-row__meta span"), (element) => element.textContent);
    expect(names).toEqual(["image-6.png", "image-5.png", "image-4.png", "image-3.png", "image-2.png"]);
    expect(container.querySelectorAll("time")).toHaveLength(5);
    expect(container.querySelector("time")?.getAttribute("datetime")).toBe("2026-08-12T06:00:00+08:00");
    expect(screen.queryByRole("button", { name: "复制全部链接" })).toBeNull();
  });
});
