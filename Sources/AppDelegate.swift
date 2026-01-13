import AppKit
import os.log

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var clipboardWatcher: ClipboardWatcher!
    private var clipsWindowController: ClipsWindowController?
    private var statusItem: NSStatusItem?
    private var globalHotkeyMonitor: Any?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlowClip", category: "AppDelegate")

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Glow Clip starting up")

        setupStatusBarItem()
        setupClipboardWatcher()
        setupMainMenu()
        setupGlobalHotkey()

        // Show window on first launch
        showClipsWindow(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardWatcher.stop()
        
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        
        logger.info("Glow Clip shutting down")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showClipsWindow(nil)
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Setup

    private func setupClipboardWatcher() {
        clipboardWatcher = ClipboardWatcher()
        clipboardWatcher.start()
    }

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Glow Clip")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(statusBarItemClicked)
            button.target = self
        }

        // Build status bar menu
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Clips", action: #selector(showClipsWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Glow Clip", action: #selector(NSApplication.terminate), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Glow Clip", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Glow Clip", action: #selector(NSApplication.hide), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Glow Clip", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Show Clips", action: #selector(showClipsWindow), keyEquivalent: "1")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (standard)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    // MARK: - Actions

    @objc private func statusBarItemClicked(_ sender: Any?) {
        showClipsWindow(sender)
    }

    @objc private func showClipsWindow(_ sender: Any?) {
        if clipsWindowController == nil {
            clipsWindowController = ClipsWindowController()
            clipsWindowController?.clipboardWatcher = clipboardWatcher
        }

        clipsWindowController?.showWindow(nil)
        clipsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear Clipboard History?"
        alert.informativeText = "This will delete all non-pinned clips. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            ClipStorage.shared.clearHistory()
            logger.info("History cleared by user")
        }
    }
}
