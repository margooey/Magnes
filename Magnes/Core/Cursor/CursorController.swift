//
//  CursorController.swift
//  Magnes
//
//  Created by margooey on 10/25/25.
//

import AppKit
import ApplicationServices
import Foundation

/// High-level coordinator that drives cursor motion, overlay presentation, and input monitoring.
/// Responsibilities:
/// - Starts/stops the tick loop based on touch, glide, and animation activity.
/// - Delegates pointer motion math to `CursorMotionEngine`.
/// - Keeps `CursorView` up to date with position, mode, and press state.
final class CursorController {
    private let trackpadMonitor: TrackpadMonitor
    private let overlayManager = CursorOverlayManager()
    private let mouseButtonMonitor = MouseButtonMonitor()
    private let motionEngine: CursorMotionEngine
    private let accessibilityInspector = AccessibilityInspector()
    private let appearanceResolver = CursorAppearanceResolver()

    private var lastUpdateTimestamp: CFTimeInterval = 0
    private var wasTouchingTrackpad = false
    private let enableGlideLogging = false
    private lazy var updateLoop = CursorUpdateLoop(frequency: 500.0) { [weak self] in
        self?.handleCursorTick()
    }
    private var isUpdateLoopRunning = false
    private var isTrackpadTouchActive = false
    private var processActivity: NSObjectProtocol?

    /// Inject the shared trackpad monitor; set up callbacks so state changes feed the controller.
    init(trackpadMonitor: TrackpadMonitor) {
        self.trackpadMonitor = trackpadMonitor
        self.motionEngine = CursorMotionEngine(enableGlideLogging: enableGlideLogging)

        motionEngine.onLogMessage = { [weak self] message in
            self?.logGlide(message)
        }

        motionEngine.onGlideStateChange = { [weak self] isGliding in
            self?.handleGlideStateChange(isGliding: isGliding)
        }

        trackpadMonitor.onTouchStateChange = { [weak self] touching in
            self?.handleTrackpadTouchChange(isTouching: touching)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        updateLoop.stop()
        isUpdateLoopRunning = false
        mouseButtonMonitor.stop()
        overlayManager.tearDown()
        setProcessActivityActive(false)
    }

    /// Boot the overlay, establish bounds, and prime the state machine.
    func start() {
        trackpadMonitor.startMonitoring()
        updateDesktopBounds()
        _ = overlayManager.ensureOverlay()
        configureMouseButtonMonitoring()
        primeCursorState()
        handleCursorTick()
        isTrackpadTouchActive = trackpadMonitor.isTrackpadTouching()
        refreshUpdateLoopState()
    }

    /// Halt timers and release overlay resources.
    func stop() {
        if isUpdateLoopRunning {
            updateLoop.stop()
            isUpdateLoopRunning = false
        }
        mouseButtonMonitor.stop()
        overlayManager.tearDown()
        wasTouchingTrackpad = false
        isTrackpadTouchActive = false
        setProcessActivityActive(false)
    }

    /// Wire the button monitor so press/release events feed the pointer animation.
    private func configureMouseButtonMonitoring() {
        mouseButtonMonitor.onStateChange = { [weak self] isPressed in
            self?.updateCursorPressState(isPressed: isPressed)
        }
        mouseButtonMonitor.start()
    }

    /// Perform one simulation + render pass.
    private func handleCursorTick() {
        let cursorView = overlayManager.ensureOverlay()
        hideCursor()
        updateCursorState()
        applyCursorAppearance(on: cursorView)
        refreshUpdateLoopState()
    }

    /// Align virtual state to the current hardware cursor position.
    private func primeCursorState() {
        let currentPosition = NSEvent.mouseLocation
        motionEngine.prime(with: currentPosition)
        lastUpdateTimestamp = CFAbsoluteTimeGetCurrent()
    }

    /// Advance motion based on whether a finger is down or we are gliding.
    private func updateCursorState() {
        let now = CFAbsoluteTimeGetCurrent()
        let deltaSeconds = max(now - lastUpdateTimestamp, 1.0 / 500.0)
        lastUpdateTimestamp = now
        let deltaTime = CGFloat(deltaSeconds)

        let physicalLocation = NSEvent.mouseLocation
        let touching = trackpadMonitor.isTrackpadTouching()

        if touching {
            if !wasTouchingTrackpad {
                motionEngine.beginTouch(at: physicalLocation)
            }
            motionEngine.handleTouch(
                at: physicalLocation,
                deltaTime: deltaTime,
                normalizedTrackpadVelocity: trackpadMonitor.currentNormalizedVelocity()
            )
        } else {
            motionEngine.handleNoTouch(
                physicalLocation: physicalLocation,
                deltaTime: deltaTime,
                suppressGlide: trackpadMonitor.shouldSuppressGlideForRecentMultiTouch(),
                touchJustEnded: wasTouchingTrackpad
            )
        }

        wasTouchingTrackpad = touching
    }

    /// Choose the correct cursor art and optional fill target.
    private func applyCursorAppearance(on cursorView: CursorView) {
        let cursorType = getCurrentCursorType()
        let position = motionEngine.position
        let elementInfo = accessibilityInspector.elementInfo(at: position)

        cursorView.mousePosition = position
        cursorView.cursorMode = appearanceResolver.cursorMode(
            for: cursorType,
            elementRole: elementInfo?.role
        )
        cursorView.targetFrame = elementInfo?.frame
        cursorView.needsDisplay = true
    }

    /// Propagate pressed-state changes to the overlay view.
    private func updateCursorPressState(isPressed: Bool) {
        guard let view = overlayManager.cursorView, view.isMouseButtonDown != isPressed else { return }
        view.isMouseButtonDown = isPressed
    }

    /// Respond to finger contact changes; schedule a tick immediately so glide start/stop is evaluated.
    private func handleTrackpadTouchChange(isTouching: Bool) {
        isTrackpadTouchActive = isTouching
        if !isUpdateLoopRunning || !isTouching {
            handleCursorTick()
        }
        refreshUpdateLoopState()
    }

    /// Keep the loop alive while glide is running.
    private func handleGlideStateChange(isGliding: Bool) {
        refreshUpdateLoopState()
    }

    /// Decide whether the high-frequency loop should run.
    private func refreshUpdateLoopState() {
        let pointerAnimating = overlayManager.cursorView?.isPointerAnimating ?? false
        let shouldRun = isTrackpadTouchActive || motionEngine.isGlidingActive || pointerAnimating
        if shouldRun && !isUpdateLoopRunning {
            updateLoop.start()
            isUpdateLoopRunning = true
            setProcessActivityActive(true)
        } else if !shouldRun && isUpdateLoopRunning {
            updateLoop.stop()
            isUpdateLoopRunning = false
            setProcessActivityActive(false)
        } else if shouldRun {
            setProcessActivityActive(true)
        }
    }

    /// Update the desktop bounds cache and nudge the motion engine.
    private func updateDesktopBounds() {
        var bounds = CGRect.null
        for screen in NSScreen.screens {
            bounds = bounds.union(screen.frame)
        }
        if bounds.isNull, let mainFrame = NSScreen.main?.frame {
            bounds = mainFrame
        }
        motionEngine.updateDesktopBounds(bounds)
    }

    /// Helper for glide logging.
    private func logGlide(_ message: String) {
        guard enableGlideLogging else { return }
        print("[Magnes] Glide: \(message)")
    }

    /// Keeps macOS from idling/AppNapping while we have real cursor work in-flight.
    private func setProcessActivityActive(_ active: Bool) {
        let processInfo = ProcessInfo.processInfo
        if active {
            guard processActivity == nil else { return }
            processActivity = processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                        reason: "Custom cursor tracking in progress")
        } else if let token = processActivity {
            processInfo.endActivity(token)
            processActivity = nil
        }
    }

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        updateDesktopBounds()
    }
}
