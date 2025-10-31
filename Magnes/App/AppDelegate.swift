import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private let trackpadMonitor = TrackpadMonitor()
    private var cursorController: CursorController?
    private var isCursorControllerRunning = false
    private let preferencesWindowController = PreferencesWindowController()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        cursorController = CursorController(trackpadMonitor: trackpadMonitor)
        if cursorController != nil {
            let menuController = MenuBarController(
                startHandler: { [weak self] in
                    self?.startCursorController()
                },
                stopHandler: { [weak self] in
                    self?.stopCursorController()
                }
            )
            menuController.setPreferencesPresenter { [weak self] in
                self?.preferencesWindowController.show()
            }
            menuBarController = menuController
        }

        initializeMagnes()
        startCursorController()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        stopCursorController()
        menuBarController?.tearDown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// App setup
    private func initializeMagnes() {
        NSApp.setActivationPolicy(.accessory)
        menuBarController?.setup()
        notTodayDock()
    }

    private func startCursorController() {
        guard !isCursorControllerRunning else { return }
        cursorController?.start()
        isCursorControllerRunning = true
        menuBarController?.updateMagnesEnabledState(true)
    }

    private func stopCursorController() {
        guard isCursorControllerRunning else { return }
        cursorController?.stop()
        isCursorControllerRunning = false
        menuBarController?.updateMagnesEnabledState(false)
    }
}
