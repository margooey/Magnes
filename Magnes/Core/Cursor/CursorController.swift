//
//  CursorController.swift
//  Magnes
//
//  Created by margooey on 10/25/25.
//

import AppKit
import ApplicationServices
import CoreGraphics
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
    private let windowInspector = WindowInspector()
    private let appearanceResolver = CursorAppearanceResolver()
    private let actionableAXActions: Set<String> = ["AXPress", "AXConfirm", "AXPick", "AXShowMenu"]
    private let ignoredMagneticAXActions: Set<String> = ["AXScrollToVisible"]
    private let magneticRoles: Set<String> = [
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
    private let openSavePanelBundleID = "com.apple.appkit.xpc.openAndSavePanelService"
    private let finderBundleID = "com.apple.finder"
    private let outlookBundleID = "com.microsoft.outlook"

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
    private var isHardwareCursorMode = false

    private struct MagnetismEligibility {
        let isCandidate: Bool
        let qualifiesByRole: Bool
        let qualifiesByActionsOrURL: Bool
        let qualifiesImplicitly: Bool
        let pointerInsideExpandedFrame: Bool
        let pointerDistanceToCenter: CGFloat
        let pointerDistanceLimit: CGFloat
        let area: CGFloat
    }

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
        // Advance motion state first
        updateCursorState()

        let rawPointerPosition = motionEngine.rawPointerPosition
        let elementInfo = accessibilityInspector.elementInfo(at: rawPointerPosition)
        let isOpenSavePanel = elementInfo?.bundleIdentifier == openSavePanelBundleID || (elementInfo?.isFilePickerPanel ?? false)
        let knownOverlayTopmost = windowInspector.isKnownOverlayOwnerTopmost(at: rawPointerPosition)
        let shouldUseHardwareCursor = knownOverlayTopmost

        if shouldUseHardwareCursor {
            if !isHardwareCursorMode {
                // One-time handoff: show system cursor, align it to our virtual position, remove overlay
                overlayManager.tearDown()
                showCursor()
                let pos = motionEngine.position
                CGWarpMouseCursorPosition(pos)
                motionEngine.prime(with: pos)
                motionEngine.setMagnetismEnabled(false)
                isHardwareCursorMode = true
            }
        } else {
            if isHardwareCursorMode {
                // Returning from hardware mode: re-prime at current hardware location
                let pos = NSEvent.mouseLocation
                motionEngine.prime(with: pos)
                isHardwareCursorMode = false
            }
            let cursorView = overlayManager.ensureOverlay()
            hideCursor()
            applyCursorAppearance(on: cursorView)
        }

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
        let rawPointerPosition = motionEngine.rawPointerPosition
        var elementInfo = accessibilityInspector.elementInfo(at: rawPointerPosition) ??
            accessibilityInspector.elementInfo(at: position)

        var magnetismCandidate = elementInfo
        var magnetismPointerOverride: CGPoint?

        if needsHighVelocityProbe(for: elementInfo) {
            if let probe = probeMagnetismCandidateAlongPointerStep(excluding: elementInfo?.frame) {
                magnetismCandidate = probe.info
                magnetismPointerOverride = probe.point
                if elementInfo == nil {
                    elementInfo = probe.info
                }
            }
        }

        let hasLink = elementInfo?.url != nil
        let magnetismInfo = magnetismCandidate ?? elementInfo
        let isOpenSavePanel: Bool
        if let info = magnetismInfo {
            isOpenSavePanel = (info.bundleIdentifier == openSavePanelBundleID) || info.isFilePickerPanel
        } else {
            isOpenSavePanel = accessibilityInspector.isFilePickerPanel(at: rawPointerPosition)
        }

        cursorView.mousePosition = position
        let resolvedMode = appearanceResolver.cursorMode(
            for: cursorType,
            elementRole: elementInfo?.role,
            elementActionNames: elementInfo?.actionNames,
            elementHasLink: hasLink,
            elementFrame: elementInfo?.frame
        )
        let shouldSuspendMagnetism = isOpenSavePanel
        cursorView.cursorMode = shouldSuspendMagnetism ? .pointer : resolvedMode
        cursorView.targetFrame = shouldSuspendMagnetism ? nil : (elementInfo?.frame ?? magnetismCandidate?.frame ?? lastInteractiveTarget?.frame)
        cursorView.needsDisplay = true

        motionEngine.setMagnetismEnabled(!shouldSuspendMagnetism)

        if shouldSuspendMagnetism {
            updateMagneticTarget(elementInfo: nil)
        } else {
            updateMagneticTarget(elementInfo: magnetismCandidate ?? elementInfo, pointerOverride: magnetismPointerOverride)
        }
    }

    private func needsHighVelocityProbe(for element: AccessibilityElementInfo?) -> Bool {
        guard motionEngine.isMagnetismEnabled else { return false }

        if let element {
            let eligibility = magnetismEligibility(for: element, pointerPosition: motionEngine.rawPointerPosition)
            if eligibility.isCandidate {
                return false
            }
        }

        let start = motionEngine.previousRawPointerPosition
        let end = motionEngine.rawPointerPosition
        let distance = hypot(end.x - start.x, end.y - start.y)
        let lowSpeedThreshold: CGFloat = 18.0
        let minimumProbeDistance: CGFloat = 12.0

        if distance < lowSpeedThreshold && !motionEngine.isGlidingActive {
            return false
        }

        return distance >= minimumProbeDistance
    }

    private func probeMagnetismCandidateAlongPointerStep(excluding existingFrame: CGRect?) -> (info: AccessibilityElementInfo, point: CGPoint)? {
        guard motionEngine.isMagnetismEnabled else { return nil }

        let start = motionEngine.previousRawPointerPosition
        let end = motionEngine.rawPointerPosition
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        let minimumProbeDistance: CGFloat = 12.0

        guard distance >= minimumProbeDistance else { return nil }

        let spacing: CGFloat = 35.0
        let sampleCount = min(8, max(3, Int(ceil(distance / spacing))))
        for index in 1...sampleCount {
            let t = CGFloat(index) / CGFloat(sampleCount + 1)
            let samplePoint = CGPoint(x: start.x + dx * t, y: start.y + dy * t)

            if windowInspector.isKnownOverlayOwnerTopmost(at: samplePoint) {
                continue
            }

            guard let info = accessibilityInspector.elementInfo(at: samplePoint) else { continue }
            if let existingFrame, framesRoughlyEqual(existingFrame, info.frame) {
                continue
            }
            if info.bundleIdentifier == openSavePanelBundleID || info.isFilePickerPanel {
                continue
            }
            if info.actionNames.contains(where: ignoredMagneticAXActions.contains) {
                continue
            }

            let eligibility = magnetismEligibility(for: info, pointerPosition: samplePoint)
            if eligibility.isCandidate {
                return (info, samplePoint)
            }
        }

        return nil
    }

    private func framesRoughlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.midX - rhs.midX) < 2.0 &&
        abs(lhs.midY - rhs.midY) < 2.0 &&
        abs(lhs.width - rhs.width) < 4.0 &&
        abs(lhs.height - rhs.height) < 4.0
    }

    /// Determines if an element is a list item that should not have magnetism (but keeps buttons)
    private func isNonInteractiveListItem(info: AccessibilityElementInfo) -> Bool {
        guard let bundleID = info.bundleIdentifier else {
            return false
        }

        let bundleIDLower = bundleID.lowercased()

        // Finder: Keep magnetism for buttons
        if bundleIDLower == finderBundleID {
            if let role = info.role, role == kAXButtonRole {
                return false
            }

            // Disable magnetism for file/folder list items
            if let role = info.role {
                let isListItem = role == kAXRowRole ||
                    role == "AXOutlineRow" ||
                    role == kAXStaticTextRole ||
                    role == kAXGroupRole ||
                    role == kAXImageRole
                return isListItem
            }
        }

        // Outlook: More aggressive - disable most UI elements including sidebar buttons
        if bundleIDLower == outlookBundleID {
            if let role = info.role {
                // Disable sidebar buttons (typically small, square-ish buttons)
                if role == kAXButtonRole {
                    let width = info.frame.width
                    let height = info.frame.height
                    let aspectRatio = width / max(height, 1)

                    // Sidebar buttons are typically small and roughly square
                    let isSidebarButton = width < 100 && height < 100 && aspectRatio > 0.5 && aspectRatio < 2.0
                    if isSidebarButton {
                        return true
                    }
                }

                // Disable email list items and other list elements
                let isListElement = role == kAXRowRole ||
                    role == "AXOutlineRow" ||
                    role == kAXStaticTextRole ||
                    role == kAXGroupRole ||
                    role == "AXTableRow" ||
                    role == "AXListRow" ||
                    role == kAXImageRole
                return isListElement
            }
        }

        return false
    }

    private func magnetismEligibility(for info: AccessibilityElementInfo, pointerPosition: CGPoint) -> MagnetismEligibility {
        // Early exit: Disable magnetism for non-interactive list items (Finder folders, Outlook emails, etc.)
        if isNonInteractiveListItem(info: info) {
            return MagnetismEligibility(
                isCandidate: false,
                qualifiesByRole: false,
                qualifiesByActionsOrURL: false,
                qualifiesImplicitly: false,
                pointerInsideExpandedFrame: false,
                pointerDistanceToCenter: 0,
                pointerDistanceLimit: 0,
                area: 0
            )
        }

        let insetX = max(8.0, min(info.frame.width * 0.2, 32.0))
        let insetY = max(8.0, min(info.frame.height * 0.6, 36.0))
        let pointerInsideExpandedFrame = info.frame.insetBy(dx: -insetX, dy: -insetY).contains(pointerPosition)

        let pointerDistanceToCenter = hypot(
            pointerPosition.x - info.frame.midX,
            pointerPosition.y - info.frame.midY
        )

        let hasPressAction = info.actionNames.contains(where: actionableAXActions.contains)
        let hasLinkURL = info.url != nil
        let role = info.role

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

        let area = info.frame.width * info.frame.height
        let qualifiesByRole = role.map { magneticRoles.contains($0) } ?? false
        let qualifiesByActionsOrURL = hasPressAction || hasLinkURL
        let qualifiesImplicitly = (role == nil) && qualifiesByActionsOrURL && area > 100 && area <= baseMaxArea

        let isCandidate = ((qualifiesByRole || qualifiesByActionsOrURL) && area <= maxAreaForRole) || qualifiesImplicitly
        let pointerDistanceLimit = max(info.frame.height * 1.35, 180.0)

        var finalIsCandidate = isCandidate

        // Calculate aspect ratio
        let aspectRatio = max(info.frame.width, 1) / max(info.frame.height, 1)

        // Filter out extremely wide/thin elements (toolbars, thin horizontal buttons)
        let isSuperWide = aspectRatio > 8.0 && info.frame.height < 25.0
        if isSuperWide {
            finalIsCandidate = false
        }

        // Filter out wide rows in lists/tables AND wide sidebar items
        if let role {
            let isRowLike = role == kAXRowRole ||
                role == "AXOutlineRow" ||
                role == "AXTableRow" ||
                role == "AXListRow" ||
                role == "AXMenuItem"

            // More aggressive: lower aspect ratio threshold and remove width requirement
            let wideRow = isRowLike && aspectRatio > 1.5 && info.frame.width > 120

            if wideRow {
                finalIsCandidate = false
            }

            // Special case: Finder sidebar items might be AXStaticText or other roles
            let isSidebarLike = (role == kAXStaticTextRole || role == kAXGroupRole || role == "AXButton") &&
                aspectRatio > 1.8 &&
                info.frame.width > 140 &&
                info.frame.height < 50

            if isSidebarLike {
                finalIsCandidate = false
            }
        }

        // Catch any wide element regardless of role (last resort filter)
        let isGenericWideElement = aspectRatio > 2.2 &&
            info.frame.width > 160 &&
            info.frame.height < 45 &&
            area < 12000  // Not too big to avoid catching large containers

        if isGenericWideElement {
            finalIsCandidate = false
        }

        return MagnetismEligibility(
            isCandidate: finalIsCandidate,
            qualifiesByRole: qualifiesByRole,
            qualifiesByActionsOrURL: qualifiesByActionsOrURL,
            qualifiesImplicitly: qualifiesImplicitly,
            pointerInsideExpandedFrame: pointerInsideExpandedFrame,
            pointerDistanceToCenter: pointerDistanceToCenter,
            pointerDistanceLimit: pointerDistanceLimit,
            area: area
        )
    }

    /// Updates the magnetic target based on the current element
    private func updateMagneticTarget(elementInfo: AccessibilityElementInfo?, pointerOverride: CGPoint? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let rawPointerPosition = motionEngine.rawPointerPosition

        guard motionEngine.isMagnetismEnabled else {
            lastInteractiveTarget = nil
            lastInteractiveTargetTimestamp = 0
            lastInteractiveTargetQualifiesByRole = false
            lastInteractiveTargetQualifiesByActionsOrURL = false
            lastInteractiveTargetQualifiesImplicitly = false
            motionEngine.updateMagneticTarget(nil)
            return
        }

        guard let info = elementInfo else {
            maintainLastInteractiveTarget(now: now, pointerPosition: rawPointerPosition)
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

        if info.actionNames.contains(where: ignoredMagneticAXActions.contains) {
            lastInteractiveTarget = nil
            lastInteractiveTargetTimestamp = 0
            lastInteractiveTargetQualifiesByRole = false
            lastInteractiveTargetQualifiesByActionsOrURL = false
            lastInteractiveTargetQualifiesImplicitly = false
            motionEngine.updateMagneticTarget(nil)
            return
        }

        let evaluationPointer = pointerOverride ?? rawPointerPosition
        let eligibility = magnetismEligibility(for: info, pointerPosition: evaluationPointer)

        // Debug logging - shows what roles and actions are detected
        print("[Magnes] Element role: \(info.role ?? "nil"), actions: \(info.actionNames), url: \(info.url?.absoluteString ?? "nil"), area: \(Int(eligibility.area))")

        if !eligibility.pointerInsideExpandedFrame &&
            eligibility.pointerDistanceToCenter > eligibility.pointerDistanceLimit &&
            !eligibility.qualifiesImplicitly {
            maintainLastInteractiveTarget(now: now, pointerPosition: rawPointerPosition)
            return
        }

        if eligibility.isCandidate {
            motionEngine.updateMagneticTarget(info.frame)
            lastInteractiveTarget = info
            lastInteractiveTargetTimestamp = now
            lastInteractiveTargetQualifiesByRole = eligibility.qualifiesByRole
            lastInteractiveTargetQualifiesByActionsOrURL = eligibility.qualifiesByActionsOrURL
            lastInteractiveTargetQualifiesImplicitly = eligibility.qualifiesImplicitly
            return
        }

        maintainLastInteractiveTarget(now: now, pointerPosition: rawPointerPosition)
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
