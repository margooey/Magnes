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

    private var state = State()
    private var desktopBounds: CGRect = .null
    private var lastPhysicalMousePosition: CGPoint = .zero

    var onLogMessage: ((String) -> Void)?
    var onGlideStateChange: ((Bool) -> Void)?

    init(
        glideDecayPerSecond: CGFloat = 6.5,
        minimumGlideVelocity: CGFloat = 220.0,
        glideStopSpeedMultiplier: CGFloat = 0.45,
        trackpadVelocityGain: CGFloat = 0.95,
        maxMomentumSpeed: CGFloat = 9000.0,
        enableGlideLogging: Bool = false
    ) {
        self.glideDecayPerSecond = glideDecayPerSecond
        self.minimumGlideVelocity = minimumGlideVelocity
        self.glideStopSpeedMultiplier = glideStopSpeedMultiplier
        self.trackpadVelocityGain = trackpadVelocityGain
        self.maxMomentumSpeed = maxMomentumSpeed
        self.enableGlideLogging = enableGlideLogging
    }

    var position: CGPoint { state.position }
    var isGlidingActive: Bool { state.isGliding }

    /// Seeds the virtual cursor state with the current system mouse position.
    /// Called on startup so the virtual cursor begins in sync with the visible pointer.
    func prime(with physicalPosition: CGPoint) {
        state = State(position: physicalPosition)
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
        lastPhysicalMousePosition = physicalLocation
        state.velocity = .zero
        setGliding(false)
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

        state.position.x += state.velocity.dx * deltaTime
        state.position.y += state.velocity.dy * deltaTime
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
