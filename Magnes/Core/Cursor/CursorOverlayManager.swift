//
//  CursorOverlayManager.swift
//  Magnes
//
//  Created by margooey on 11/24/24.
//

import AppKit

/// Handles creation and teardown of the overlay window that hosts the custom cursor view and installs pointer tracking.
final class CursorOverlayManager {
    private var overlayWindow: OverlayWindow?
    private(set) var cursorView: CursorView?
    private var trackingArea: NSTrackingArea?

    /// Lazily builds (or returns) the overlay window + view stack.
    /// Steps:
    /// 1. Re-use an existing view if present, refreshing the tracking area.
    /// 2. Otherwise allocate a borderless window and attach a `CursorView`.
    /// 3. Install a full-screen tracking area so mouseMoved events keep coming in.
    @discardableResult
    func ensureOverlay() -> CursorView {
        if let existingView = cursorView {
            ensureTrackingArea(on: existingView)
            return existingView
        }

        let window = OverlayWindow()
        let view = CursorView(frame: window.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()

        overlayWindow = window
        cursorView = view
        ensureTrackingArea(on: view)
        return view
    }

    /// Removes the overlay window and tracking area so the system cursor regains control.
    func tearDown() {
        if let area = trackingArea, let view = cursorView {
            view.removeTrackingArea(area)
        }
        trackingArea = nil
        cursorView = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    /// Installs (or reattaches) a tracking area that spans all connected displays.
    /// Notes:
    /// - The tracking area attaches to the view so mouseMoved events arrive even when invisible.
    /// - We eager-union all screen frames to support multi-monitor rigs.
    /// - Reuses the previous `NSTrackingArea` instance when possible to avoid allocating duplicates.
    private func ensureTrackingArea(on view: NSView) {
        // Ensure the window forwards mouseMoved events
        view.window?.acceptsMouseMovedEvents = true

        if let area = trackingArea {
            if !view.trackingAreas.contains(area) {
                view.addTrackingArea(area)
            }
            return
        }

        /// Use the union of all screen frames to cover multi-display setups
        let fullFrame = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeAlways]
        let area = NSTrackingArea(rect: fullFrame, options: options, owner: view, userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
    }
}
