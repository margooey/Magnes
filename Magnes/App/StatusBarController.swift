import Cocoa

final class StatusBarController {
    private enum Constants {
        static let statusBarIconName = NSImage.Name("cursorOutlineCentered")
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let cursorController = CursorController.shared
    private let preferencesWindowController = PreferencesWindowController()
    private lazy var controlPanelMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Control Panel…", action: #selector(showControlPanel(_:)), keyEquivalent: "")
        item.target = self
        return item
    }()
    private var stateObserver: NSObjectProtocol?

    func setup() {
        statusItem.isVisible = true
        guard let button = statusItem.button else {
            NSLog("StatusBarController: status item button unavailable; status bar item not shown")
            return
        }
        if let image = NSImage(named: Constants.statusBarIconName) ?? NSImage(systemSymbolName: "triangleshape", accessibilityDescription: nil) {
            button.image = image
            button.image?.size = NSSize(width: 18, height: 18)
        } else {
            button.title = "🧲"
        }

        statusItem.menu = buildMenu()
        NSLog("StatusBarController: status item installed")
    }

    func tearDown() {
        cursorController.stop()
        if let observer = stateObserver {
            NotificationCenter.default.removeObserver(observer)
            stateObserver = nil
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func showPreferences(_ sender: Any?) {
        preferencesWindowController.show()
    }

    @objc private func showControlPanel(_ sender: Any?) {
        // controlWindowController?.show()
    }

    @objc private func quitApplication(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(NSMenuItem.separator())

        menu.addItem(controlPanelMenuItem)

        menu.addItem(NSMenuItem.separator())

        let preferencesItem = NSMenuItem(title: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Magnes", action: #selector(quitApplication(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }
}

