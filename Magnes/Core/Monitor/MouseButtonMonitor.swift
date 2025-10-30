//
//  MouseButtonMonitor.swift
//  Magnes
//
//  Created by margooey on 11/24/24.
//

import AppKit

/// Centralizes NSEvent monitor lifecycle and reports button state transitions to its caller.
final class MouseButtonMonitor {
    var onStateChange: ((Bool) -> Void)?

    private var eventMonitors: [Any] = []
    private var pressedButtons: Set<Int> = []

    /// Installs global and local event monitors for mouse button up/down events.
    /// Both monitors are used so we capture clicks even when the app is active or backgrounded.
    func start() {
        guard eventMonitors.isEmpty else { return }

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp
        ]

        // Global monitor: receives events regardless of first responder chain.
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouseButtonEvent(event)
        }) {
            eventMonitors.append(globalMonitor)
        }

        // Local monitor: ensures events still flow to the app while we inspect them.
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouseButtonEvent(event)
            return event
        }) {
            eventMonitors.append(localMonitor)
        }
    }

    /// Removes monitors and clears state so the cursor animation returns to idle.
    func stop() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        pressedButtons.removeAll()
        notifyStateChange()
    }

    /// Normalizes threading so downstream handlers always run on the main queue.
    private func handleMouseButtonEvent(_ event: NSEvent) {
        let processEvent: () -> Void = { [weak self] in
            guard let self else { return }
            self.processMouseButtonEvent(buttonNumber: Int(event.buttonNumber), eventType: event.type)
        }

        if Thread.isMainThread {
            processEvent()
        } else {
            DispatchQueue.main.async(execute: processEvent)
        }
    }

    /// Tracks the set of pressed buttons and notifies listeners.
    private func processMouseButtonEvent(buttonNumber: Int, eventType: NSEvent.EventType) {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressedButtons.insert(buttonNumber)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pressedButtons.remove(buttonNumber)
        default:
            break
        }
        notifyStateChange()
    }

    /// Emits the aggregated press state (true if any button remains down).
    private func notifyStateChange() {
        onStateChange?(!pressedButtons.isEmpty)
    }
}
