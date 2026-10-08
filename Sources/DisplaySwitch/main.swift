import AppKit
import DisplaySwitchCore
import Darwin

let appName = "Display Switch"
let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Display Switch", isDirectory: true)
let stateURL = supportURL.appendingPathComponent("recovery.json")

func makeController(_ url: URL = stateURL) -> DisplayController {
    DisplayController(backend: NativeDisplayBackend(), store: RecoveryStore(url: url))
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
    let controller = makeController()
    let helper = RecoveryHelper()
    var statusItem: NSStatusItem!
    var refreshTimer: Timer?
    var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.DisplaySwitch")
            .filter { $0.processIdentifier != getpid() }
        if let other = others.first { other.activate(options: []); NSApp.terminate(nil); return }
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
    }

    func refreshNames() {
        guard let backend = controller.backend as? NativeDisplayBackend else { return }
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
                backend.names[id] = screen.localizedName
            }
        }
    }

    @objc func woke() { refreshNames(); rebuildMenu() }
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
            let external = live.filter { !$0.builtIn }
            if external.isEmpty && disconnected.isEmpty { add("No external displays connected", to: menu).isEnabled = false }
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
                item.toolTip = "Reconnect \(display.name)"
                item.isEnabled = controller.backend.available
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
        menu.addItem(.separator())
        add("About Display Switch", action: #selector(about), to: menu)
        add("Quit & Reconnect Displays", action: #selector(quit), to: menu, key: "q")
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
            try self.controller.disconnect(id)
        }
    }
    @objc func reconnect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UInt32 else { return }
        perform {
            if let display = try self.controller.remembered().first(where: { $0.id == id }) { try self.controller.reconnect(display) }
        }
    }
    @objc func reconnectAll() {
        perform {
            let errors = self.controller.reconnectAll()
            if !errors.isEmpty { throw DisplayError(errors.joined(separator: "\n")) }
        }
    }
    @objc func showLastError() {
        guard let lastError else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Display Switch"
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
            .applicationName: appName, .applicationVersion: "1.0",
            .credits: NSAttributedString(string: "A small, free utility for external displays.\n\nClick a checked display to disconnect it. Click it again to reconnect. Quitting reconnects displays.\n\nUses a private macOS API, which may change in future updates.")
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

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
