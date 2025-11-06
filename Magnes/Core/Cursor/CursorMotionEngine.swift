//
//  CursorMotionEngine.swift
//  Magnes
//
//  Created by margooey on 11/24/24.
//

import AppKit
import ApplicationServices
import CoreGraphics

/// Encapsulates the virtual cursor state, pointer momentum, and system cursor synchronisation.
/// Math highlights:
/// - Collects physical mouse deltas, converts them to velocities, and blends with trackpad velocity.
/// - Uses exponential decay to simulate friction during glide.
/// - Scales normalized trackpad velocity by desktop bounds to obtain pixel velocity.
final class CursorMotionEngine {
    var isMagnetismEnabled: Bool = true
    private let settings = SettingsManager.shared
    
    enum VelocitySource: String {
        case pointer
        case trackpad
    }

    private struct State {
        var position: CGPoint = .zero
        var previousPosition: CGPoint = .zero
        var lastInputDelta: CGVector = .zero
        var velocity: CGVector = .zero
        var isGliding: Bool = false
        var velocitySource: VelocitySource = .pointer
    }

    private let glideDecayPerSecond: CGFloat
    private let minimumGlideVelocity: CGFloat
    private let glideStopSpeedMultiplier: CGFloat
    private let trackpadVelocityGain: CGFloat
    private let maxMomentumSpeed: CGFloat
    private let enableGlideLogging: Bool

    // Magnetic snapping parameters
    private let magnetismRadius: CGFloat
    private let magneticStrength: CGFloat
    private let snapThreshold: CGFloat
    private let targetLockDistance: CGFloat
    private let targetSwitchMinDistance: CGFloat
    private let targetSwitchConsistencyFrames: Int = 3
    private let minimumUnlockSpeed: CGFloat = 140.0

    private var state = State()
    private var desktopBounds: CGRect = .null
    private var lastPhysicalMousePosition: CGPoint = .zero
    private var currentMagneticTarget: CGRect?
    private var lockedMagneticTarget: CGRect?
    private var isLockedToTarget: Bool = false
    private var pendingSwitchTarget: CGRect?
    private var pendingSwitchConfidence: Int = 0

    var onLogMessage: ((String) -> Void)?
    var onGlideStateChange: ((Bool) -> Void)?

    init(
        glideDecayPerSecond: CGFloat = 6.5,
        minimumGlideVelocity: CGFloat = 220.0,
        glideStopSpeedMultiplier: CGFloat = 0.45,
        trackpadVelocityGain: CGFloat = 0.95,
        maxMomentumSpeed: CGFloat = 9000.0,
        magnetismRadius: CGFloat = 80.0,
        magneticStrength: CGFloat = 0.65,
        snapThreshold: CGFloat = 30.0,
        targetLockDistance: CGFloat = 50.0,
        targetSwitchMinDistance: CGFloat = 120.0,
        enableGlideLogging: Bool = false
    ) {
        self.glideDecayPerSecond = glideDecayPerSecond
        self.minimumGlideVelocity = minimumGlideVelocity
        self.glideStopSpeedMultiplier = glideStopSpeedMultiplier
        self.trackpadVelocityGain = trackpadVelocityGain
        self.maxMomentumSpeed = maxMomentumSpeed
        self.magnetismRadius = magnetismRadius
        self.magneticStrength = magneticStrength
        self.snapThreshold = snapThreshold
        self.targetLockDistance = targetLockDistance
        self.targetSwitchMinDistance = targetSwitchMinDistance
        self.enableGlideLogging = enableGlideLogging
    }

    var position: CGPoint { state.position }
    var isGlidingActive: Bool { state.isGliding }

    /// Updates the current magnetic target element (if any)
    /// Implements hysteresis to prevent rapid switching between nearby targets
    func updateMagneticTarget(_ targetFrame: CGRect?) {
        guard settings.magneticSnappingEnabled else {
            currentMagneticTarget = nil
            lockedMagneticTarget = nil
            isLockedToTarget = false
            pendingSwitchTarget = nil
            pendingSwitchConfidence = 0
            return
        }

        // If no new target, clear everything
        guard let newTarget = targetFrame else {
            currentMagneticTarget = nil
            if isLockedToTarget {
                isLockedToTarget = false
                lockedMagneticTarget = nil
            }
            pendingSwitchTarget = nil
            pendingSwitchConfidence = 0
            return
        }

        // If we have a locked target, be smart about unlocking
        if let lockedTarget = lockedMagneticTarget {
            let lockedCenter = CGPoint(x: lockedTarget.midX, y: lockedTarget.midY)
            let distanceFromLocked = hypot(
                state.position.x - lockedCenter.x,
                state.position.y - lockedCenter.y
            )
            let lockedParameters = magneticParameters(for: lockedTarget)

            // Check if new target is essentially the same (within a small tolerance)
            let isSameTarget = abs(newTarget.midX - lockedTarget.midX) < 5.0 &&
                               abs(newTarget.midY - lockedTarget.midY) < 5.0 &&
                               abs(newTarget.width - lockedTarget.width) < 10.0 &&
                               abs(newTarget.height - lockedTarget.height) < 10.0

            if isSameTarget {
                // Same target, update the locked frame (in case it moved slightly)
                lockedMagneticTarget = newTarget
                currentMagneticTarget = newTarget
                applyMagnetism()
                pendingSwitchTarget = nil
                pendingSwitchConfidence = 0
                return
            }

            // If targets overlap heavily (nested or stacked controls), prefer the existing lock.
            let overlapRect = lockedTarget.intersection(newTarget)
            if !overlapRect.isNull {
                let overlapArea = max(overlapRect.width, 0) * max(overlapRect.height, 0)
                let lockedArea = max(lockedTarget.width, 0) * max(lockedTarget.height, 0)
                let newArea = max(newTarget.width, 0) * max(newTarget.height, 0)
                let smallestArea = max(min(lockedArea, newArea), 1.0)
                let overlapRatio = overlapArea / smallestArea
                let pointerInsideLocked = lockedTarget.insetBy(dx: -6, dy: -6).contains(state.position)

                if overlapRatio >= 0.65 && pointerInsideLocked {
                    currentMagneticTarget = lockedTarget
                    applyMagnetism()
                    pendingSwitchTarget = nil
                    pendingSwitchConfidence = 0
                    return
                }
            }

            // Calculate distance to new target
            let newTargetCenter = CGPoint(x: newTarget.midX, y: newTarget.midY)
            let distanceToNew = hypot(
                state.position.x - newTargetCenter.x,
                state.position.y - newTargetCenter.y
            )

            // Check if we're moving TOWARD the new target (directional intent)
            let vectorToNew = CGVector(
                dx: newTargetCenter.x - state.position.x,
                dy: newTargetCenter.y - state.position.y
            )
            let velocityMagnitude = magnitude(of: state.velocity)
            let deltaMagnitude = magnitude(of: state.lastInputDelta)
            let alignmentTowardNew = directionalAlignmentTowardTarget(
                targetVector: vectorToNew,
                velocityVector: velocityMagnitude > 1.0 ? state.velocity : nil,
                inputVector: deltaMagnitude > 0.15 ? state.lastInputDelta : nil
            )
            let movingTowardNew = (alignmentTowardNew ?? 0) > 0.35

            // Decide whether to unlock
            let newTargetIsCloser = distanceToNew < distanceFromLocked
            let outsideSnapZone = distanceFromLocked > lockedParameters.snap * 1.5  // 45px at default

            // Unlock if:
            // 1. Moving away from snap zone AND new target is closer AND moving toward it
            // OR
            // 2. Far enough away (traditional hysteresis)
            let unlockDueToMovement = outsideSnapZone && newTargetIsCloser && movingTowardNew
            let unlockDueToDistance = distanceFromLocked > targetSwitchMinDistance
            let shouldUnlock = unlockDueToMovement || unlockDueToDistance

            if shouldUnlock {
                if unlockDueToDistance {
                    // Fast rejection – new target clearly far away
                    isLockedToTarget = false
                    lockedMagneticTarget = nil
                    pendingSwitchTarget = nil
                    pendingSwitchConfidence = 0
                } else {
                    let unlockSpeedThreshold = max(CGFloat(60), minimumUnlockSpeed * max(lockedParameters.snap / snapThreshold, 0.35))
                    let hasIntentSpeed = velocityMagnitude > unlockSpeedThreshold
                    let hasIntentDelta = deltaMagnitude > max(CGFloat(3.5), lockedParameters.snap * 0.28)
                    let hasIntentMovement = hasIntentSpeed || hasIntentDelta

                    if hasIntentMovement,
                       let pending = pendingSwitchTarget,
                       framesAreEquivalent(pending, newTarget) {
                        pendingSwitchConfidence += 1
                    } else if hasIntentMovement {
                        pendingSwitchTarget = newTarget
                        pendingSwitchConfidence = 1
                    } else {
                        pendingSwitchTarget = nil
                        pendingSwitchConfidence = 0
                    }

                    if hasIntentMovement && pendingSwitchConfidence >= targetSwitchConsistencyFrames {
                        isLockedToTarget = false
                        lockedMagneticTarget = nil
                        pendingSwitchTarget = nil
                        pendingSwitchConfidence = 0
                    } else {
                        currentMagneticTarget = lockedTarget
                        applyMagnetism()
                        return
                    }
                }
            } else {
                // Stay locked, ignore the new target
                currentMagneticTarget = lockedTarget
                applyMagnetism()
                pendingSwitchTarget = nil
                pendingSwitchConfidence = 0
                return
            }
        }

        // Update current target (either no lock, or we just unlocked)
        currentMagneticTarget = newTarget
        applyMagnetism()
        pendingSwitchTarget = nil
        pendingSwitchConfidence = 0
    }

    /// Seeds the virtual cursor state with the current system mouse position.
    /// Called on startup so the virtual cursor begins in sync with the visible pointer.
    func prime(with physicalPosition: CGPoint) {
        state = State(position: physicalPosition, previousPosition: physicalPosition, lastInputDelta: .zero)
        lastPhysicalMousePosition = physicalPosition
    }

    /// Recomputes the bounding box across all displays and clamps the virtual cursor inside it.
    func updateDesktopBounds(_ bounds: CGRect) {
        desktopBounds = bounds
        clampPositionToDesktop()
    }

    /// Marks the start of a touch interaction.
    /// Resets velocity and cancels any active glide so the new interaction starts from zero momentum.
    func beginTouch(at physicalLocation: CGPoint) {
        state.position = physicalLocation
        state.previousPosition = physicalLocation
        state.lastInputDelta = .zero
        lastPhysicalMousePosition = physicalLocation
        state.velocity = .zero
        setGliding(false)
        // Reset lock state on new touch to allow fresh target selection
        isLockedToTarget = false
        lockedMagneticTarget = nil
    }

    /// Absorbs raw pointer deltas and merges them with trackpad velocity if it is stronger.
    /// - Calculates pointer delta in pixels.
    /// - Converts delta to instantaneous velocity (pixels / second) using frame time.
    /// - Compares velocity magnitude with normalized trackpad velocity scaled to desktop pixels.
    /// - Updates virtual position by integrating the delta.
    func handleTouch(
        at physicalLocation: CGPoint,
        deltaTime: CGFloat,
        normalizedTrackpadVelocity: CGVector?
    ) {
        let delta = CGPoint(
            x: physicalLocation.x - lastPhysicalMousePosition.x,
            y: physicalLocation.y - lastPhysicalMousePosition.y
        )
        lastPhysicalMousePosition = physicalLocation
        state.previousPosition = state.position

        let pointerVelocity = CGVector(
            dx: delta.x / deltaTime,
            dy: delta.y / deltaTime
        )

        var velocity = pointerVelocity
        var source: VelocitySource = .pointer
        if let trackpadVelocity = trackpadVelocityInPixels(from: normalizedTrackpadVelocity),
           magnitude(of: trackpadVelocity) > magnitude(of: pointerVelocity) {
            velocity = trackpadVelocity
            source = .trackpad
        }

        state.velocity = velocity
        state.velocitySource = source
        state.position.x += delta.x
        state.position.y += delta.y
        state.lastInputDelta = CGVector(dx: delta.x, dy: delta.y)

        // Apply magnetic pull if near a target
        applyMagnetism()

        clampPositionToDesktop()

        if state.isGliding {
            setGliding(false)
            logGlide("interrupted by touch")
        }
    }

    /// Handles the period when no fingers are touching the trackpad.
    /// - If touch just ended, either start a glide (momentum) or cancel it if multi touch suppression applies.
    /// - If glide is active, integrate velocity forward while applying exponential decay.
    func handleNoTouch(
        physicalLocation: CGPoint,
        deltaTime: CGFloat,
        suppressGlide: Bool,
        touchJustEnded: Bool
    ) {
        lastPhysicalMousePosition = physicalLocation

        if touchJustEnded {
            if suppressGlide {
                if state.isGliding {
                    logGlide("skipping glide (recent multi-touch)")
                }
                setGliding(false)
                state.velocity = .zero
            } else {
                beginGlideIfNeeded()
            }
        }

        if state.isGliding {
            applyMomentum(timeStep: deltaTime)
        } else {
            state.lastInputDelta = .zero
        }
    }

    /// Applies magnetic attraction to nearby interactive elements
    /// Based on iPadOS pointer magnetism behavior with lock-on to prevent jittering
    private func applyMagnetism() {
        guard settings.magneticSnappingEnabled else { return }
        guard let targetFrame = currentMagneticTarget else {
            // No target - unlock if we were locked
            if isLockedToTarget {
                isLockedToTarget = false
                lockedMagneticTarget = nil
            }
            return
        }

        // Calculate target center
        let targetCenter = CGPoint(
            x: targetFrame.midX,
            y: targetFrame.midY
        )

        // Calculate distance to target center
        let dx = targetCenter.x - state.position.x
        let dy = targetCenter.y - state.position.y
        let distance = hypot(dx, dy)

        let parameters = magneticParameters(for: targetFrame)
        let localMagnetismRadius = parameters.radius
        let localSnapThreshold = parameters.snap
        let localMagneticStrength = parameters.strength

        // Expand hit area by magnetism radius (like the tutorial suggests ~20-40pt)
        let expandedFrame = targetFrame.insetBy(dx: -localMagnetismRadius, dy: -localMagnetismRadius)

        let previousPoint = state.previousPosition
        if segmentIntersectsCircle(
            from: previousPoint,
            to: state.position,
            center: targetCenter,
            radius: localSnapThreshold
        ) {
            isLockedToTarget = true
            lockedMagneticTarget = targetFrame
            state.position = targetCenter
            state.previousPosition = targetCenter
            state.velocity = .zero
            if state.isGliding {
                setGliding(false)
                syncSystemCursorToVirtualPosition()
            }
            return
        }

        // Check if cursor is within magnetism zone
        guard expandedFrame.contains(state.position) || distance < localMagnetismRadius else {
            return
        }

        // Lock onto target if we get close enough
        if !isLockedToTarget && distance < targetLockDistance {
            isLockedToTarget = true
            lockedMagneticTarget = targetFrame
        }

        let speed = magnitude(of: state.velocity)
        let inputMagnitude = magnitude(of: state.lastInputDelta)
        var escapeScale: CGFloat = 1.0
        var alignment: CGFloat?

        // Use directional intent to either boost or suppress magnetism.
        if let computedAlignment = directionalAlignmentTowardTarget(
            targetVector: CGVector(dx: dx, dy: dy),
            velocityVector: speed > 1.0 ? state.velocity : nil,
            inputVector: inputMagnitude > 0.15 ? state.lastInputDelta : nil
        ) {
            alignment = computedAlignment
            let releaseAlignmentThreshold: CGFloat = -0.55
            let activationAlignment: CGFloat = 0.2

            if computedAlignment <= releaseAlignmentThreshold {
                // Hard shove away—cancel the lock and skip attraction this frame.
                if isLockedToTarget {
                    isLockedToTarget = false
                    lockedMagneticTarget = nil
                }
                return
            }

            if computedAlignment <= 0 {
                // Any backward intent should fully disable the pull.
                escapeScale = 0
            } else if computedAlignment < activationAlignment {
                // Gentle approach: ease in magnetism to avoid sudden re-lock.
                let normalized = computedAlignment / activationAlignment
                escapeScale = max(0, normalized * normalized * 0.12)
            } else {
                // Strong approach: blend toward full strength.
                let normalized = (computedAlignment - activationAlignment) / (1.0 - activationAlignment)
                escapeScale = min(1.0, 0.15 + normalized * 0.85)
            }
        }

        if escapeScale <= 0 {
            if isLockedToTarget {
                isLockedToTarget = false
                lockedMagneticTarget = nil
            }
            return
        }

        if state.isGliding,
           distance < localMagnetismRadius,
           speed > 35,
           (alignment ?? 0.5) > -0.2 {
            state.position = targetCenter
            state.previousPosition = targetCenter
            state.velocity = .zero
            setGliding(false)
            syncSystemCursorToVirtualPosition()
            return
        }

        // If very close to center, snap directly and kill velocity (strong magnetism)
        if distance < localSnapThreshold {
            if escapeScale > 0 {
                if state.isGliding {
                    // During glide, hard-snap to the target so momentum can't drift through
                    state.position = targetCenter
                    state.previousPosition = targetCenter
                    state.velocity = .zero
                    setGliding(false)
                    syncSystemCursorToVirtualPosition()
                } else if distance > 1.0 {
                    // Snap almost completely to center while preserving slight manual control
                    let snapWeight = 0.95 * escapeScale
                    state.position.x += (targetCenter.x - state.position.x) * snapWeight
                    state.position.y += (targetCenter.y - state.position.y) * snapWeight
                } else {
                    // Lock exactly to center
                    state.position.x = targetCenter.x
                    state.position.y = targetCenter.y
                }
            }

            // Kill velocity almost completely when locked on, but let escapes keep their momentum
            let velocityDamping = 0.05 + (1.0 - escapeScale) * 0.95
            state.velocity.dx *= velocityDamping
            state.velocity.dy *= velocityDamping

            // Stop glide if we're locked onto target
            if state.isGliding && distance < 5.0 {
                setGliding(false)
                state.velocity = .zero
            }
        } else if distance > 0 && escapeScale > 0 {
            // In outer zone - apply strong magnetic pull
            let pullForce = localMagneticStrength * (1.0 - distance / localMagnetismRadius)

            // Stronger pull when moving fast (to catch flicks)
            let speedMultiplier = min(1.0 + (speed / maxMomentumSpeed) * 0.5, 1.5)
            let adjustedPullForce = pullForce * speedMultiplier * escapeScale

            state.position.x += dx * adjustedPullForce
            state.position.y += dy * adjustedPullForce

            // Heavy velocity dampening based on proximity
            let dampenFactor = 1.0 - (pullForce * 0.85 * escapeScale)
            state.velocity.dx *= dampenFactor
            state.velocity.dy *= dampenFactor
        }
    }

    /// Checks whether the current velocity magnitude exceeds the minimum required to initiate glide.
    /// If so, locks in glide mode and synchronizes the system cursor with the virtual one.
    private func beginGlideIfNeeded() {
        let speed = magnitude(of: state.velocity)
        guard speed >= minimumGlideVelocity else {
            if speed > 0 {
                logGlide("skipping glide (\(Int(speed))px/s via \(state.velocitySource.rawValue) below threshold)")
            }
            setGliding(false)
            state.velocity = .zero
            return
        }

        setGliding(true)
        logGlide("starting at \(Int(speed))px/s via \(state.velocitySource.rawValue)")
        syncSystemCursorToVirtualPosition()
    }

    /// Applies exponential decay to the existing glide velocity and moves the virtual cursor accordingly.
    /// The decay factor is (1 - decayRate * dt), clamped at zero, which mimics friction over time.
    /// When the speed falls below a fraction of the minimum glide velocity, glide stops entirely.
    private func applyMomentum(timeStep deltaTime: CGFloat) {
        let decayFactor = max(0, 1 - glideDecayPerSecond * deltaTime)
        state.velocity.dx *= decayFactor
        state.velocity.dy *= decayFactor

        let momentumDelta = CGVector(dx: state.velocity.dx * deltaTime, dy: state.velocity.dy * deltaTime)
        state.previousPosition = state.position
        state.position.x += momentumDelta.dx
        state.position.y += momentumDelta.dy
        state.lastInputDelta = momentumDelta

        // Apply magnetic pull during glide (important for snap-to-target on flick)
        applyMagnetism()

        clampPositionToDesktop()
        syncSystemCursorToVirtualPosition()

        let speed = magnitude(of: state.velocity)
        if speed < minimumGlideVelocity * glideStopSpeedMultiplier {
            setGliding(false)
            state.velocity = .zero
            logGlide("stopped (velocity dissipated)")
            syncSystemCursorToVirtualPosition()
        }
    }

    /// Converts normalized trackpad velocity into pixel velocity by scaling against desktop dimensions,
    /// then clamps the result to the configured maximum momentum speed to avoid runaway values.
    private func trackpadVelocityInPixels(from normalizedVelocity: CGVector?) -> CGVector? {
        guard let normalizedVelocity, !desktopBounds.isNull else { return nil }
        let scaled = CGVector(
            dx: normalizedVelocity.dx * desktopBounds.width * trackpadVelocityGain,
            dy: normalizedVelocity.dy * desktopBounds.height * trackpadVelocityGain
        )
        return clampedVelocity(scaled, maxMagnitude: maxMomentumSpeed)
    }

    /// Ensures the virtual cursor position stays inside the combined screen bounds.
    private func clampPositionToDesktop() {
        guard !desktopBounds.isNull else { return }
        state.position.x = min(max(state.position.x, desktopBounds.minX), desktopBounds.maxX)
        state.position.y = min(max(state.position.y, desktopBounds.minY), desktopBounds.maxY)
    }

    /// Mirrors the virtual cursor position to the system cursor using display-local coordinates.
    private func syncSystemCursorToVirtualPosition() {
        let targetPoint = state.position
        guard let screen = (NSScreen.screens.first { $0.frame.contains(targetPoint) }) ?? NSScreen.main else {
            return
        }
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return
        }
        let localX = targetPoint.x - screen.frame.minX
        let localYFromBottom = targetPoint.y - screen.frame.minY
        let localY = screen.frame.height - localYFromBottom
        CGDisplayMoveCursorToPoint(screenNumber, CGPoint(x: localX, y: localY))
    }

    /// Returns the Euclidean length of a vector.
    private func magnitude(of vector: CGVector) -> CGFloat {
        hypot(vector.dx, vector.dy)
    }

    /// Returns magnetism radius, snap threshold, and strength adjusted for the given frame.
    private func magneticParameters(for frame: CGRect) -> (radius: CGFloat, snap: CGFloat, strength: CGFloat) {
        var radius = magnetismRadius
        var snap = snapThreshold
        var strength = magneticStrength

        if frame.height > 80.0 && frame.height > frame.width * 0.8 {
            radius *= 0.55
            snap *= 0.65
            strength *= 0.55
        }

        return (radius, snap, strength)
    }

    /// Computes directional alignment toward the target using velocity and/or raw input deltas.
    private func directionalAlignmentTowardTarget(
        targetVector: CGVector,
        velocityVector: CGVector?,
        inputVector: CGVector?
    ) -> CGFloat? {
        let targetDistance = magnitude(of: targetVector)
        guard targetDistance > 0 else { return nil }

        let targetNorm = CGVector(dx: targetVector.dx / targetDistance, dy: targetVector.dy / targetDistance)
        var alignmentSum: CGFloat = 0
        var weightSum: CGFloat = 0

        if let velocityVector {
            let magnitude = magnitude(of: velocityVector)
            if magnitude > 0 {
                let velocityNorm = CGVector(dx: velocityVector.dx / magnitude, dy: velocityVector.dy / magnitude)
                let weight = min(magnitude / CGFloat(300), CGFloat(1))
                alignmentSum += (velocityNorm.dx * targetNorm.dx + velocityNorm.dy * targetNorm.dy) * weight
                weightSum += weight
            }
        }

        if let inputVector {
            let magnitude = magnitude(of: inputVector)
            if magnitude > 0 {
                let inputNorm = CGVector(dx: inputVector.dx / magnitude, dy: inputVector.dy / magnitude)
                let weight = min(magnitude / CGFloat(10), CGFloat(1))
                alignmentSum += (inputNorm.dx * targetNorm.dx + inputNorm.dy * targetNorm.dy) * weight
                weightSum += weight
            }
        }

        guard weightSum > 0 else { return nil }
        return alignmentSum / weightSum
    }

    /// Determines whether two frames are effectively the same within a small tolerance.
    private func framesAreEquivalent(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.midX - rhs.midX) < 5.0 &&
        abs(lhs.midY - rhs.midY) < 5.0 &&
        abs(lhs.width - rhs.width) < 10.0 &&
        abs(lhs.height - rhs.height) < 10.0
    }

    /// Checks whether the line segment between two points intersects a circle.
    private func segmentIntersectsCircle(from start: CGPoint, to end: CGPoint, center: CGPoint, radius: CGFloat) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        if lengthSquared == 0 {
            let distance = hypot(start.x - center.x, start.y - center.y)
            return distance <= radius
        }

        let tNumerator = (center.x - start.x) * dx + (center.y - start.y) * dy
        let t = max(0, min(1, tNumerator / lengthSquared))
        let closestPoint = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
        let distanceToCenter = hypot(closestPoint.x - center.x, closestPoint.y - center.y)
        return distanceToCenter <= radius
    }

    /// If velocity exceeds the maximum configured speed, scales it back to that limit while preserving direction.
    private func clampedVelocity(_ vector: CGVector, maxMagnitude: CGFloat) -> CGVector {
        let magnitude = magnitude(of: vector)
        guard magnitude > maxMagnitude, magnitude > 0 else { return vector }
        let scale = maxMagnitude / magnitude
        return CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
    }

    /// Emits glide debug logs when enabled.
    private func logGlide(_ message: String) {
        guard enableGlideLogging else { return }
        onLogMessage?(message)
    }

    /// Updates the glide flag and notifies observers when the glide state changes.
    private func setGliding(_ newValue: Bool) {
        guard state.isGliding != newValue else { return }
        state.isGliding = newValue
        onGlideStateChange?(newValue)
    }
}
