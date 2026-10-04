import Carbon
import Foundation

/// Remaps the 🎤 (Dictation) key to F19 with macOS's built-in `hidutil`, so
/// Apple Dictation never sees it. The mapping lives until logout or reboot;
/// it is removed when the app quits and applied again on launch.
enum KeyRemap {
    // HID usage of the Dictation key (Consumer page 0x0C, usage 0xCF) and of F19 (Keyboard page 0x07, usage 0x6E).
    private static let dictationKey: UInt64 = 0xC0000_00CF
    private static let f19Key: UInt64 = 0x70000_006E

    static func install() {
        hidutil(#"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\#(dictationKey),"HIDKeyboardModifierMappingDst":\#(f19Key)}]}"#)
    }

    static func uninstall() {
        hidutil(#"{"UserKeyMapping":[]}"#)
    }

    private static func hidutil(_ json: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// Global F19 hotkey with press and release events through Carbon, which needs
/// no Input Monitoring permission and swallows the key so no app receives it.
final class HotKey {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() -> Bool {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                hotKey.onPress?()
            } else {
                hotKey.onRelease?()
            }
            return noErr
        }, eventTypes.count, &eventTypes, selfPtr, &handlerRef)
        guard status == noErr else { return false }

        let id = EventHotKeyID(signature: OSType(0x5048_4E44), id: 1)  // 'PHND'
        return RegisterEventHotKey(UInt32(kVK_F19), 0, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }
}
