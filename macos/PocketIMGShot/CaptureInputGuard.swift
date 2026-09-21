import AppKit
import CoreGraphics

// Tracks complete gestures so a mouse-up from a gesture started before capture
// still reaches its original application, and swallowed clicks never leak an up.
struct CaptureMouseInputState {
    private(set) var isPreparing = true
    private(set) var swallowedButtons: UInt64 = 0
    private var existingButtons: UInt64

    init(pressedButtons: UInt64) {
        existingButtons = pressedButtons
    }

    mutating func finish() {
        isPreparing = false
    }

    mutating func discardReleasedButtons(pressedButtons: UInt64) {
        swallowedButtons &= pressedButtons
    }

    mutating func shouldSuppress(_ type: CGEventType, button: Int64 = 0) -> Bool {
        if type == .scrollWheel { return isPreparing }
        guard (0..<32).contains(button) else { return false }
        let mask = UInt64(1) << UInt64(button)
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard isPreparing, existingButtons & mask == 0 else { return false }
            swallowedButtons |= mask
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return swallowedButtons & mask != 0
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            existingButtons &= ~mask
            let suppressed = swallowedButtons & mask != 0
            swallowedButtons &= ~mask
            return suppressed
        default:
            return false
        }
    }
}

@MainActor
final class CaptureInputGuard {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var drainTask: Task<Void, Never>?
    private var state = CaptureMouseInputState(pressedButtons: 0)
    private(set) var protectionLost = false
    private var onFailure: (() -> Void)?

    static var pressedButtons: UInt64 {
        (0..<32).reduce(UInt64(0)) { buttons, index in
            guard CGEventSource.buttonState(.hidSystemState, button: CGMouseButton(rawValue: UInt32(index))!) else {
                return buttons
            }
            return buttons | (UInt64(1) << UInt64(index))
        }
    }

    func start(onFailure: @escaping () -> Void) throws {
        let eventTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<CaptureInputGuard>.fromOpaque(userInfo).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.protectionLost = true
                        // Leave the event-tap callback before tearing down the session.
                        let failure = owner.onFailure
                        Task { @MainActor in failure?() }
                        return Unmanaged.passUnretained(event)
                    }
                    return owner.state.shouldSuppress(type, button: event.getIntegerValueField(.mouseEventButtonNumber))
                        ? nil : Unmanaged.passUnretained(event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw CaptureError.inputProtectionUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw CaptureError.inputProtectionUnavailable
        }
        self.tap = tap
        self.source = source
        self.onFailure = onFailure
        state = CaptureMouseInputState(pressedButtons: Self.pressedButtons)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        onFailure = nil
        state.finish()
        guard drainTask == nil else { return }
        if state.swallowedButtons == 0 || protectionLost {
            invalidate()
            return
        }
        // After cancel, allow new input immediately but swallow the remaining
        // drag/up of clicks whose down was blocked. Retain the tap until release.
        drainTask = Task { @MainActor in
            while !Task.isCancelled, state.swallowedButtons != 0, !protectionLost {
                try? await Task.sleep(for: .milliseconds(100))
                // Allow queued mouse-up callbacks to drain before checking for
                // releases missed when the event tap is disabled or a
                // device disconnects; read HID state, not the suppressed stream.
                state.discardReleasedButtons(pressedButtons: Self.pressedButtons)
            }
            invalidate()
            drainTask = nil
        }
    }

    private func invalidate() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
