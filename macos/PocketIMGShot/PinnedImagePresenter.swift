import AppKit

@MainActor
final class PinnedImagePresenter: NSObject, NSWindowDelegate {
    private var windows: [PinnedImageWindow] = []

    func show(_ payload: UploadPayload, language: AppLanguage) throws {
        guard let image = NSImage(data: payload.data),
              let placementFrame = payload.placementFrame,
              placementFrame.width > 0,
              placementFrame.height > 0 else {
            throw PinnedImageError.invalidImage
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(placementFrame) })
            ?? NSScreen.main else {
            throw PinnedImageError.noScreen
        }
        let screenLocalFrame = CaptureGeometry.screenLocalFrame(
            for: placementFrame,
            on: screen.frame
        )

        let window = PinnedImageWindow(
            contentRect: screenLocalFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // The screen-specific initializer expects its origin relative to that screen.
        // setFrame uses global screen coordinates and prevents AppKit from retaining a
        // doubly-offset position on secondary displays.
        window.setFrame(placementFrame, display: false)
        DiagnosticLog.record(
            "pin window placement=\(Int(placementFrame.minX)),\(Int(placementFrame.minY)) " +
            "size=\(Int(placementFrame.width))x\(Int(placementFrame.height)) " +
            "screenOrigin=\(Int(screen.frame.minX)),\(Int(screen.frame.minY))"
        )
        let imageView = PinnedImageView(frame: CGRect(origin: .zero, size: placementFrame.size))
        imageView.image = image
        imageView.language = language
        imageView.imageScaling = .scaleAxesIndependently
        imageView.onClose = { [weak window] in window?.close() }
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.borderWidth = 1.5
        imageView.layer?.borderColor = NSColor.controlAccentColor
            .withAlphaComponent(0.82)
            .cgColor
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
        window.contentAspectRatio = placementFrame.size
        window.minSize = CGSize(width: 48, height: 48)
        windows.append(window)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(imageView)
    }

    func updateLanguage(_ language: AppLanguage) {
        for window in windows {
            (window.contentView as? PinnedImageView)?.language = language
        }
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

final class PinnedImageView: NSImageView {
    var onClose: (() -> Void)?
    var language: AppLanguage = .system

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
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
            title: L10n.text("pinned.close", language: language),
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

enum PinnedImageError: LocalizedError, AppLocalizedError {
    case invalidImage
    case noScreen

    var errorDescription: String? {
        localizedMessage(language: .system)
    }

    func localizedMessage(language: AppLanguage) -> String {
        switch self {
        case .invalidImage:
            return L10n.text("error.pinned.invalid_image", language: language)
        case .noScreen:
            return L10n.text("error.pinned.no_screen", language: language)
        }
    }
}
