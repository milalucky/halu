import AppKit
import Carbon.HIToolbox
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let services = Services.shared
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.start()
        services.openWindow = { [weak self] in self?.showWindow() }
        services.collapsePanel = { [weak self] in self?.controller?.collapseAll() }
        controller = NotchController(services: services)
        setupStatusItem()
        setupHotKeys()
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
        let app = NSMenu(title: "Halu")
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let appItem = NSMenuItem(title: "Halu", action: nil, keyEquivalent: "")
        appItem.submenu = app
        main.addItem(appItem)
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
        menu.addItem(withTitle: "Open in a Window", action: #selector(openWindowItem), keyEquivalent: "").target = self

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

    @objc private func openWindowItem() { showWindow() }

    /// ⌃⌥Space opens Halu; ⌃⌥T translates the text selected in any app.
    private func setupHotKeys() {
        HotKeys.shared.register(key: kVK_Space) { [weak self] in self?.controller?.openOnPointerScreen() }
        HotKeys.shared.register(key: kVK_ANSI_T) { [weak self] in
            Selection.copySelectedText { text in
                guard let self else { return }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.services.translate.input = text
                }
                self.controller?.openOnPointerScreen(tab: .translate)
            }
        }
    }

    /// Halu as an ordinary window, for working in a tab for longer: it doesn't hide when the pointer leaves.
    private func showWindow() {
        controller?.collapseAll()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Halu"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.minSize = NSSize(width: 720, height: 460)
            window.contentView = NSHostingView(rootView: WindowRootView(model: services.model, services: services))
            window.center()
            window.setFrameAutosaveName("HaluWindow")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

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
