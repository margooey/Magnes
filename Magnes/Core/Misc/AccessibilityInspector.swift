//
//  Element.swift
//  Magnes
//
//  Created by margooey on 5/27/25.
//

import ApplicationServices
import Cocoa

private let axFrameAttribute: CFString = "AXFrame" as CFString

/// Snapshot of an accessibility element's geometry and role metadata.
struct AccessibilityElementInfo {
    let frame: CGRect
    let role: String?
}

/// Thin wrapper around the Accessibility APIs used by the cursor to query role and bounds data.
final class AccessibilityInspector {
    /// Returns the accessibility element under the given screen coordinate with frame and optional role.
    func elementInfo(at screenPoint: CGPoint) -> AccessibilityElementInfo? {
        guard let element = element(at: screenPoint),
              let frame = elementFrame(element) else {
            return nil
        }

        var roleValue: CFTypeRef?
        var role: String?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success {
            role = roleValue as? String
        }

        return AccessibilityElementInfo(frame: frame, role: role)
    }

    /// Finds the accessibility element at a point (converted to bottom-left origin used by AX).
    private func element(at point: CGPoint) -> AXUIElement? {
        var location = point
        if let screenHeight = NSScreen.main?.frame.height {
            location.y = screenHeight - location.y
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWideElement, Float(location.x), Float(location.y), &element)
        return result == .success ? element : nil
    }

    /// Reads the `AXFrame` attribute for the given element, ensuring the value is a valid `AXValue`.
    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, axFrameAttribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let rectValue = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(rectValue) == .cgRect else {
            return nil
        }

        var frame = CGRect.zero
        AXValueGetValue(rectValue, .cgRect, &frame)
        return frame
    }
}
