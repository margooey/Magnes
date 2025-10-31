import AppKit

/// Manages the menu bar status item and related menu actions.
final class MenuBarController {
    private enum Constants {
        static let statusBarIconName = NSImage.Name("cursorOutline")
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let startHandler: () -> Void
    private let stopHandler: () -> Void
    private var isMagnesEnabled = false

    private lazy var toggleMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Enable Magnes", action: #selector(toggleCursorControl(_:)), keyEquivalent: "")
        item.target = self
        return item
    }()

    private lazy var preferencesMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Preferences…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        item.target = self
        item.isEnabled = preferencesPresenter != nil
        return item
    }()

    private lazy var quitMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Quit Magnes", action: #selector(quitApplication(_:)), keyEquivalent: "q")
        item.target = self
        return item
    }()

    private var preferencesPresenter: (() -> Void)?

    init(startHandler: @escaping () -> Void, stopHandler: @escaping () -> Void) {
        self.startHandler = startHandler
        self.stopHandler = stopHandler
    }

    func setup() {
        statusItem.isVisible = true
        configureStatusItemAppearance()
        statusItem.menu = buildMenu()
        syncToggleState()
    }

    func tearDown() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func updateMagnesEnabledState(_ isEnabled: Bool) {
        guard isMagnesEnabled != isEnabled else { return }
        isMagnesEnabled = isEnabled
        syncToggleState()
    }

    func setPreferencesPresenter(_ presenter: @escaping () -> Void) {
        preferencesPresenter = presenter
        preferencesMenuItem.isEnabled = true
    }

    @objc private func toggleCursorControl(_ sender: Any?) {
        if isMagnesEnabled {
            stopHandler()
            updateMagnesEnabledState(false)
        } else {
            startHandler()
            updateMagnesEnabledState(true)
        }
    }

    @objc private func showPreferences(_ sender: Any?) {
        preferencesPresenter?()
    }

    @objc private func quitApplication(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(toggleMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(preferencesMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitMenuItem)
        return menu
    }

    private func configureStatusItemAppearance() {
        guard let button = statusItem.button else {
            NSLog("MenuBarController: Failed to acquire status item button")
            return
        }
        if let image = NSImage(named: Constants.statusBarIconName) {
            button.image = image
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 18, height: 18)
        } else {
            button.title = "◎"
        }
    }

    private func syncToggleState() {
        toggleMenuItem.state = isMagnesEnabled ? .on : .off
        toggleMenuItem.title = isMagnesEnabled ? "Disable Magnes" : "Enable Magnes"
    }
}
