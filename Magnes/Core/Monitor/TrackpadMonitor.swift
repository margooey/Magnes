//
//  TrackpadMonitor.swift
//  Magnes
//
//  Created by margooey on 10/25/25.
//

import OpenMultitouchSupport
import CoreGraphics
import Foundation

/// Listens to the OpenMultitouch stream and exposes high-level touch metrics (presence, centroid, velocity).
/// Also notifies observers when touches start/stop.
class TrackpadMonitor {
    private let omsManager = OMSManager.shared
    private var listenerStarted = false
    private var isTouching = false
    private var latestPositions: [CGPoint] = []
    private var lastLoggedTouchState = false
    private var hasLoggedState = false
    private var latestCentroid: CGPoint?
    private var previousCentroid: CGPoint?
    private var lastSampleTimestamp: CFTimeInterval = 0
    private var normalizedVelocity: CGVector = .zero
    private let velocitySmoothing: CGFloat = 0.35
    private let enableLogging = false
    private var multiFingerSuppressionDeadline: CFTimeInterval = 0
    private let multiFingerSuppressionDuration: CFTimeInterval = 0.15 // window to keep glide disabled after multi-touch
    var onTouchStateChange: ((Bool) -> Void)?

    /// Ensures the OMS stream is started once and continuously consumes touch frames.
    private func initialize() {
        guard !listenerStarted else { return }
        listenerStarted = true
        Task { [weak self, omsManager] in
            for await touches in omsManager.touchDataStream {
                guard let self = self else { continue }
                // Map to normalized CGPoints in [0,1]
                let positions = touches.map { touch in
                    CGPoint(
                        x: CGFloat(touch.position.x),
                        y: CGFloat(touch.position.y)
                    )
                }
                self.latestPositions = positions
                let now = CFAbsoluteTimeGetCurrent()
                if touches.count > 1 {
                    self.multiFingerSuppressionDeadline = now + self.multiFingerSuppressionDuration
                }
                // If any touch is in a touching/making/breaking/lingering state, mark touching
                let touching = touches.contains { touch in
                    switch touch.state {
                    case .notTouching, .hovering:
                        return false
                    default:
                        return true
                    }
                }
                self.updateTouchingState(touching)
                self.updateTouchMetrics(with: positions)
            }
        }
        omsManager.startListening()
    }

    /// Public entry point to guarantee the stream is active.
    func startMonitoring() {
        initialize()
    }

    /// Optional logging hook; keeps historical behaviour intact.
    func monitorTouches() {
        initialize()
        if hasLoggedState && isTouching == lastLoggedTouchState {
            return
        }
        hasLoggedState = true
        lastLoggedTouchState = isTouching
        guard enableLogging else { return }
        if isTouching {
            let formatted = latestPositions.map { p in
                String(format: "(%.2f, %.2f)", p.x, p.y)
            }.joined(separator: ", ")
            print("[Magnes] Trackpad: TOUCHING at positions: [\(formatted)]")
        } else {
            print("[Magnes] Trackpad: not touching")
        }
    }

    func isTrackpadTouching() -> Bool {
        initialize()
        return isTouching
    }

    /// Latest normalized positions (0-1) for each finger.
    func currentTouchPositions() -> [CGPoint] {
        initialize()
        return latestPositions
    }

    /// Latest centroid (average) of touch points, if any.
    func currentTouchCentroid() -> CGPoint? {
        initialize()
        return latestCentroid
    }

    /// Returns smoothed velocity derived from centroid changes while touching.
    func currentNormalizedVelocity() -> CGVector? {
        initialize()
        guard isTouching else { return nil }
        return normalizedVelocity
    }

    /// True when a recent multi-touch gesture should suppress glide.
    func shouldSuppressGlideForRecentMultiTouch() -> Bool {
        initialize()
        return CFAbsoluteTimeGetCurrent() < multiFingerSuppressionDeadline
    }

    /// Tracks state transitions and notifies listeners on the main queue.
    private func updateTouchingState(_ newValue: Bool) {
        let previous = isTouching
        isTouching = newValue
        guard previous != newValue else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onTouchStateChange?(newValue)
        }
    }

    /// Updates centroid and velocity calculations from the latest touch frame.
    /// Steps:
    /// 1. Early-out when there are no touches, resetting cached values.
    /// 2. Compute the centroid by averaging positions.
    /// 3. Derive raw velocity (delta / dt) and blend with previous velocity using exponential smoothing.
    private func updateTouchMetrics(with positions: [CGPoint]) {
        let timestamp = CFAbsoluteTimeGetCurrent()
        guard !positions.isEmpty else {
            latestCentroid = nil
            previousCentroid = nil
            normalizedVelocity = .zero
            lastSampleTimestamp = timestamp
            return
        }

        var centroid = positions.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let divisor = CGFloat(positions.count)
        centroid.x /= divisor
        centroid.y /= divisor

        latestCentroid = centroid
        if let previous = previousCentroid, lastSampleTimestamp > 0 {
            let deltaTime = max(timestamp - lastSampleTimestamp, 1.0 / 500.0)
            let rawVelocity = CGVector(
                dx: (centroid.x - previous.x) / CGFloat(deltaTime),
                dy: (centroid.y - previous.y) / CGFloat(deltaTime)
            )
            normalizedVelocity = CGVector(
                dx: normalizedVelocity.dx * (1 - velocitySmoothing) + rawVelocity.dx * velocitySmoothing,
                dy: normalizedVelocity.dy * (1 - velocitySmoothing) + rawVelocity.dy * velocitySmoothing
            )
        } else {
            normalizedVelocity = .zero
        }

        previousCentroid = centroid
        lastSampleTimestamp = timestamp
    }
}
