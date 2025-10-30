//
//  CursorUpdateLoop.swift
//  Magnes
//
//  Created by margooey on 11/24/24.
//

import Foundation

/// Encapsulates the high-frequency timer that drives cursor updates.
/// Keeps `CursorController` free from timer bookkeeping.
final class CursorUpdateLoop {
    private let interval: TimeInterval
    private let tick: () -> Void
    private var timer: Timer?

    /// `frequency` is expressed in Hz (ticks per second); we convert to a `TimeInterval`.
    init(frequency: TimeInterval, tick: @escaping () -> Void) {
        self.interval = 1.0 / frequency
        self.tick = tick
    }

    /// Starts (or restarts) the timer on the main run loop.
    /// A prior timer is invalidated to avoid multiple instances running concurrently.
    func start() {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops the timer if it is currently running.
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
