import AppKit
import Carbon.HIToolbox

/// One system-wide shortcut, registered the way the system's own menu shortcuts are.
///
/// Carbon's hot-key API is used on purpose: it asks the window server for one specific combination,
/// so Gantry never sees any other keystroke and macOS asks for no Accessibility or Input Monitoring
/// permission. Watching for a bare double-tap of a letter would mean reading everything the user
/// types, in every app, which is a permission prompt and a keylogger's shape — not worth a shortcut.
@MainActor
final class GlobalHotKey {
    /// The default: control + option + command + G, for Gantry. Three modifiers keep it clear of the
    /// shortcuts apps and the system already use.
    static let defaultKeyCode = UInt32(kVK_ANSI_G)
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)
    /// What to show in a menu, in the order macOS writes modifiers.
    static let defaultLabel = "⌃⌥⌘G"

    /// The Carbon handle. Marked unsafe because deinit is not on any actor and has to give it back;
    /// it is only ever written on the main thread, right here.
    private nonisolated(unsafe) var reference: EventHotKeyRef?
    private let identifier: UInt32

    private nonisolated(unsafe) static var handlers: [UInt32: () -> Void] = [:]
    private nonisolated(unsafe) static var nextIdentifier: UInt32 = 1
    private nonisolated(unsafe) static var handlerInstalled = false

    /// Registers the shortcut. Returns nil when another app already holds that combination, which is
    /// the one failure worth telling the user about rather than retrying.
    init?(keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
          modifiers: UInt32 = GlobalHotKey.defaultModifiers,
          action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.handlers[identifier] = action

        var created: EventHotKeyRef?
        // "GNTR" is the four-character signature Carbon uses to tell one app's hot keys from another's.
        let hotKeyID = EventHotKeyID(signature: OSType(0x474E5452), id: identifier)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &created)
        guard status == noErr, let created else {
            Self.handlers[identifier] = nil
            return nil
        }
        reference = created
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        let identifier = identifier
        Self.handlers[identifier] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return status }
            let identifier = pressed.id
            // The Carbon handler runs on the main thread already; the hop keeps the callback's own
            // work off the event handler's stack.
            DispatchQueue.main.async { GlobalHotKey.handlers[identifier]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
