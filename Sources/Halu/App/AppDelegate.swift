import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let services = Services.shared
    private var controller: NotchController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.start()
        controller = NotchController(services: services)
        setupStatusItem()
        setupEditMenu()
    }

    /// Halu shows no menu bar, but text fields only get ⌘C/⌘V/⌘X/⌘A/⌘Z through the main menu's key equivalents.
    private func setupEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Halu", action: nil, keyEquivalent: ""))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = HaluMark.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open Halu", action: #selector(openPanel), keyEquivalent: "").target = self

        let awake = menu.addItem(withTitle: "Keep Mac Awake", action: #selector(toggleAwake), keyEquivalent: "")
        awake.target = self
        awake.state = services.awake.isOn ? .on : .off

        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Halu", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func openPanel() { controller?.openOnPointerScreen() }

    @objc private func toggleAwake() { services.awake.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Halu: launch at login failed: \(error.localizedDescription)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
