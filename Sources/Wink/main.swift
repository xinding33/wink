import AppKit
import WinkCore
import Darwin

let appName = "Wink"
let bundleID = "io.github.xinding33.wink"
// Builds before the move to a Developer ID bundle ID kept the Display Switch identifiers.
let legacyBundleID = "local.DisplaySwitch"
let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let legacySupportURL = applicationSupport.appendingPathComponent("Display Switch", isDirectory: true)
let supportURL = applicationSupport.appendingPathComponent("Wink", isDirectory: true)
let stateURL = supportURL.appendingPathComponent("recovery.json")
let preferencesURL = supportURL.appendingPathComponent("remembered.json")

func makeController(_ url: URL = stateURL, preferences: PreferenceStore? = nil) -> DisplayController {
    DisplayController(backend: NativeDisplayBackend(), store: RecoveryStore(url: url), preferences: preferences)
}

let agentLabel = bundleID
let agentURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

/// For Homebrew installs, use the version-independent opt/ path so Open at Login survives upgrades.
func stableExecutablePath() -> String {
    Bundle.main.bundlePath.replacingOccurrences(of: #"/Cellar/wink/[^/]+/"#, with: "/opt/wink/", options: .regularExpression)
        + "/Contents/MacOS/Wink"
}

/// Open at Login is a LaunchAgent. It is not kept alive, so a crash leaves displays reconnected.
var opensAtLogin: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

func writeLaunchAgent() throws {
    let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": [stableExecutablePath()],
                                "RunAtLoad": true, "ProcessType": "Interactive"]
    try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL)
}

func report(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

final class RecoveryHelper {
    private var process: Process?
    var running: Bool { process?.isRunning == true }
    func start(store: RecoveryStore) throws {
        guard !running else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--watchdog", String(getpid()), store.url.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
    }
    func stop() { if running { process?.terminate() }; process = nil }
}

// The helper survives an app crash and only reconnects displays this app recorded.
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--watchdog" {
    let parent = pid_t(CommandLine.arguments[2]) ?? 0
    let controller = makeController(URL(fileURLWithPath: CommandLine.arguments[3]))
    while parent > 1 && getppid() == parent && kill(parent, 0) == 0 {
        if let displays = try? controller.backend.displays(), !displays.contains(where: { $0.active }) {
            _ = controller.reconnectAll()
        }
        Thread.sleep(forTimeInterval: 1)
    }
    for _ in 0..<3 {
        if controller.reconnectAll().isEmpty { break }
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") {
    let backend = NativeDisplayBackend()
    for screen in NSScreen.screens {
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 { backend.names[id] = screen.localizedName }
    }
    print("Display disconnect API: \(backend.available ? "available" : "unavailable")")
    do {
        let data = try JSONEncoder().encode(backend.displays())
        print(String(decoding: data, as: UTF8.self))
        exit(backend.available ? 0 : 1)
    } catch { report(error.localizedDescription); exit(1) }
}

// Integration check uses the same controller, with a separate recovery ledger.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--test-cycle" {
    guard let id = UInt32(CommandLine.arguments[2]) else { exit(2) }
    let storeURL = supportURL.appendingPathComponent("test-recovery.json")
    let controller = makeController(storeURL)
    let helper = RecoveryHelper()
    do {
        let previous = controller.reconnectAll()
        guard previous.isEmpty else { throw DisplayError(previous.joined(separator: "\n")) }
        let before = try controller.backend.displays()
        try helper.start(store: controller.store)
        try controller.disconnect(id)
        print("PASS: display \(id) disappeared from the online display list.")
        Thread.sleep(forTimeInterval: 2)
        let failures = controller.reconnectAll()
        guard failures.isEmpty else { throw DisplayError(failures.joined(separator: "\n")) }
        let after = try controller.backend.displays()
        guard Set(before.map(\.uuid)) == Set(after.map(\.uuid)) else { throw DisplayError("Display topology did not recover.") }
        print("PASS: every original display is online again.")
        helper.stop(); exit(0)
    } catch {
        _ = controller.reconnectAll()
        report(error.localizedDescription)
        // Let the helper perform its final recovery attempt after this process exits.
        exit(1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = makeController(preferences: PreferenceStore(url: preferencesURL))
    let helper = RecoveryHelper()
    var statusItem: NSStatusItem!
    var refreshTimer: Timer?
    var lastError: String?
    // Holding Option at launch leaves remembered displays on for this session.
    let pausePreferences = NSEvent.modifierFlags.contains(.option)
    // Displays that failed to turn off automatically are not retried until the user turns them off again.
    var gaveUp: Set<String> = []
    var pendingApply: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? bundleID)
            .filter { $0.processIdentifier != getpid() }
        if let other = others.first { other.activate(options: []); NSApp.terminate(nil); return }
        migrateFromLegacyBuild()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: appName)
        statusItem.button?.toolTip = appName
        let errors = controller.reconnectAll()
        if !errors.isEmpty { lastError = errors.joined(separator: "\n") }
        do { try helper.start(store: controller.store) } catch { lastError = error.localizedDescription }
        refreshNames()
        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.monitor() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Give displays time to come online after login before turning remembered ones off.
        scheduleApply(after: 2)
    }

    /// Quits a running pre-rename build, which reconnects its displays, before taking over its state.
    func migrateFromLegacyBuild() {
        let legacy = { NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).filter { !$0.isTerminated } }
        legacy().forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while !legacy().isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        do { try StateMigration.migrate(from: legacySupportURL, to: supportURL) } catch { lastError = error.localizedDescription }
    }

    func scheduleApply(after delay: TimeInterval) {
        guard !pausePreferences else { return }
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPreferences() }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func applyPreferences() {
        guard helper.running else { scheduleApply(after: 2); return }
        refreshNames()
        let failures = controller.applyPreferences(skipping: gaveUp)
        if !failures.isEmpty {
            gaveUp.formUnion(failures.keys)
            lastError = failures.values.sorted().joined(separator: "\n")
        }
        rebuildMenu()
    }

    @objc func screensChanged() { scheduleApply(after: 1.5) }

    func refreshNames() {
        guard let backend = controller.backend as? NativeDisplayBackend else { return }
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
                backend.names[id] = screen.localizedName
            }
        }
    }

    @objc func woke() { refreshNames(); rebuildMenu(); scheduleApply(after: 2) }
    func menuWillOpen(_ menu: NSMenu) { refreshNames(); rebuildMenu(menu) }

    func monitor() {
        if !helper.running {
            let errors = controller.reconnectAll()
            do { try helper.start(store: controller.store) } catch { lastError = error.localizedDescription }
            if !errors.isEmpty { lastError = errors.joined(separator: "\n") }
        }
        // If the remaining screen is unplugged, recover disconnected screens.
        if let live = try? controller.backend.displays(), !live.contains(where: { $0.active }) {
            let errors = controller.reconnectAll()
            if !errors.isEmpty { lastError = errors.joined(separator: "\n") }
        }
        let off = (try? controller.remembered().count) ?? 0
        statusItem.button?.toolTip = off == 0 ? appName : "\(appName) · \(off) display(s) disconnected"
    }

    @discardableResult
    func add(_ title: String, action: Selector? = nil, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    func rebuildMenu(_ existing: NSMenu? = nil) {
        let menu = existing ?? NSMenu()
        menu.autoenablesItems = false
        menu.removeAllItems()
        let heading = add(appName, to: menu)
        heading.isEnabled = false
        add("Click a display to turn it off or on", to: menu).isEnabled = false
        menu.addItem(.separator())
        do {
            let live = try controller.backend.displays()
            let saved = try controller.remembered()
            let disconnected = saved.filter { old in !live.contains(where: { $0.uuid == old.uuid }) }
            let absent = try (controller.preferences?.load() ?? []).filter { wanted in
                !live.contains(where: { $0.uuid == wanted.uuid }) && !disconnected.contains(where: { $0.uuid == wanted.uuid })
            }
            let external = live.filter { !$0.builtIn }
            if external.isEmpty && disconnected.isEmpty && absent.isEmpty { add("No external displays connected", to: menu).isEnabled = false }
            for display in external.sorted(by: { $0.id < $1.id }) {
                let item = add(display.name, action: #selector(toggle(_:)), to: menu)
                item.state = .on
                item.representedObject = display.id
                let reason = DisplayPolicy.reasonToKeepOn(display, among: live)
                item.isEnabled = reason == nil && controller.backend.available && helper.running
                item.toolTip = reason ?? "Turn off \(display.name)"
                if reason != nil { item.title += " — stays on" }
            }
            for display in disconnected {
                let item = add(display.name + " — off", action: #selector(reconnect(_:)), to: menu)
                item.representedObject = display.id
                item.toolTip = "Reconnect \(display.name). Until you do, Wink turns it off whenever it connects."
                item.isEnabled = controller.backend.available
            }
            for wanted in absent {
                let item = add(wanted.name + " — off when connected", action: #selector(forget(_:)), to: menu)
                item.representedObject = wanted.uuid
                item.toolTip = "Click to stop turning off \(wanted.name) when it connects"
            }
            if pausePreferences && !(try controller.preferences?.load() ?? []).isEmpty {
                add("Remembered displays paused (Option held at launch)", to: menu).isEnabled = false
            }
            if live.contains(where: { $0.builtIn }) {
                add("Built-in display stays on", to: menu).isEnabled = false
            }
            menu.addItem(.separator())
            add("Reconnect All", action: #selector(reconnectAll), to: menu, key: "r").isEnabled = !saved.isEmpty
        } catch { lastError = error.localizedDescription }
        if !controller.backend.available {
            add("Display control unavailable on this macOS", to: menu).isEnabled = false
        }
        if lastError != nil { add("View Last Error…", action: #selector(showLastError), to: menu) }
        add("Display Settings…", action: #selector(openSettings), to: menu)
        add("Open at Login", action: #selector(toggleLoginItem), to: menu).state = opensAtLogin ? .on : .off
        menu.addItem(.separator())
        add("About Wink", action: #selector(about), to: menu)
        add("Quit & Reconnect Displays", action: #selector(quit), to: menu, key: "q").toolTip =
            "Displays turn back on until Wink launches again. Reconnect a display to stop keeping it off."
        menu.delegate = self
        if existing == nil { statusItem.menu = menu }
    }

    func perform(_ operation: @escaping () throws -> Void) {
        // Allow the menu to close before macOS rearranges screens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            do { try operation(); self.lastError = nil }
            catch { self.lastError = error.localizedDescription; self.showLastError() }
            self.refreshNames(); self.rebuildMenu()
        }
    }

    @objc func toggle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UInt32 else { return }
        perform {
            guard self.helper.running else { throw DisplayError("The recovery helper is restarting. Please try again.") }
            if let uuid = try self.controller.backend.displays().first(where: { $0.id == id })?.uuid { self.gaveUp.remove(uuid) }
            try self.controller.disconnect(id)
        }
    }
    @objc func reconnect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UInt32 else { return }
        perform {
            if let display = try self.controller.remembered().first(where: { $0.id == id }) { try self.controller.turnOn(display) }
        }
    }
    @objc func reconnectAll() {
        perform {
            var errors: [String] = []
            for display in try self.controller.remembered() {
                do { try self.controller.turnOn(display) } catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty { throw DisplayError(errors.joined(separator: "\n")) }
        }
    }
    @objc func forget(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        perform { try self.controller.preferences?.forget(uuid) }
    }
    @objc func toggleLoginItem() {
        perform { if opensAtLogin { try FileManager.default.removeItem(at: agentURL) } else { try writeLaunchAgent() } }
    }
    @objc func showLastError() {
        guard let lastError else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Wink"
        alert.informativeText = lastError
        alert.alertStyle = .warning
        alert.runModal()
    }
    @objc func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .credits: NSAttributedString(string: "A small, free utility for external displays.\n\nClick a checked display to disconnect it. Click it again to reconnect. Disconnected displays stay off whenever Wink is running, including after a restart with Open at Login. Quitting reconnects displays until the next launch.\n\nUses a private macOS API, which may change in future updates.")
        ])
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard statusItem != nil else { return .terminateNow }
        let errors = controller.reconnectAll()
        if !errors.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Some displays could not reconnect"
            alert.informativeText = errors.joined(separator: "\n") + "\n\nTheir recovery information will be kept for the next launch."
            alert.addButton(withTitle: "Stay Open")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        } else { helper.stop() }
        return .terminateNow
    }
}

// Keep the login item pointing at this copy if the app has moved.
if opensAtLogin { try? writeLaunchAgent() }

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
