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
    private let actionableAXActions: Set<String> = ["AXPress", "AXConfirm", "AXPick", "AXShowMenu"]
    private let openSavePanelBundleID = "com.apple.appkit.xpc.openAndSavePanelService"

    private var lastUpdateTimestamp: CFTimeInterval = 0
    private var wasTouchingTrackpad = false
    private let enableGlideLogging = false
    private lazy var updateLoop = CursorUpdateLoop(frequency: 500.0) { [weak self] in
        self?.handleCursorTick()
    }
    private var isUpdateLoopRunning = false
    private var isTrackpadTouchActive = false
    private var processActivity: NSObjectProtocol?
    private var lastInteractiveTarget: AccessibilityElementInfo?
    private var lastInteractiveTargetTimestamp: CFTimeInterval = 0
    private var lastInteractiveTargetQualifiesByRole = false
    private var lastInteractiveTargetQualifiesByActionsOrURL = false
    private var lastInteractiveTargetQualifiesImplicitly = false

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
        let hasLink = elementInfo?.url != nil
        let isOpenSavePanel = (elementInfo?.bundleIdentifier == openSavePanelBundleID) ||
                              (elementInfo?.isFilePickerPanel ?? false)

        cursorView.mousePosition = position
        let resolvedMode = appearanceResolver.cursorMode(
            for: cursorType,
            elementRole: elementInfo?.role,
            elementActionNames: elementInfo?.actionNames,
            elementHasLink: hasLink,
            elementFrame: elementInfo?.frame
        )
        cursorView.cursorMode = isOpenSavePanel ? .pointer : resolvedMode
        cursorView.targetFrame = isOpenSavePanel ? nil : (elementInfo?.frame ?? lastInteractiveTarget?.frame)
        cursorView.needsDisplay = true

        // Update magnetic target for elements that should attract cursor
        updateMagneticTarget(elementInfo: elementInfo)
    }

    /// Updates the magnetic target based on the current element
    private func updateMagneticTarget(elementInfo: AccessibilityElementInfo?) {
        let now = CFAbsoluteTimeGetCurrent()
        let pointerPosition = motionEngine.position

        guard let info = elementInfo else {
            maintainLastInteractiveTarget(now: now, pointerPosition: pointerPosition)
            return
        }

        if info.bundleIdentifier == openSavePanelBundleID || info.isFilePickerPanel {
            lastInteractiveTarget = nil
            lastInteractiveTargetTimestamp = 0
            lastInteractiveTargetQualifiesByRole = false
            lastInteractiveTargetQualifiesByActionsOrURL = false
            lastInteractiveTargetQualifiesImplicitly = false
            motionEngine.updateMagneticTarget(nil)
            return
        }

        let magneticRoles: Set<String> = [
            kAXButtonRole,
            kAXDockItemRole,
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole,
            kAXCheckBoxRole,
            kAXRadioButtonRole,
            kAXPopUpButtonRole,
            kAXMenuItemRole,
            kAXMenuButtonRole,
            kAXImageRole,
            kAXGroupRole,
            kAXToolbarRole,
            "AXTab",
            "AXLink",
            "AXWebArea",
        ]

        let area = info.frame.width * info.frame.height
        let hasPressAction = info.actionNames.contains(where: actionableAXActions.contains)
        let hasLinkURL = info.url != nil
        let role = info.role

        // Debug logging - shows what roles and actions are detected
        print("[Magnes] Element role: \(role ?? "nil"), actions: \(info.actionNames), url: \(info.url?.absoluteString ?? "nil"), area: \(Int(area))")

        // Determine area ceilings per role to avoid latching to very large containers.
        let baseMaxArea: CGFloat = 15000
        var maxAreaForRole = baseMaxArea
        switch role {
        case "AXLink":
            maxAreaForRole = baseMaxArea * 2.0
        case kAXTextAreaRole:
            maxAreaForRole = baseMaxArea * 0.8
        case kAXGroupRole:
            maxAreaForRole = baseMaxArea * 0.7
        case kAXStaticTextRole:
            maxAreaForRole = baseMaxArea * 0.9
        default:
            break
        }

        let qualifiesByRole = role.map { magneticRoles.contains($0) } ?? false
        let qualifiesByActionsOrURL = hasPressAction || hasLinkURL
        let qualifiesImplicitly = (role == nil) && qualifiesByActionsOrURL && area > 100 && area <= baseMaxArea

        let isCandidate = ((qualifiesByRole || qualifiesByActionsOrURL) && area <= maxAreaForRole) || qualifiesImplicitly

        if isCandidate {
            motionEngine.updateMagneticTarget(info.frame)
            lastInteractiveTarget = info
            lastInteractiveTargetTimestamp = now
            lastInteractiveTargetQualifiesByRole = qualifiesByRole
            lastInteractiveTargetQualifiesByActionsOrURL = qualifiesByActionsOrURL
            lastInteractiveTargetQualifiesImplicitly = qualifiesImplicitly
            return
        }

        maintainLastInteractiveTarget(now: now, pointerPosition: pointerPosition)
    }

    /// Keeps the previous interactive target alive briefly to smooth out AX element flicker.
    private func maintainLastInteractiveTarget(now: CFTimeInterval, pointerPosition: CGPoint) {
        let lingerDuration: CFTimeInterval = 0.06
        guard let lastTarget = lastInteractiveTarget else {
            motionEngine.updateMagneticTarget(nil)
            return
        }

        let elapsed = now - lastInteractiveTargetTimestamp
        let expandedFrame = lastTarget.frame.insetBy(dx: -12, dy: -12)

        let stillInteractive = lastInteractiveTargetQualifiesByRole ||
            lastInteractiveTargetQualifiesByActionsOrURL ||
            lastInteractiveTargetQualifiesImplicitly

        if elapsed <= lingerDuration && expandedFrame.contains(pointerPosition) && stillInteractive {
            motionEngine.updateMagneticTarget(lastTarget.frame)
        } else {
            lastInteractiveTarget = nil
            lastInteractiveTargetTimestamp = 0
            lastInteractiveTargetQualifiesByRole = false
            lastInteractiveTargetQualifiesByActionsOrURL = false
            lastInteractiveTargetQualifiesImplicitly = false
            motionEngine.updateMagneticTarget(nil)
        }
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
