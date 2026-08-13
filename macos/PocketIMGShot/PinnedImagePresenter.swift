import AppKit

@MainActor
final class PinnedImagePresenter: NSObject, NSWindowDelegate {
    private var windows: [PinnedImageWindow] = []

    func show(_ payload: UploadPayload) throws {
        guard let image = NSImage(data: payload.data),
              payload.displaySize.width > 0,
              payload.displaySize.height > 0 else {
            throw PinnedImageError.invalidImage
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            throw PinnedImageError.noScreen
        }
        let maximum = CGSize(width: visibleFrame.width * 0.78, height: visibleFrame.height * 0.78)
        let scale = min(
            1,
            maximum.width / payload.displaySize.width,
            maximum.height / payload.displaySize.height
        )
        let size = CGSize(
            width: max(48, payload.displaySize.width * scale),
            height: max(48, payload.displaySize.height * scale)
        )
        let origin = CGPoint(
            x: min(
                max(mouse.x - size.width / 2, visibleFrame.minX),
                visibleFrame.maxX - size.width
            ),
            y: min(
                max(mouse.y - size.height / 2, visibleFrame.minY),
                visibleFrame.maxY - size.height
            )
        )

        let window = PinnedImageWindow(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let imageView = PinnedImageView(frame: CGRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.onClose = { [weak window] in window?.close() }
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.black.withAlphaComponent(0.32).cgColor
        imageView.layer?.masksToBounds = true

        window.contentView = imageView
        window.delegate = self
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = payload.displaySize
        window.minSize = CGSize(width: 48, height: 48)
        windows.append(window)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(imageView)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === closing }
    }
}

private final class PinnedImageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinnedImageView: NSImageView {
    var onClose: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onClose?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window, abs(event.scrollingDeltaY) > 0.01 else { return }
        let factor = min(1.18, max(0.82, exp(event.scrollingDeltaY * 0.015)))
        let current = window.frame
        let minimumWidth: CGFloat = 48
        let maximumWidth = (window.screen?.visibleFrame.width ?? current.width) * 2
        let width = min(maximumWidth, max(minimumWidth, current.width * factor))
        let height = width * current.height / current.width
        let resized = CGRect(
            x: current.midX - width / 2,
            y: current.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(resized, display: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let closeItem = NSMenuItem(
            title: "关闭贴图",
            action: #selector(closePinnedImage),
            keyEquivalent: ""
        )
        closeItem.target = self
        menu.addItem(closeItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func closePinnedImage() {
        onClose?()
    }
}

private enum PinnedImageError: LocalizedError {
    case invalidImage
    case noScreen

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取截图图像。"
        case .noScreen:
            return "没有找到可显示贴图的屏幕。"
        }
    }
}
