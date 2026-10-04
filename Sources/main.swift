import AppKit
import AVFoundation
import ServiceManagement

// Phonon Dictation: hold the 🎤 key, speak, and the text is pasted into the
// focused app about every 5 seconds and when you let go.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private let server = PhononServer()
    private let hotKey = HotKey()
    private var recorder: Recorder?
    private var streamer: Streamer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Phonon Dictation", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refreshLoginItem()

        KeyRemap.install()
        Paster.ensureAccessibility()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        hotKey.onPress = { [weak self] in self?.startDictation() }
        hotKey.onRelease = { [weak self] in self?.stopDictation() }
        if !hotKey.register() {
            setStatus("Could not register the 🎤 key")
        }

        setStatus("Loading Phonon-2…")
        server.start { [weak self] ok in
            self?.setStatus(ok ? "Ready: hold 🎤 to dictate" : "Phonon server failed to start")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
        KeyRemap.uninstall()
        server.stop()
    }

    private func startDictation() {
        guard recorder == nil else { return }  // ignore key auto-repeat
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
            setStatus("Allow the microphone, then hold 🎤 again")
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
        setStatus("Ready: hold 🎤 to dictate")
        let streamer = Streamer(endpoint: server.endpoint)
        let recorder = Recorder { samples in streamer.append(samples) }
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
    }

    private func stopDictation() {
        guard let recorder else { return }
        recorder.stop()
        streamer?.finish()  // pastes whatever was said since the last paste
        self.recorder = nil
        self.streamer = nil
        setIcon(recording: false)
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
