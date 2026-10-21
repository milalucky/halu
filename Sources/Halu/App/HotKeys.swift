import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts through Carbon's hot keys: they work in any app and need no
/// permission. Only ⌃⌥ combinations are used, which apps rarely take.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    /// `key` is a virtual key code (kVK_ANSI_…); modifiers are Carbon flags.
    func register(key: Int, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) {
        installHandler()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x48414C55), id: id) // "HALU"
        if RegisterEventHotKey(UInt32(key), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Reads the text selected in the front app by pressing ⌘C for it, then puts the clipboard back.
/// Needs Accessibility (System Settings → Privacy & Security → Accessibility) to send the keystroke.
@MainActor
enum Selection {
    static func copySelectedText(_ done: @escaping @MainActor (String?) -> Void) {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
            done(nil)
            return
        }
        let board = NSPasteboard.general
        let before = board.changeCount
        let saved = board.string(forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                let text = board.changeCount != before ? board.string(forType: .string) : nil
                // Leave the clipboard as it was.
                if text != nil, let saved {
                    board.clearContents()
                    board.setString(saved, forType: .string)
                }
                done(text)
            }
        }
    }
}
