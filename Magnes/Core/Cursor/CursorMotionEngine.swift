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
        var preMagnetPosition: CGPoint = .zero
        var previousPreMagnetPosition: CGPoint = .zero
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
    private let baseTargetSwitchMinDistance: CGFloat
    private let targetSwitchConsistencyFrames: Int = 3
    private let minimumUnlockSpeed: CGFloat = 140.0
    private let enableMagnetismLogging: Bool
    private let enableDimensionLogging: Bool = true

    private var state = State()
    private var desktopBounds: CGRect = .null
    private var lastPhysicalMousePosition: CGPoint = .zero
    private var currentMagneticTarget: CGRect?
    private var lockedMagneticTarget: CGRect?
    private var isLockedToTarget: Bool = false
    private var pendingSwitchTarget: CGRect?
    private var pendingSwitchConfidence: Int = 0
    private var magnetismEnabled: Bool = true
    private var lastSeenCandidate: CGRect?
    private var lastSeenCandidateTTL: Int = 0
    private var rawFreshThisFrame: Bool = false
    private var lockStrainCounter: Int = 0
    private var lockStrainTarget: CGRect?

    var onLogMessage: ((String) -> Void)?
    var onGlideStateChange: ((Bool) -> Void)?
    var isMagnetismEnabled: Bool { magnetismEnabled }
    var rawPointerPosition: CGPoint { state.preMagnetPosition }
    var previousRawPointerPosition: CGPoint { state.previousPreMagnetPosition }

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
        enableGlideLogging: Bool = false,
        enableMagnetismLogging: Bool = false
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
        self.baseTargetSwitchMinDistance = targetSwitchMinDistance
        self.enableGlideLogging = enableGlideLogging
        self.enableMagnetismLogging = enableMagnetismLogging
    }

    var position: CGPoint { state.position }
    var isGlidingActive: Bool { state.isGliding }

    /// Enables or disables magnetism globally. Disabling it clears any locked targets.
    func setMagnetismEnabled(_ enabled: Bool) {
        guard magnetismEnabled != enabled else { return }
        magnetismEnabled = enabled
        if !enabled {
            resetMagnetismState()
        }
    }

    /// Updates the current magnetic target element (if any)
    /// Implements hysteresis to prevent rapid switching between nearby targets
    func updateMagneticTarget(_ targetFrame: CGRect?) {
        guard magnetismEnabled else {
            resetMagnetismState()
            return
        }

        // If no new target, keep the last candidate so we can still snap during transient gaps.
        guard let newTarget = targetFrame else {
            currentMagneticTarget = nil
            pendingSwitchTarget = nil
            pendingSwitchConfidence = 0
            if lastSeenCandidateTTL > 0 {
                lastSeenCandidateTTL -= 1
            } else {
                lastSeenCandidate = nil
            }
            return
        }

        lastSeenCandidate = newTarget
        lastSeenCandidateTTL = 6

        // If we have a locked target, be smart about unlocking
        if let lockedTarget = lockedMagneticTarget {
            let pointerPosition = state.preMagnetPosition
            let lockedCenter = CGPoint(x: lockedTarget.midX, y: lockedTarget.midY)
            let distanceFromLocked = hypot(
                pointerPosition.x - lockedCenter.x,
                pointerPosition.y - lockedCenter.y
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
                let pointerInsideLocked = lockedTarget.insetBy(dx: -6, dy: -6).contains(pointerPosition)

                if overlapRatio >= 0.65 && pointerInsideLocked {
                    currentMagneticTarget = lockedTarget
                    pendingSwitchTarget = nil
                    pendingSwitchConfidence = 0
                    return
                }
            }

            // Calculate distance to new target
            let newTargetCenter = CGPoint(x: newTarget.midX, y: newTarget.midY)
            let distanceToNew = hypot(
                pointerPosition.x - newTargetCenter.x,
                pointerPosition.y - newTargetCenter.y
            )

            // If the raw pointer is already inside the candidate target, prefer switching immediately.
            if !framesAreEquivalent(newTarget, lockedTarget) &&
                newTarget.insetBy(dx: -8, dy: -8).contains(pointerPosition) {
                if enableMagnetismLogging {
                    logMagnetism("Unlocking: pointer entered new target bounds directly")
                }
                isLockedToTarget = false
                lockedMagneticTarget = nil
                pendingSwitchTarget = nil
                pendingSwitchConfidence = 0
                resetLockStrainTracking()
                currentMagneticTarget = newTarget
                return
            }

            // Check if we're moving TOWARD the new target (directional intent)
            let vectorToNew = CGVector(
                dx: newTargetCenter.x - pointerPosition.x,
                dy: newTargetCenter.y - pointerPosition.y
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
            let minorAxis = max(min(lockedTarget.width, lockedTarget.height), 1.0)
            let newTargetIsCloser = distanceToNew < distanceFromLocked
            let exitThreshold = max(lockedParameters.snap * 1.1, minorAxis * 0.75)
            let outsideSnapZone = distanceFromLocked > exitThreshold
            let preliminarySwitchDistance = max(minorAxis * 0.95, lockedParameters.snap * 1.5)
            let dynamicSwitchDistance = min(
                baseTargetSwitchMinDistance,
                max(preliminarySwitchDistance, minorAxis, baseTargetSwitchMinDistance * 0.35)
            )
            // Unlock if we move out of the snap radius toward a closer target,
            // or if we travel beyond the dynamic distance threshold that scales with element size.
            let unlockDueToMovement = outsideSnapZone && newTargetIsCloser && movingTowardNew
            let unlockDueToDistance = distanceFromLocked > dynamicSwitchDistance
            let shouldUnlock = unlockDueToMovement || unlockDueToDistance

            if enableMagnetismLogging {
                logMagnetism(
                    "Locked target: h=\(Int(lockedTarget.height)) distance=\(Int(distanceFromLocked)) "
                    + "exit>\(Int(exitThreshold)) switch>\(Int(dynamicSwitchDistance)) "
                    + "toward=\(String(format: "%.2f", alignmentTowardNew ?? -9)) "
                    + "speed=\(Int(velocityMagnitude))"
                )
            }

            if shouldUnlock {
                if unlockDueToDistance {
                    // Fast rejection – new target clearly far away
                    isLockedToTarget = false
                    lockedMagneticTarget = nil
                    pendingSwitchTarget = nil
                    pendingSwitchConfidence = 0
                    resetLockStrainTracking()
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
                        if enableMagnetismLogging {
                            logMagnetism("Unlocking due to consistent intent toward new target")
                        }
                        isLockedToTarget = false
                        lockedMagneticTarget = nil
                        pendingSwitchTarget = nil
                        pendingSwitchConfidence = 0
                        resetLockStrainTracking()
                    } else {
                        currentMagneticTarget = lockedTarget
                        return
                    }
                }
            } else {
                if enableMagnetismLogging {
                    logMagnetism("Maintaining lock: inside exit threshold and no strong intent")
                }
                // Stay locked, ignore the new target
                currentMagneticTarget = lockedTarget
                pendingSwitchTarget = nil
                pendingSwitchConfidence = 0
                return
            }
        }

        // Update current target (either no lock, or we just unlocked)
        currentMagneticTarget = newTarget
        pendingSwitchTarget = nil
        pendingSwitchConfidence = 0

        if rawFreshThisFrame {
            applyMagnetism()
            rawFreshThisFrame = false
        }
    }

    /// Seeds the virtual cursor state with the current system mouse position.
    /// Called on startup so the virtual cursor begins in sync with the visible pointer.
    func prime(with physicalPosition: CGPoint) {
        state = State(
            position: physicalPosition,
            previousPosition: physicalPosition,
            lastInputDelta: .zero,
            velocity: .zero,
            isGliding: false,
            velocitySource: .pointer,
            preMagnetPosition: physicalPosition,
            previousPreMagnetPosition: physicalPosition
        )
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
        state.preMagnetPosition = physicalLocation
        state.previousPreMagnetPosition = physicalLocation
        setGliding(false)
        // Reset lock state on new touch to allow fresh target selection
        isLockedToTarget = false
        lockedMagneticTarget = nil
        resetLockStrainTracking()
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
        rawFreshThisFrame = false

        let delta = CGPoint(
            x: physicalLocation.x - lastPhysicalMousePosition.x,
            y: physicalLocation.y - lastPhysicalMousePosition.y
        )
        lastPhysicalMousePosition = physicalLocation

        let rawStart = state.preMagnetPosition
        let rawEnd = CGPoint(x: rawStart.x + delta.x, y: rawStart.y + delta.y)
        if interceptRawStepIfCrossing(from: rawStart, to: rawEnd) {
            state.velocitySource = .pointer
            rawFreshThisFrame = true
            clampPositionToDesktop()
            return
        }

        var scaledDelta = delta
        if let brakeTarget = lockedMagneticTarget ?? currentMagneticTarget ?? lastSeenCandidate {
            let center = CGPoint(x: brakeTarget.midX, y: brakeTarget.midY)
            let params = magneticParameters(for: brakeTarget)
            let brakeRadius = params.radius * 1.6
            let approach = distanceFromPointToSegment(center, rawStart, rawEnd)
            if approach < brakeRadius {
                var scale = approach / brakeRadius
                scale = max(0.15, min(1.0, scale * scale))
                scaledDelta.x *= scale
                scaledDelta.y *= scale
            }
        }

        state.previousPosition = state.position
        state.position.x += scaledDelta.x
        state.position.y += scaledDelta.y

        let pointerVelocity = CGVector(
            dx: scaledDelta.x / max(deltaTime, 0.0001),
            dy: scaledDelta.y / max(deltaTime, 0.0001)
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
        state.lastInputDelta = CGVector(dx: scaledDelta.x, dy: scaledDelta.y)
        state.previousPreMagnetPosition = state.preMagnetPosition
        state.preMagnetPosition = state.position

        rawFreshThisFrame = true

        applyMagnetism()

        clampPositionToDesktop()

        if let target = currentMagneticTarget {
            let rp = state.preMagnetPosition
            let center = CGPoint(x: target.midX, y: target.midY)
            let rawDistance = hypot(center.x - rp.x, center.y - rp.y)
            let params = magneticParameters(for: target)
            if rawDistance <= params.radius * 1.15 && magnitude(of: state.velocity) < 1500 {
                syncSystemCursorToVirtualPosition()
            }
        }

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
        guard magnetismEnabled else { return }

        // --- 0) Handle escape from an existing lock using RAW distance ---
        if isLockedToTarget, let lockedTarget = lockedMagneticTarget {
            let rawPosition = state.preMagnetPosition
            let lockedCenter = CGPoint(x: lockedTarget.midX, y: lockedTarget.midY)
            let escapeDistance = hypot(rawPosition.x - lockedCenter.x, rawPosition.y - lockedCenter.y)
            let lockedParameters = magneticParameters(for: lockedTarget)
            let minorAxis = max(min(lockedTarget.width, lockedTarget.height), 1.0)
            let majorAxis = max(lockedTarget.width, lockedTarget.height)
            let aspectRatio = majorAxis / minorAxis

            var unlockDistance = max(minorAxis * 0.65, lockedParameters.snap * 0.9)

            // Lower threshold to catch typical list rows and sidebars (2:1 to 2.5:1 aspect ratio)
            if aspectRatio > 1.8 && minorAxis < 110.0 {
                let cappedUnlock = max(minorAxis * 0.65, lockedParameters.snap * 0.95, 26.0)
                unlockDistance = min(unlockDistance, cappedUnlock)

                let deltaRaw = CGVector(
                    dx: rawPosition.x - state.previousPreMagnetPosition.x,
                    dy: rawPosition.y - state.previousPreMagnetPosition.y
                )

                // Determine if element is vertical (sidebar) or horizontal (toolbar)
                let isVertical = lockedTarget.height > lockedTarget.width
                let isHorizontal = lockedTarget.width > lockedTarget.height

                if isVertical {
                    // Vertical sidebar: allow horizontal escape
                    let horizontalIntent = abs(deltaRaw.dx) > abs(deltaRaw.dy) * 0.9 && abs(deltaRaw.dx) > 2.5
                    let movingAwayHorizontally = (rawPosition.x - lockedCenter.x) * deltaRaw.dx > 0

                    if horizontalIntent && movingAwayHorizontally {
                        let directionalCap = max(minorAxis * 0.48, lockedParameters.snap * 0.75, 18.0)
                        unlockDistance = min(unlockDistance, directionalCap)
                    }
                } else if isHorizontal {
                    // Horizontal toolbar: allow vertical escape
                    let verticalIntent = abs(deltaRaw.dy) > abs(deltaRaw.dx) * 0.9 && abs(deltaRaw.dy) > 2.5
                    let movingAwayVertically = (rawPosition.y - lockedCenter.y) * deltaRaw.dy > 0

                    if verticalIntent && movingAwayVertically {
                        let directionalCap = max(minorAxis * 0.48, lockedParameters.snap * 0.75, 18.0)
                        unlockDistance = min(unlockDistance, directionalCap)
                    }
                }
            }

            if enableDimensionLogging {
                print("[Magnes] Locked target: w=\(Int(lockedTarget.width)) h=\(Int(lockedTarget.height)) aspect=\(String(format: "%.2f", aspectRatio)) minor=\(Int(minorAxis)) escape=\(Int(escapeDistance)) unlock=\(Int(unlockDistance))")
            }

            if escapeDistance > unlockDistance {
                if enableMagnetismLogging {
                    logMagnetism("Unlocking due to raw escape: \(Int(escapeDistance)) > \(Int(unlockDistance))")
                }
                isLockedToTarget = false
                lockedMagneticTarget = nil
                resetLockStrainTracking()
                if let candidate = lastSeenCandidate { currentMagneticTarget = candidate }
            }
        }

        let startRaw = state.previousPreMagnetPosition
        let endRaw = state.preMagnetPosition

        if isLockedToTarget, let lockedTarget = lockedMagneticTarget {
            evaluateLockStrain(for: lockedTarget, startRaw: startRaw, endRaw: endRaw)
        }

        // --- 1) Candidate adoption & candidate crossing capture (unchanged + rectangular) ---
        if let candidate = lastSeenCandidate {
            if !isLockedToTarget {
                if !desktopBounds.isNull {
                    let desktopArea = desktopBounds.width * desktopBounds.height
                    let candidateArea = max(candidate.width, 0) * max(candidate.height, 0)
                    if candidateArea <= desktopArea * 0.35 {
                        let rp = endRaw
                        let candCenterDist = hypot(candidate.midX - rp.x, candidate.midY - rp.y)
                        let candParams = magneticParameters(for: candidate)
                        let adoptLimitCenter = candParams.radius * 1.9 + 12.0
                        let rectDist = distanceFromPointToRect(rp, candidate)
                        let adoptLimitRect = max(10.0, candParams.snap * 1.8)
                        if candCenterDist <= adoptLimitCenter || rectDist <= adoptLimitRect {
                            if let current = currentMagneticTarget {
                                let curCenterDist = hypot(current.midX - rp.x, current.midY - rp.y)
                                let curRectDist = distanceFromPointToRect(rp, current)
                                let candKey = min(candCenterDist, rectDist)
                                let curKey = min(curCenterDist, curRectDist)
                                if candKey + 12.0 < curKey { currentMagneticTarget = candidate }
                            } else {
                                currentMagneticTarget = candidate
                            }
                        }
                    }
                }
            }

            // Candidate edge/center crossing should snap immediately (robust for fast skims)
            let candCenter = CGPoint(x: candidate.midX, y: candidate.midY)
            let candParams = magneticParameters(for: candidate)
            let candSnapBand = candParams.snap * 1.5
            let cPadX = max(6.0, min(candidate.width * 0.22, 18.0))
            let cPadY = max(6.0, min(candidate.height * 0.60, 18.0))
            let expandedCandidate = candidate.insetBy(dx: -cPadX, dy: -cPadY)

            // Directional sanity (avoid snapping when flying away)
            let travel = CGVector(dx: endRaw.x - startRaw.x, dy: endRaw.y - startRaw.y)
            let toCand = CGVector(dx: candCenter.x - startRaw.x, dy: candCenter.y - startRaw.y)
            let movingTowardCand = (travel.dx * toCand.dx + travel.dy * toCand.dy) > 0

            // Allow capture even if the frame ends past the target by using closest approach along the segment
            let candCenterSegDist = distanceFromPointToSegment(candCenter, startRaw, endRaw)

            let crossesCand =
                segmentIntersectsCircle(from: startRaw, to: endRaw, center: candCenter, radius: candSnapBand) ||
                segmentIntersectsRect(from: startRaw, to: endRaw, rect: expandedCandidate)

            let largeStepCand: Bool = {
                let stepSquared = travel.dx * travel.dx + travel.dy * travel.dy
                if stepSquared > (candParams.radius * 2) * (candParams.radius * 2) {
                    let mid = CGPoint(x: (startRaw.x + endRaw.x) * 0.5, y: (startRaw.y + endRaw.y) * 0.5)
                    return expandedCandidate.contains(mid) || candCenterSegDist <= candSnapBand
                }
                return false
            }()

            if movingTowardCand && (crossesCand || largeStepCand || candCenterSegDist <= candSnapBand) {
                snapToTargetCenter(targetFrame: candidate, targetCenter: candCenter)
                return
            }
        }

        // --- 1.5) PRE-BRAKE near last-seen candidate even if not adopted (closest-approach based) ---
        if currentMagneticTarget == nil, let cand = lastSeenCandidate {
            let speed = magnitude(of: state.velocity)
            if speed > 70 {
                let candCenter = CGPoint(x: cand.midX, y: cand.midY)
                let candParams = magneticParameters(for: cand)
                let brakeRadius = candParams.radius * 1.6
                let dCenter = hypot(candCenter.x - endRaw.x, candCenter.y - endRaw.y)
                let dRect = distanceFromPointToRect(endRaw, cand)
                let dSeg = distanceFromPointToSegment(candCenter, startRaw, endRaw)
                let approach = min(dCenter, dRect, dSeg)
                if approach < brakeRadius {
                    let proximityBrake = max(0, 1 - approach / brakeRadius)
                    let speedBrake = max(0, min(1.0, (speed - 38.0) / 210.0))
                    let brakeFactor = max(proximityBrake, 0.24) * speedBrake
                    if brakeFactor > 0 {
                        let damping = max(0.03, 1.0 - 0.96 * brakeFactor)
                        state.velocity.dx *= damping
                        state.velocity.dy *= damping
                        state.lastInputDelta = CGVector(
                            dx: state.lastInputDelta.dx * damping,
                            dy: state.lastInputDelta.dy * damping
                        )
                    }
                }
            }
        }

        // --- 2) If there is still no target, bail (but only after candidate pre-brake ran) ---
        guard let targetFrame = currentMagneticTarget else {
            if isLockedToTarget {
                isLockedToTarget = false
                lockedMagneticTarget = nil
                resetLockStrainTracking()
            }
            return
        }

        // --- 3) Compute parameters & distances for the current target ---
        let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        var dx = targetCenter.x - state.position.x
        var dy = targetCenter.y - state.position.y
        var distance = hypot(dx, dy)

        let params = magneticParameters(for: targetFrame)
        let localMagnetismRadius = params.radius
        let localSnapThreshold = params.snap
        let localMagStrength = params.strength
        let expandedFrame = targetFrame.insetBy(dx: -localMagnetismRadius, dy: -localMagnetismRadius)

        let rawDistance = hypot(targetCenter.x - endRaw.x, targetCenter.y - endRaw.y)
        let rectDistance = distanceFromPointToRect(endRaw, targetFrame)
        let rawInside = rawDistance <= localMagnetismRadius
        let rectInside = rectDistance <= localMagnetismRadius

        let snapBand = localSnapThreshold * 1.25
        let rectSnapBand = max(localSnapThreshold * 1.25, 10.0)

        var insideMagnetZone =
            expandedFrame.contains(state.position) ||
            distance <= localMagnetismRadius ||
            rawInside ||
            rectInside

        // --- 4) Robust crossing tests for the current target (add rectangular band) ---
        let crossedSnapZone = segmentIntersectsCircle(
            from: startRaw,
            to: endRaw,
            center: targetCenter,
            radius: localSnapThreshold
        )
        let crossedMagZone = segmentIntersectsCircle(
            from: startRaw,
            to: endRaw,
            center: targetCenter,
            radius: localMagnetismRadius
        )
        let crossedSnapBand = segmentIntersectsCircle(
            from: startRaw,
            to: endRaw,
            center: targetCenter,
            radius: snapBand
        )

        let tPadX = max(6.0, min(targetFrame.width * 0.22, 18.0))
        let tPadY = max(6.0, min(targetFrame.height * 0.60, 18.0))
        let expandedTarget = targetFrame.insetBy(dx: -tPadX, dy: -tPadY)
        let crossedRectBand = segmentIntersectsRect(from: startRaw, to: endRaw, rect: expandedTarget)

        let travelDX = endRaw.x - startRaw.x
        let travelDY = endRaw.y - startRaw.y
        let largeStepHit: Bool = {
            let stepSquared = travelDX * travelDX + travelDY * travelDY
            if stepSquared > (localMagnetismRadius * 2) * (localMagnetismRadius * 2) {
                let midPoint = CGPoint(x: (startRaw.x + endRaw.x) * 0.5, y: (startRaw.y + endRaw.y) * 0.5)
                return expandedTarget.contains(midPoint)
            }
            return false
        }()

        if crossedSnapZone || crossedMagZone || crossedSnapBand || crossedRectBand || largeStepHit {
            snapToTargetCenter(targetFrame: targetFrame, targetCenter: targetCenter)
            return
        }

        // --- 5) Keep lock frame fresh if already locked ---
        if isLockedToTarget { lockedMagneticTarget = targetFrame }

        // --- 6) Entering the magnet zone by any proxy -> snap & lock immediately ---
        if !isLockedToTarget && insideMagnetZone {
            snapToTargetCenter(targetFrame: targetFrame, targetCenter: targetCenter)
            return
        }

        // --- 7) Raw or rectangular snap band -> snap & lock ---
        if rawDistance <= snapBand || rectDistance <= rectSnapBand {
            snapToTargetCenter(targetFrame: targetFrame, targetCenter: targetCenter)
            return
        }

        // --- 8) Compute alignment & small pre-attraction for slow approach ---
        let speed = magnitude(of: state.velocity)
        let inputMagnitude = magnitude(of: state.lastInputDelta)
        var alignment = directionalAlignmentTowardTarget(
            targetVector: CGVector(dx: dx, dy: dy),
            velocityVector: speed > 1.0 ? state.velocity : nil,
            inputVector: inputMagnitude > 0.15 ? state.lastInputDelta : nil
        )

        if !insideMagnetZone,
           !isLockedToTarget,
           !state.isGliding,
           pendingSwitchTarget == nil {
            let assistOuter = max(localMagnetismRadius * 1.6, localSnapThreshold + 22.0)
            if distance > localMagnetismRadius && distance <= assistOuter {
                let alignForAssist = alignment ?? 0.3
                if alignForAssist > -0.5 {
                    let speedEase = max(0, min(1, 1 - speed / 165.0))
                    let microEase = max(0, min(1, 1 - inputMagnitude / 3.2))
                    let gate = max(speedEase, 0.35) * max(microEase, 0.45)
                    if gate > 0.05 {
                        let range = max(assistOuter - localMagnetismRadius, 1.0)
                        let proximity = max(0, min(1, (assistOuter - distance) / range))
                        let intensity = CGFloat(pow(Double(proximity), 1.25))
                        let basePull = min(localMagStrength * 0.55, 0.42)
                        let pull = basePull * intensity * gate
                        if pull > 0.0004 {
                            state.position.x += dx * pull
                            state.position.y += dy * pull

                            dx = targetCenter.x - state.position.x
                            dy = targetCenter.y - state.position.y
                            distance = hypot(dx, dy)
                            insideMagnetZone = expandedFrame.contains(state.position) ||
                                               distance <= localMagnetismRadius ||
                                               rawInside ||
                                               rectInside
                            alignment = directionalAlignmentTowardTarget(
                                targetVector: CGVector(dx: dx, dy: dy),
                                velocityVector: speed > 1.0 ? state.velocity : nil,
                                inputVector: inputMagnitude > 0.15 ? state.lastInputDelta : nil
                            )
                        }
                    }
                }
            }
        }

        // --- 9) HIGH-SPEED BRAKE (closest-approach; widened envelope) ---
        if speed > 70.0 {
            let centerSegDist = distanceFromPointToSegment(targetCenter, startRaw, endRaw)
            let approach = min(rawDistance, rectDistance, centerSegDist)
            if approach < localMagnetismRadius * 1.6 {
                let proximityBrake = max(0, 1 - approach / (localMagnetismRadius * 1.6))
                let speedBrake = max(0, min(1.0, (speed - 38.0) / 210.0))
                let brakeFactor = max(proximityBrake, 0.24) * speedBrake
                if brakeFactor > 0 {
                    let damping = max(0.03, 1.0 - 0.96 * brakeFactor)
                    state.velocity.dx *= damping
                    state.velocity.dy *= damping
                    state.lastInputDelta = CGVector(
                        dx: state.lastInputDelta.dx * damping,
                        dy: state.lastInputDelta.dy * damping
                    )

                    if brakeFactor > 0.32 {
                        let snapAssist = min(1.0, (brakeFactor - 0.2) * 1.9)
                        let snapWeight = 0.38 + snapAssist * 0.5
                        state.position.x += dx * snapWeight
                        state.position.y += dy * snapWeight
                        dx = targetCenter.x - state.position.x
                        dy = targetCenter.y - state.position.y
                        distance = hypot(dx, dy)
                        insideMagnetZone = expandedFrame.contains(state.position) ||
                                           distance <= localMagnetismRadius ||
                                           rawInside ||
                                           rectInside
                        alignment = directionalAlignmentTowardTarget(
                            targetVector: CGVector(dx: dx, dy: dy),
                            velocityVector: speed > 1.0 ? state.velocity : nil,
                            inputVector: inputMagnitude > 0.15 ? state.lastInputDelta : nil
                        )
                    }
                }
            }
        }

        // --- 10) Only now allow early-out if we're still outside by both raw and rect ---
        let updatedRawDistance = hypot(
            targetCenter.x - state.preMagnetPosition.x,
            targetCenter.y - state.preMagnetPosition.y
        )
        let updatedRectDistance = distanceFromPointToRect(state.preMagnetPosition, targetFrame)
        let updatedRawInside = updatedRawDistance <= localMagnetismRadius
        let updatedRectInside = updatedRectDistance <= localMagnetismRadius
        insideMagnetZone = insideMagnetZone || updatedRawInside || updatedRectInside

        if !insideMagnetZone && !updatedRawInside && !updatedRectInside {
            if isLockedToTarget {
                isLockedToTarget = false
                lockedMagneticTarget = nil
                resetLockStrainTracking()
            }
            return
        }

        // --- 11) Ensure we are locked once we cross the outside gate ---
        if !isLockedToTarget {
            isLockedToTarget = true
            lockedMagneticTarget = targetFrame
        }

        // --- 12) Glide snap: when gliding and close, snap hard and return ---
        let glideProximity = min(distance, rectDistance)
        if state.isGliding, glideProximity < localMagnetismRadius, speed > 35 {
            snapToTargetCenter(targetFrame: targetFrame, targetCenter: targetCenter)
            return
        }

        // --- 13) Near-center snap: make it unconditional and final ---
        if distance < localSnapThreshold {
            snapToTargetCenter(targetFrame: targetFrame, targetCenter: targetCenter)
            return
        }

        // --- 14) Otherwise apply outer-zone pull with alignment gating (as before) ---
        var escapeScale: CGFloat = 1.0
        let slowIntent = speed < 30.0 && inputMagnitude < 1.35
        if let a = alignment {
            let releaseAlignmentThreshold: CGFloat = -0.55
            let activationAlignment: CGFloat = 0.2

            if a <= releaseAlignmentThreshold {
                if isLockedToTarget {
                    isLockedToTarget = false
                    lockedMagneticTarget = nil
                    resetLockStrainTracking()
                }
                return
            }

            if a <= 0 {
                if slowIntent && a > -0.4 {
                    let softened = max(0, 1 + a / 0.4)
                    escapeScale = 0.08 * softened
                } else {
                    escapeScale = 0
                }
            } else if a < activationAlignment {
                let normalized = a / activationAlignment
                let base = slowIntent ? 0.22 : 0.12
                escapeScale = max(0, normalized * normalized * base)
            } else {
                let normalized = (a - activationAlignment) / (1.0 - activationAlignment)
                let base = slowIntent ? 0.25 : 0.15
                escapeScale = min(1.0, base + normalized * (1.0 - base))
            }
        }

        if distance > 0 && escapeScale > 0 {
            let baseProximity = max(0, 1 - distance / localMagnetismRadius)
            let shaped = CGFloat(pow(Double(baseProximity), 1.18))
            let pull = localMagStrength * (0.18 + shaped * 0.92)
            let speedMult = min(1.0 + (speed / maxMomentumSpeed) * 0.72 + baseProximity * 0.6, 1.9)
            let adjusted = pull * speedMult * escapeScale

            state.position.x += dx * adjusted
            state.position.y += dy * adjusted

            let dampen = max(0.08, 1.0 - (pull * 1.05 * escapeScale))
            state.velocity.dx *= dampen
            state.velocity.dy *= dampen
        }

        if escapeScale <= 0 {
            if isLockedToTarget {
                isLockedToTarget = false
                lockedMagneticTarget = nil
                resetLockStrainTracking()
            }
            return
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
        rawFreshThisFrame = false
        let decayFactor = max(0, 1 - glideDecayPerSecond * deltaTime)
        state.velocity.dx *= decayFactor
        state.velocity.dy *= decayFactor

        let momentumDelta = CGVector(dx: state.velocity.dx * deltaTime, dy: state.velocity.dy * deltaTime)
        state.previousPosition = state.position
        state.position.x += momentumDelta.dx
        state.position.y += momentumDelta.dy
        state.lastInputDelta = momentumDelta
        state.previousPreMagnetPosition = state.preMagnetPosition
        state.preMagnetPosition = state.position

        rawFreshThisFrame = true

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

    /// Clears any cached magnetism targets and lock state.
    private func resetMagnetismState() {
        currentMagneticTarget = nil
        lockedMagneticTarget = nil
        isLockedToTarget = false
        pendingSwitchTarget = nil
        pendingSwitchConfidence = 0
        lastSeenCandidate = nil
        lastSeenCandidateTTL = 0
        rawFreshThisFrame = false
        resetLockStrainTracking()
    }

    private func resetLockStrainTracking() {
        lockStrainCounter = 0
        lockStrainTarget = nil
    }

    private func evaluateLockStrain(
        for lockedTarget: CGRect,
        startRaw: CGPoint,
        endRaw: CGPoint
    ) {
        if let existing = lockStrainTarget, !framesAreEquivalent(existing, lockedTarget) {
            resetLockStrainTracking()
        }
        lockStrainTarget = lockedTarget

        let delta = CGVector(dx: endRaw.x - startRaw.x, dy: endRaw.y - startRaw.y)
        let deltaMagnitude = hypot(delta.dx, delta.dy)

        if deltaMagnitude < 2.2 {
            lockStrainCounter = max(lockStrainCounter - 1, 0)
            return
        }

        let center = CGPoint(x: lockedTarget.midX, y: lockedTarget.midY)
        let fromCenter = CGVector(dx: endRaw.x - center.x, dy: endRaw.y - center.y)
        let movingAway = (delta.dx * fromCenter.dx + delta.dy * fromCenter.dy) > 0
        if !movingAway {
            lockStrainCounter = max(lockStrainCounter - 1, 0)
            return
        }

        let minorAxis = max(min(lockedTarget.width, lockedTarget.height), 1.0)
        let majorAxis = max(lockedTarget.width, lockedTarget.height)
        let aspectRatio = majorAxis / minorAxis
        // Match the threshold from the main escape logic
        if aspectRatio <= 1.8 || minorAxis >= 110.0 {
            lockStrainCounter = max(lockStrainCounter - 1, 0)
            return
        }

        // Match main escape logic: check direction based on element orientation
        let isVertical = lockedTarget.height > lockedTarget.width
        let isHorizontal = lockedTarget.width > lockedTarget.height

        var hasDirectionalIntent = false
        if isVertical {
            // Vertical sidebar: check for horizontal movement
            hasDirectionalIntent = abs(delta.dx) > abs(delta.dy) * 0.9 && abs(delta.dx) > 2.5
        } else if isHorizontal {
            // Horizontal toolbar: check for vertical movement
            hasDirectionalIntent = abs(delta.dy) > abs(delta.dx) * 0.9 && abs(delta.dy) > 2.5
        }

        if !hasDirectionalIntent {
            lockStrainCounter = max(lockStrainCounter - 1, 0)
            return
        }

        let distanceFromCenter = hypot(fromCenter.dx, fromCenter.dy)
        let lockedParams = magneticParameters(for: lockedTarget)
        let distanceThreshold = max(minorAxis * 0.38, lockedParams.snap * 0.6, 16.0)
        if distanceFromCenter < distanceThreshold {
            lockStrainCounter = max(lockStrainCounter - 1, 0)
            return
        }

        lockStrainCounter += 1

        // Unlock faster for stuck situations (reduced from 4 to 3 frames)
        if lockStrainCounter >= 3 {
            if enableMagnetismLogging {
                logMagnetism("Force-unlocking stuck magnetism (strain \(lockStrainCounter))")
            }
            isLockedToTarget = false
            lockedMagneticTarget = nil
            resetLockStrainTracking()
            if let candidate = lastSeenCandidate {
                currentMagneticTarget = candidate
            }
        }
    }

    private func snapToTargetCenter(targetFrame: CGRect, targetCenter: CGPoint) {
        currentMagneticTarget = targetFrame
        isLockedToTarget = true
        lockedMagneticTarget = targetFrame
        pendingSwitchTarget = nil
        pendingSwitchConfidence = 0
        lastSeenCandidate = targetFrame
        resetLockStrainTracking()
        lockStrainTarget = targetFrame

        if enableDimensionLogging {
            let w = targetFrame.width
            let h = targetFrame.height
            let aspect = max(w, h) / max(min(w, h), 1.0)
            print("[Magnes] LOCKED to target: w=\(Int(w)) h=\(Int(h)) aspect=\(String(format: "%.2f", aspect))")
        }

        state.position = targetCenter
        state.previousPosition = targetCenter
        state.velocity = .zero
        state.lastInputDelta = .zero
        state.previousPreMagnetPosition = targetCenter
        state.preMagnetPosition = targetCenter

        setGliding(false)
        syncSystemCursorToVirtualPosition()
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
        let minorAxis = max(min(frame.width, frame.height), 1.0)
        let majorAxis = max(frame.width, frame.height)
        let aspectRatio = majorAxis / minorAxis
        let normalized = min(max(minorAxis / 110.0, 0.22), 1.0)

        var radius = magnetismRadius * normalized * 1.05
        radius = max(radius, minorAxis * 0.85)
        radius = min(radius, minorAxis * 1.8 + 18.0)

        var snap = snapThreshold * normalized * 0.9
        snap = max(snap, minorAxis * 0.55)
        snap = max(snap, 12.0)

        var strength = magneticStrength * (0.66 + normalized * 0.5)
        strength = min(max(strength, 0.4), magneticStrength * 1.12)

        if aspectRatio > 2.4 {
            let reduction = min(0.6, (aspectRatio - 2.4) * 0.12)
            radius *= (1.0 - reduction)
            snap *= (1.0 - reduction * 0.85)
            strength *= max(0.55, 1.0 - reduction * 0.9)
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

    private func distanceFromPointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let ap = CGVector(dx: p.x - a.x, dy: p.y - a.y)
        let ab2 = ab.dx * ab.dx + ab.dy * ab.dy
        if ab2 == 0 { return hypot(ap.dx, ap.dy) }
        var t = (ap.dx * ab.dx + ap.dy * ab.dy) / ab2
        if t < 0 { t = 0 } else if t > 1 { t = 1 }
        let proj = CGPoint(x: a.x + ab.dx * t, y: a.y + ab.dy * t)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    private func interceptRawStepIfCrossing(from startRaw: CGPoint, to endRaw: CGPoint) -> Bool {
        var targets: [CGRect] = []
        if let target = lockedMagneticTarget {
            targets.append(target)
        }
        if let target = currentMagneticTarget,
           !targets.contains(where: { framesAreEquivalent($0, target) }) {
            targets.append(target)
        }
        if let target = lastSeenCandidate,
           !targets.contains(where: { framesAreEquivalent($0, target) }) {
            targets.append(target)
        }

        guard !targets.isEmpty else { return false }

        let travel = CGVector(dx: endRaw.x - startRaw.x, dy: endRaw.y - startRaw.y)

        for target in targets {
            let center = CGPoint(x: target.midX, y: target.midY)
            let params = magneticParameters(for: target)
            let snapBand = params.snap * 1.5
            let padX = max(6.0, min(target.width * 0.22, 18.0))
            let padY = max(6.0, min(target.height * 0.60, 18.0))
            let expanded = target.insetBy(dx: -padX, dy: -padY)

            let toCenter = CGVector(dx: center.x - startRaw.x, dy: center.y - startRaw.y)
            let movingToward = (travel.dx * toCenter.dx + travel.dy * toCenter.dy) > 0

            let crosses =
                segmentIntersectsRect(from: startRaw, to: endRaw, rect: expanded) ||
                segmentIntersectsCircle(from: startRaw, to: endRaw, center: center, radius: snapBand) ||
                distanceFromPointToSegment(center, startRaw, endRaw) <= snapBand

            if movingToward && crosses {
                snapToTargetCenter(targetFrame: target, targetCenter: center)
                return true
            }
        }

        return false
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

    private func distanceFromPointToRect(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func segmentIntersectsRect(from start: CGPoint, to end: CGPoint, rect: CGRect) -> Bool {
        if rect.contains(start) || rect.contains(end) {
            return true
        }

        let edges: [(CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY))
        ]

        for (p, q) in edges {
            if segmentsIntersect(start, end, p, q) {
                return true
            }
        }

        return false
    }

    private func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> Bool {
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        let d1 = cross(p1, p2, q1)
        let d2 = cross(p1, p2, q2)
        let d3 = cross(q1, q2, p1)
        let d4 = cross(q1, q2, p2)

        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
            ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }

        if d1 == 0 && d2 == 0 && d3 == 0 && d4 == 0 {
            let minx1 = min(p1.x, p2.x), maxx1 = max(p1.x, p2.x)
            let miny1 = min(p1.y, p2.y), maxy1 = max(p1.y, p2.y)
            let minx2 = min(q1.x, q2.x), maxx2 = max(q1.x, q2.x)
            let miny2 = min(q1.y, q2.y), maxy2 = max(q1.y, q2.y)
            let overlapX = max(minx1, minx2) <= min(maxx1, maxx2)
            let overlapY = max(miny1, miny2) <= min(maxy1, maxy2)
            return overlapX && overlapY
        }

        return false
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

    /// Emits magnetism debug logs when enabled.
    private func logMagnetism(_ message: String) {
        guard enableMagnetismLogging else { return }
        onLogMessage?("[Magnetism] \(message)")
    }

    /// Updates the glide flag and notifies observers when the glide state changes.
    private func setGliding(_ newValue: Bool) {
        guard state.isGliding != newValue else { return }
        state.isGliding = newValue
        onGlideStateChange?(newValue)
    }
}
