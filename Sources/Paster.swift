import AppKit
import Carbon

/// Pastes text into the focused app with ⌘V, then puts your clipboard back.
enum Paster {
    static func ensureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Call off the main thread; blocks until the clipboard is restored so pastes stay in order.
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        var saved: [NSPasteboardItem] = []
        var ourChange = 0

        DispatchQueue.main.sync {
            saved = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            // Tells clipboard history tools to ignore this temporary entry.
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            ourChange = pasteboard.changeCount

            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }

        Thread.sleep(forTimeInterval: 0.3)  // let the target app read the clipboard

        DispatchQueue.main.sync {
            guard pasteboard.changeCount == ourChange else { return }  // you copied something meanwhile
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}
