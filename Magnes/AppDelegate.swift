//
//  AppDelegate.swift
//  Magnes
//
//  Created by margooey on 6/3/25.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarItem: NSStatusItem?
    private let trackpadMonitor = TrackpadMonitor()
    private var cursorController: CursorController?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initializeMagnes()
        cursorController = CursorController(trackpadMonitor: trackpadMonitor)
        cursorController?.start()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        cursorController?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// App setup
    private func initializeMagnes() {
        NSApp.setActivationPolicy(.accessory)
        initializeStatusBar()
        notTodayDock()
    }

    private func initializeStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        let quitMenuItem = NSMenuItem()
        quitMenuItem.title = "Quit"
        quitMenuItem.action = #selector(quit(_:))
        menu.addItem(quitMenuItem)

        statusBarItem?.menu = menu
        statusBarItem?.button?.image = NSImage(named: NSImage.Name("cursorOutline"))
        statusBarItem?.button?.image?.size = NSSize(width: 18, height: 18)
    }

    @objc private func quit(_ sender: Any) {
        _ = exit(0)
    }
}
