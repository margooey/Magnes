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
    let actionNames: [String]
    let url: URL?
    let bundleIdentifier: String?
    let isFilePickerPanel: Bool
}

/// Thin wrapper around the Accessibility APIs used by the cursor to query role and bounds data.
final class AccessibilityInspector {
    /// Returns the accessibility element under the given screen coordinate with frame and optional role.
    func elementInfo(at screenPoint: CGPoint) -> AccessibilityElementInfo? {
        guard let element = element(at: screenPoint),
              let frame = elementFrame(element) else {
            return nil
        }

        let role = extractRole(from: element)
        let actions = extractActionNames(from: element)
        let url = extractURL(from: element)
        let bundleIdentifier = applicationBundleIdentifier(for: element)
        let isFilePickerPanel = detectOpenSavePanel(for: element)

        return AccessibilityElementInfo(
            frame: frame,
            role: role,
            actionNames: actions,
            url: url,
            bundleIdentifier: bundleIdentifier,
            isFilePickerPanel: isFilePickerPanel
        )
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

    /// Extracts the role attribute as a Swift `String` if available.
    private func extractRole(from element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success else {
            return nil
        }
        return roleValue as? String
    }

    /// Returns the list of supported AX action names (e.g. `AXPress`) for the element.
    private func extractActionNames(from element: AXUIElement) -> [String] {
        var actionValue: CFArray?
        guard AXUIElementCopyActionNames(element, &actionValue) == .success,
              let cfArray = actionValue as? [Any] else {
            return []
        }

        return cfArray.compactMap { $0 as? String }
    }

    /// Extracts a URL attached to the element, if any.
    private func extractURL(from element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let unwrapped = value else {
            return nil
        }

        if CFGetTypeID(unwrapped) == CFURLGetTypeID() {
            let cfURL = unsafeBitCast(unwrapped, to: CFURL.self)
            return cfURL as URL
        }

        if let urlString = unwrapped as? String {
            return URL(string: urlString)
        }

        return nil
    }

    /// Attempts to derive the bundle identifier owning the given element, walking up the parent chain if needed.
    private func applicationBundleIdentifier(for element: AXUIElement, depth: Int = 0) -> String? {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid),
           let bundleIdentifier = app.bundleIdentifier {
            return bundleIdentifier
        }

        guard depth < 6, let parent = parent(of: element) else {
            return nil
        }
        return applicationBundleIdentifier(for: parent, depth: depth + 1)
    }

    /// Determines whether the element belongs to the system Open/Save panel.
    private func detectOpenSavePanel(for element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 12 {
            if let roleDescription = stringAttribute(kAXRoleDescriptionAttribute as CFString, of: node)?.lowercased(),
               roleDescription.contains("open dialog") ||
               roleDescription.contains("save dialog") {
               return true
           }

            if let subrole = stringAttribute(kAXSubroleAttribute as CFString, of: node),
               subrole == (kAXSystemDialogSubrole as String) {
               return true
           }

            if let title = stringAttribute(kAXTitleAttribute as CFString, of: node)?.lowercased(),
               title == "open" || title == "save" || title == "export" {
                return true
            }

            current = parent(of: node)
            depth += 1
        }
        return false
    }

    /// Returns the accessibility parent of an element, if available.
    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeBitCast(rawValue, to: AXUIElement.self)
        return element
    }

    /// Convenience helper to read string-based attributes from an AX element.
    private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let rawValue = value else {
            return nil
        }
        if CFGetTypeID(rawValue) == CFStringGetTypeID() {
            return rawValue as? String
        }
        return nil
    }
}
