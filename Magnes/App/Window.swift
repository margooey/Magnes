//
//  OverlayWindow.swift
//  Magnes
//
//  Created by margooey on 5/27/25.
//

import AppKit

class OverlayWindow: NSWindow {
    init() {
        let screenFrame = NSScreen.main!.frame
        super.init(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        self.level = .screenSaver /// Lol? This fixes the cursor not showing up on Launchpad
        self.isOpaque = false
        self.backgroundColor = .clear
        self.ignoresMouseEvents = true
        /// Prevents the cursor view from erroneously showing up in mission control
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}
