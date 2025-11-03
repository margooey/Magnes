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
    private var statusBarController: StatusBarController?

    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initializeMagnes()
        statusBarController = StatusBarController()
        //statusBarController?.controlWindowController = controlWindowController
        statusBarController?.setup()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        statusBarController?.tearDown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// App setup
    private func initializeMagnes() {
        NSApp.setActivationPolicy(.accessory)
        notTodayDock()
    }

    @objc private func quit(_ sender: Any) {
        _ = exit(0)
    }
}
