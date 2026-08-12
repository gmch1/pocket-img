import { render, screen } from "@testing-library/react";
import { describe, expect, test } from "vitest";
import { GlobalUploadProgress } from "./GlobalUploadProgress";

describe("GlobalUploadProgress", () => {
  test("is hidden without active uploads", () => {
    render(<GlobalUploadProgress tasks={[]} />);
    expect(screen.queryByRole("progressbar")).toBeNull();
  });

  test("shows aggregate upload progress", () => {
    render(<GlobalUploadProgress tasks={[
      { id: "one", state: "uploading", progress: 80 },
      { id: "two", state: "queued", progress: 0 },
    ]} />);
    const progress = screen.getByRole("progressbar", { name: "正在上传图片" });
    expect(progress.getAttribute("aria-valuenow")).toBe("40");
    expect(progress.querySelector("i")?.getAttribute("style")).toContain("40%");
  });

  test("uses an indeterminate state while processing", () => {
    render(<GlobalUploadProgress tasks={[{ id: "one", state: "processing", progress: 100 }]} />);
    const progress = screen.getByRole("progressbar", { name: "正在处理图片" });
    expect(progress.getAttribute("aria-valuenow")).toBeNull();
    expect(progress.classList.contains("global-upload-progress--indeterminate")).toBe(true);
  });
});
