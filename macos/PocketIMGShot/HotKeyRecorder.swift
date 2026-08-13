import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey
    var onChange: (HotKey) -> Void = { _ in }
    var onRecordingChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.hotKey = hotKey
        view.onChange = { value in
            hotKey = value
            onChange(value)
        }
        view.onRecordingChanged = onRecordingChanged
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderView, context: Context) {
        nsView.hotKey = hotKey
        nsView.needsDisplay = true
    }
}

final class HotKeyRecorderView: NSView {
    var hotKey: HotKey = .default
    var onChange: ((HotKey) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var recording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 28) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !recording {
            recording = true
            onRecordingChanged?(true)
        }
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty || Self.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }
        let label = Self.keyLabel(for: event)
        guard !label.isEmpty else {
            NSSound.beep()
            return
        }
        let value = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers.rawValue, keyLabel: label)
        hotKey = value
        onChange?(value)
        stopRecording()
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 1.5 : 1
        path.stroke()

        let text = recording ? "请按新的快捷键…" : hotKey.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (self.bounds.width - size.width) / 2, y: (self.bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    private static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeyLabels[keyCode] != nil
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        onRecordingChanged?(false)
    }

    private static func keyLabel(for event: NSEvent) -> String {
        if let value = functionKeyLabels[event.keyCode] { return value }
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? ""
        }
    }

    private static let functionKeyLabels: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]
}
