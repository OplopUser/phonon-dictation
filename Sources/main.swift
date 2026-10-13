import AppKit
import AVFoundation
import ServiceManagement

// Phonon Dictation: hold the 🎤 key (or press it to start and again to stop),
// speak, and the text is pasted into the focused app about every 5 seconds
// and when you stop.

/// How the 🎤 key controls recording. Chosen in the menu and remembered.
enum KeyMode: String {
    case hold  // record while the key is held down
    case toggle  // press to start, press again to stop

    private static let defaultsKey = "KeyMode"

    static var saved: KeyMode {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(KeyMode.init) ?? .hold }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var readyText: String {
        switch self {
        case .hold: return "Ready: hold 🎤 to dictate"
        case .toggle: return "Ready: press 🎤 to start, again to stop"
        }
    }
}

/// A voice saying "Start" and "Stop" when recording starts and stops (made with
/// `say` by build.sh). Turned on or off in the menu, and remembered.
enum Cues {
    private static let defaultsKey = "PlaySounds"
    private static let start = sound("start")
    private static let stop = sound("stop")

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Says "Start" if sounds are on; returns how long to keep the mic muted.
    /// The mic would otherwise hear the word and Phonon would type "Start.",
    /// so it stays muted until the word ends, plus 0.2 s for speaker delay.
    static func playStart() -> Double {
        guard enabled, let start else { return 0 }
        stop?.stop()  // a "Stop" still playing from a quick re-press would be heard too
        start.stop()
        start.play()
        return start.duration + 0.2
    }

    static func playStop() {
        guard enabled, let stop else { return }
        stop.stop()
        stop.play()
    }

    private static func sound(_ name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "aiff") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = 0.6
        return sound
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let holdItem = NSMenuItem(title: "Hold 🎤 to Talk", action: #selector(chooseHold), keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Press 🎤 to Start, Press Again to Stop", action: #selector(chooseToggle), keyEquivalent: "")
    private let soundsItem = NSMenuItem(title: "Say \u{201C}Start\u{201D} and \u{201C}Stop\u{201D}", action: #selector(toggleSounds), keyEquivalent: "")

    private let server = PhononServer()
    private let hotKey = HotKey()
    private var recorder: Recorder?
    private var streamer: Streamer?
    private var mode = KeyMode.saved
    private var keyIsDown = false  // so key auto-repeat never counts as another press

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        holdItem.target = self
        toggleItem.target = self
        menu.addItem(holdItem)
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        soundsItem.target = self
        soundsItem.state = Cues.enabled ? .on : .off
        menu.addItem(soundsItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Phonon Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refreshLoginItem()
        refreshModeItems()

        KeyRemap.install()
        Paster.ensureAccessibility()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        hotKey.onPress = { [weak self] in self?.keyPressed() }
        hotKey.onRelease = { [weak self] in self?.keyReleased() }
        if !hotKey.register() {
            setStatus("Could not register the 🎤 key")
        }

        setStatus("Loading Phonon-2…")
        server.start { [weak self] ok in
            guard let self else { return }
            self.setStatus(ok ? self.mode.readyText : "Phonon server failed to start")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
        KeyRemap.uninstall()
        server.stop()
    }

    private func keyPressed() {
        guard !keyIsDown else { return }  // auto-repeat while held
        keyIsDown = true
        switch mode {
        case .hold:
            startDictation()
        case .toggle:
            if recorder == nil {
                startDictation()
            } else {
                stopDictation()
            }
        }
    }

    private func keyReleased() {
        keyIsDown = false
        if mode == .hold {
            stopDictation()
        }
    }

    private func startDictation() {
        guard recorder == nil else { return }
        guard server.isReady else {
            NSSound.beep()
            return
        }
        // Without these, recording or pasting would fail silently, so ask for
        // them right when you press the key, where you'll see the prompt.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            setStatus("Allow the microphone, then press 🎤 again")
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            setStatus("Turn on Phonon Dictation under Microphone")
            openPrivacySettings("Privacy_Microphone")
            return
        }
        if !AXIsProcessTrusted() {
            setStatus("Turn on Phonon Dictation under Accessibility")
            Paster.ensureAccessibility()  // adds the app to the list and shows the system prompt
            openPrivacySettings("Privacy_Accessibility")
            return
        }
        setStatus(mode.readyText)
        let streamer = Streamer(endpoint: server.endpoint)
        let muteSeconds = Cues.playStart()
        let recorder = Recorder(muteSeconds: muteSeconds) { samples in streamer.append(samples) }
        do {
            try recorder.start()
        } catch {
            setStatus("Mic error: \(error.localizedDescription)")
            NSSound.beep()
            return
        }
        self.streamer = streamer
        self.recorder = recorder
        setIcon(recording: true)
        if mode == .toggle {
            setStatus("Recording: press 🎤 again to stop")
        }
    }

    private func stopDictation() {
        guard let recorder else { return }
        recorder.stop()
        Cues.playStop()  // after the mic is off, so it isn't recorded
        streamer?.finish()  // pastes whatever was said since the last paste
        self.recorder = nil
        self.streamer = nil
        setIcon(recording: false)
        setStatus(mode.readyText)
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "mic.fill" : "mic"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Phonon Dictation")
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            statusItem.button?.image = image?.withSymbolConfiguration(config)
        } else {
            image?.isTemplate = true
            statusItem.button?.image = image
        }
    }

    private func openPrivacySettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLine.title = text }
    }

    @objc private func toggleSounds() {
        Cues.enabled.toggle()
        soundsItem.state = Cues.enabled ? .on : .off
    }

    @objc private func chooseHold() {
        setMode(.hold)
    }

    @objc private func chooseToggle() {
        setMode(.toggle)
    }

    private func setMode(_ newMode: KeyMode) {
        stopDictation()  // finish any recording started under the old mode
        mode = newMode
        KeyMode.saved = newMode
        refreshModeItems()
        if server.isReady {
            setStatus(newMode.readyText)
        }
    }

    private func refreshModeItems() {
        holdItem.state = mode == .hold ? .on : .off
        toggleItem.state = mode == .toggle ? .on : .off
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            setStatus("Login item error: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
