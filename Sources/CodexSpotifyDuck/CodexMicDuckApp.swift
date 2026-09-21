import AppKit
import Foundation
import ServiceManagement

@main
private enum CodexMicDuckMain {
    static func main() {
        // Support diagnostics from the installed bundle without starting a second
        // microphone watcher or touching Spotify.
        if CommandLine.arguments.contains("--login-status") {
            print("Launch at Login: \(LaunchAtLoginManager.statusDescription)")
            return
        }
        if CommandLine.arguments.contains("--enable-login") {
            do {
                try LaunchAtLoginManager.setEnabled(true, openSettings: {})
                print("Launch at Login: \(LaunchAtLoginManager.statusDescription)")
                if !LaunchAtLoginManager.isEnabled { exit(2) }
            } catch {
                let error = error as NSError
                fputs("Launch at Login failed: \(error.localizedDescription) [\(error.domain):\(error.code)]\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--duck-volume-options") {
            print(AppConstants.duckVolumeOptions.map(String.init).joined(separator: ","))
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Preferences {
        static let enabled = "automaticDuckingEnabled"
        static let duckVolume = "duckVolume"
        static let hasRevealedStatusItem = "hasRevealedStatusItem"
    }

    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var statusText = "Starting…"
    private var statusIsError = false
    private var monitoringIssue: String?
    private var pendingRestore = false
    private lazy var menuBarImage: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "CodexMicDuckMenuBar",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 19, height: 19)
        return image
    }()

    private lazy var spotify = SpotifyController(defaults: defaults)
    private lazy var coordinator = DuckCoordinator(
        spotify: spotify,
        targetVolume: { [weak self] in self?.configuredDuckVolume ?? AppConstants.defaultDuckVolume }
    )
    private lazy var monitor = CoreAudioMonitor(onMonitoringIssue: { [weak self] issue in
        guard let self else { return }
        self.monitoringIssue = issue
        self.rebuildMenu()
    }) { [weak self] active in
        guard let self, self.isAutomaticDuckingEnabled else { return }
        self.coordinator.updateMicrophoneActivity(active)
    }

    private var isAutomaticDuckingEnabled: Bool {
        get { defaults.bool(forKey: Preferences.enabled) }
        set { defaults.set(newValue, forKey: Preferences.enabled) }
    }

    private var configuredDuckVolume: Int {
        get {
            let value = defaults.integer(forKey: Preferences.duckVolume)
            return AppConstants.duckVolumeOptions.contains(value)
                ? value
                : AppConstants.defaultDuckVolume
        }
        set {
            guard AppConstants.duckVolumeOptions.contains(newValue) else { return }
            defaults.set(newValue, forKey: Preferences.duckVolume)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Preferences.enabled: true,
            Preferences.duckVolume: AppConstants.defaultDuckVolume,
        ])

        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()

        spotify.onStatusChange = { [weak self] status in
            self?.apply(status)
        }
        coordinator.onImmediateStatus = { [weak self] message in
            self?.statusText = message
            self?.statusIsError = false
            self?.rebuildMenu()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        if isAutomaticDuckingEnabled {
            monitor.start()
        } else {
            statusText = "Automatic ducking is paused"
            spotify.recoverAfterAppOrSpotifyLaunch()
            rebuildMenu()
        }

        revealStatusItemOnFirstLaunch()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        revealStatusMenu()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        coordinator.cancelPendingRestore()
        monitor.stopSynchronously()
        spotify.prepareForTermination()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Codex MicDuck"
        rebuildMenu()
    }

    private func apply(_ status: DuckStatus) {
        pendingRestore = status.hasPendingRestore
        if !isAutomaticDuckingEnabled, !status.isError {
            statusText = status.hasPendingRestore
                ? "Automatic ducking paused — Spotify restore pending"
                : "Automatic ducking is paused"
            statusIsError = false
        } else {
            statusText = status.message
            statusIsError = status.isError
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }

        let image: NSImage?
        if statusIsError || monitoringIssue != nil {
            image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Codex MicDuck needs attention"
            )
        } else {
            image = menuBarImage ?? NSImage(
                systemSymbolName: coordinator.isMicrophoneActive
                    ? "mic.circle.fill"
                    : "mic.circle",
                accessibilityDescription: "Codex MicDuck"
            )
        }
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu(title: "Codex MicDuck")

        let status = NSMenuItem(title: monitoringIssue ?? statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let enabled = NSMenuItem(
            title: "Automatic Ducking",
            action: #selector(toggleAutomaticDucking(_:)),
            keyEquivalent: ""
        )
        enabled.target = self
        enabled.state = isAutomaticDuckingEnabled ? .on : .off
        menu.addItem(enabled)

        let volumeItem = NSMenuItem(title: "Duck Spotify To", action: nil, keyEquivalent: "")
        let volumeMenu = NSMenu(title: "Duck Spotify To")
        for volume in AppConstants.duckVolumeOptions {
            let item = NSMenuItem(
                title: "\(volume)%",
                action: #selector(selectDuckVolume(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: volume)
            item.state = volume == configuredDuckVolume ? .on : .off
            volumeMenu.addItem(item)
        }
        volumeItem.submenu = volumeMenu
        menu.addItem(volumeItem)

        menu.addItem(.separator())

        let test = NSMenuItem(
            title: "Test Spotify Duck (1.5 seconds)",
            action: #selector(testSpotifyDuck(_:)),
            keyEquivalent: ""
        )
        test.target = self
        test.isEnabled = !coordinator.isMicrophoneActive
        menu.addItem(test)

        let restore = NSMenuItem(
            title: "Restore Saved Spotify Volume",
            action: #selector(restoreSavedSpotifyVolume(_:)),
            keyEquivalent: ""
        )
        restore.target = self
        restore.isEnabled = pendingRestore || spotify.hasPendingRestore
        menu.addItem(restore)

        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: LaunchAtLoginManager.requiresApproval
                ? "Launch at Login (Approval Required)"
                : "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = LaunchAtLoginManager.isEnabled ? .on : .off
        menu.addItem(launchAtLogin)

        let automation = NSMenuItem(
            title: "Open Automation Settings…",
            action: #selector(openAutomationSettings(_:)),
            keyEquivalent: ""
        )
        automation.target = self
        menu.addItem(automation)

        let about = NSMenuItem(
            title: "About Codex MicDuck…",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Codex MicDuck",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func revealStatusItemOnFirstLaunch() {
        guard !defaults.bool(forKey: Preferences.hasRevealedStatusItem) else { return }
        defaults.set(true, forKey: Preferences.hasRevealedStatusItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.revealStatusMenu()
        }
    }

    private func revealStatusMenu() {
        statusItem.button?.performClick(nil)
    }

    @objc private func toggleAutomaticDucking(_ sender: Any?) {
        isAutomaticDuckingEnabled.toggle()
        if isAutomaticDuckingEnabled {
            statusText = "Starting microphone watcher…"
            statusIsError = false
            monitor.start()
        } else {
            monitor.stop()
            monitoringIssue = nil
            coordinator.stopAndRestore()
            statusText = "Automatic ducking is paused"
            statusIsError = false
        }
        rebuildMenu()
    }

    @objc private func selectDuckVolume(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        configuredDuckVolume = value.intValue
        rebuildMenu()
    }

    @objc private func testSpotifyDuck(_ sender: Any?) {
        guard !coordinator.isMicrophoneActive else {
            showAlert(
                title: "Codex microphone is active",
                message: "Finish the current recording before testing Spotify control."
            )
            return
        }

        statusText = "Testing Spotify control…"
        statusIsError = false
        rebuildMenu()
        spotify.runTest(targetVolume: configuredDuckVolume) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let outcome):
                self.showAlert(
                    title: "Spotify test complete",
                    message: outcome.message
                )
            case let .failure(error):
                self.showAlert(title: "Spotify test failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func restoreSavedSpotifyVolume(_ sender: Any?) {
        spotify.restoreSavedVolumeForcefully { [weak self] result in
            guard case let .failure(error) = result else { return }
            self?.showAlert(title: "Could not restore Spotify", message: error.localizedDescription)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            try LaunchAtLoginManager.setEnabled(!LaunchAtLoginManager.isEnabled)
            rebuildMenu()
        } catch {
            showAlert(title: "Launch at Login failed", message: error.localizedDescription)
        }
    }

    @objc private func openAutomationSettings(_ sender: Any?) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        showAlert(
            title: "Codex MicDuck",
            message: "Automatically lowers only Spotify while Codex is using the microphone, then safely restores the previous Spotify volume.\n\nCodex MicDuck observes microphone state; it never records or accesses microphone audio."
        )
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func workspaceApplicationDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              app.bundleIdentifier == AppConstants.spotifyBundleIdentifier
        else { return }
        coordinator.spotifyDidLaunch()
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
