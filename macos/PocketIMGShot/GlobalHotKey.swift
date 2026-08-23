import AppKit
import Carbon.HIToolbox
import Foundation

struct HotKey: Equatable {
    static let `default` = HotKey(keyCode: UInt32(kVK_F1), modifiers: 0, keyLabel: "F1")
    static let videoDefault = HotKey(keyCode: UInt32(kVK_F2), modifiers: 0, keyLabel: "F2")

    let keyCode: UInt32
    let modifiers: UInt
    let keyLabel: String

    var displayName: String {
        localizedDisplayName(language: .english)
    }

    func localizedDisplayName(language: AppLanguage) -> String {
        var value = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        let localizedKeyLabel: String
        switch keyLabel {
        case "Space": localizedKeyLabel = L10n.text("hotkey.space", language: language)
        case "Return": localizedKeyLabel = L10n.text("hotkey.return", language: language)
        case "Tab": localizedKeyLabel = L10n.text("hotkey.tab", language: language)
        case "Delete": localizedKeyLabel = L10n.text("hotkey.delete", language: language)
        case "Forward Delete": localizedKeyLabel = L10n.text("hotkey.forward_delete", language: language)
        default: localizedKeyLabel = keyLabel
        }
        return value + localizedKeyLabel
    }

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}

enum GlobalHotKeyError: LocalizedError, AppLocalizedError {
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        localizedMessage(language: .system)
    }

    func localizedMessage(language: AppLanguage) -> String {
        switch self {
        case .registrationFailed(let status):
            return L10n.format("error.hotkey_registration", language: language, status)
        }
    }
}

final class GlobalHotKey {
    static let signature: OSType = 0x5049_4853 // PIHS
    private let identifier: UInt32
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var action: (@MainActor () -> Void)?

    init(identifier: UInt32) {
        self.identifier = identifier
    }

    func register(_ hotKey: HotKey, action: @escaping @MainActor () -> Void) throws {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                var eventIdentifier = EventHotKeyID(signature: 0, id: 0)
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &eventIdentifier
                )
                guard parameterStatus == noErr,
                      owner.matches(eventIdentifier) else {
                    return OSStatus(eventNotHandledErr)
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        owner.action?()
                    }
                } else {
                    Task { @MainActor in
                        owner.action?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            unregister()
            throw GlobalHotKeyError.registrationFailed(handlerStatus)
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: self.identifier)
        let registerStatus = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw GlobalHotKeyError.registrationFailed(registerStatus)
        }
    }

    func matches(_ eventIdentifier: EventHotKeyID) -> Bool {
        eventIdentifier.signature == Self.signature && eventIdentifier.id == identifier
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKeyRef = nil
        eventHandler = nil
        action = nil
    }

    deinit {
        unregister()
    }
}
