import ApplicationServices
import Cocoa
import CoreFoundation

/// Snapshot of an accessibility element's geometry and role metadata.
struct AccessibilityElementInfo {
    let element: AXUIElement
    let frame: CGRect
    let role: String?
    let subrole: String?
    let label: String?
    let enabled: Bool
    let supportsPress: Bool
    let inCollection: Bool
}

/// Wrapper around the Accessibility API that fetches interactive UI elements for the cursor layer.
final class AccessibilityInspector {
    private let systemWideElement = AXUIElementCreateSystemWide()

    /// Returns the most relevant accessibility metadata for the point under the cursor.
    func elementInfo(at point: CGPoint) -> AccessibilityElementInfo? {
        if let element = element(at: point) {
            return AccessibilityElementInfo(
                element: element.element,
                frame: element.frame,
                role: element.role,
                subrole: element.subrole,
                label: element.label,
                enabled: element.enabled,
                supportsPress: element.supportsPress,
                inCollection: element.inCollection
            )
        }

        guard let rawElement = captureElement(at: point),
              let frame = rawElement.frameOrUnion()
        else {
            return nil
        }

        return AccessibilityElementInfo(
            element: rawElement,
            frame: frame,
            role: rawElement.attributeString(for: AXAttribute.role),
            subrole: rawElement.attributeString(for: AXAttribute.subrole),
            label: rawElement.attributeString(for: AXAttribute.title)
                ?? rawElement.attributeString(for: AXAttribute.description),
            enabled: rawElement.attributeBool(for: AXAttribute.enabled) ?? true,
            supportsPress: rawElement.supportsPress(),
            inCollection: rawElement.isWithinCollectionContainer()
        )
    }

    /// Returns an interactive accessibility element at the given screen coordinate.
    func element(at point: CGPoint) -> AccessibilityElement? {
        guard let rawElement = captureElement(at: point) else { return nil }
        return makeElement(from: rawElement)
    }

    /// Samples a grid around the point to find nearby interactive elements.
    func elements(around point: CGPoint, radius: CGFloat) -> [AccessibilityElement] {
        let step: CGFloat = max(min(radius / 6.0, 16.0), 8.0)
        var visited = Set<Int>()
        var results: [AccessibilityElement] = []

        stride(from: -radius, through: radius, by: step).forEach { dx in
            stride(from: -radius, through: radius, by: step).forEach { dy in
                let samplePoint = CGPoint(x: point.x + dx, y: point.y + dy)
                guard let rawElement = captureElement(at: samplePoint) else { return }
                let identifier = Int(bitPattern: CFHash(rawElement))
                if visited.insert(identifier).inserted,
                   let element = makeElement(from: rawElement) {
                    results.append(element)
                }
            }
        }

        let uniqueResults = Array(Set(results))
        return uniqueResults.sorted(by: { $0.priority > $1.priority })
    }

    /// Walks up the hierarchy near the given point and returns siblings if enough interactive children exist.
    func siblingsNear(_ point: CGPoint, minCount: Int = 3, maxDepth: Int = 4) -> [AccessibilityElement] {
        var node = captureElement(at: point)
        var depth = 0
        while let element = node, depth < maxDepth {
            let children = element.children()
            let interactive = children.compactMap { makeElement(from: $0) }
            let enabledElements = interactive.filter { $0.enabled }
            let uniqueElements = Set(enabledElements)
            if uniqueElements.count >= minCount {
                return uniqueElements.sorted(by: { $0.priority > $1.priority })
            }
            node = element.parent()
            depth += 1
        }
        return []
    }

    /// Determines whether the hit element participates in a menu hierarchy from the point upward.
    func isInMenuHierarchy(at point: CGPoint) -> Bool {
        guard let hit = captureElement(at: point) else { return false }
        var node: AXUIElement? = hit
        var depth = 0
        while let element = node, depth < 8 {
            let role = element.attributeString(for: AXAttribute.role)
            if role == AXRole.menu || role == AXRole.menuItem || role == AXRole.menuBar {
                return true
            }
            node = element.parent()
            depth += 1
        }
        return false
    }

    private func captureElement(at point: CGPoint) -> AXUIElement? {
        var rawElement: AXUIElement?
        let location = convertToAXCoordinate(point)
        let status = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(location.x),
            Float(location.y),
            &rawElement
        )
        guard status == .success else { return nil }
        return rawElement
    }

    private func convertToAXCoordinate(_ point: CGPoint) -> CGPoint {
        let screenBounds = CGGeometry.aggregateScreenBounds()
        return CGPoint(x: point.x, y: screenBounds.maxY - point.y)
    }

    private func makeElement(from rawElement: AXUIElement) -> AccessibilityElement? {
        guard let chosen = rawElement.promoteToInteractive() else { return nil }
        guard let frame = chosen.frameOrUnion() else { return nil }

        let role = chosen.attributeString(for: AXAttribute.role)
        let subrole = chosen.attributeString(for: AXAttribute.subrole)
        let label = chosen.attributeString(for: AXAttribute.title)
            ?? chosen.attributeString(for: AXAttribute.description)
        let enabled = chosen.attributeBool(for: AXAttribute.enabled) ?? true
        let supportsPress = chosen.supportsPress()
        let inCollection = chosen.isWithinCollectionContainer()

        guard AccessibilityElement.isInteractive(
            role: role,
            subrole: subrole,
            supportsPress: supportsPress,
            inCollection: inCollection
        ) else {
            return nil
        }

        return AccessibilityElement(
            element: chosen,
            frame: frame,
            role: role,
            subrole: subrole,
            label: label,
            enabled: enabled,
            supportsPress: supportsPress,
            inCollection: inCollection
        )
    }
}

struct AccessibilityElement: Hashable {
    let element: AXUIElement
    let frame: CGRect
    let role: String?
    let subrole: String?
    let label: String?
    let enabled: Bool
    let supportsPress: Bool
    let inCollection: Bool

    var priority: Int {
        if subrole == AXSubrole.closeButton { return 3 }
        if role == AXRole.button { return 2 }
        if role == AXRole.link { return 2 }
        if role == AXRole.textField { return 1 }
        if supportsPress { return 1 }
        if inCollection { return 1 }
        return 0
    }

    static func isInteractive(role: String?, subrole: String?, supportsPress: Bool, inCollection: Bool) -> Bool {
        guard let role else { return false }
        switch role {
        case AXRole.button,
             AXRole.link,
             AXRole.radioButton,
             AXRole.checkBox,
             AXRole.textField,
             AXRole.popUpButton:
            return true
        case AXRole.group,
             AXRole.list,
             AXRole.listItem,
             AXRole.row,
             AXRole.cell,
             AXRole.staticText:
            return supportsPress || inCollection
        default:
            break
        }

        if subrole == AXSubrole.closeButton { return true }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Int(bitPattern: CFHash(element)))
    }

    static func == (lhs: AccessibilityElement, rhs: AccessibilityElement) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

private extension AXUIElement {
    var frame: CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, AXAttribute.frame, &value) == .success,
              let cfValue = value,
              CFGetTypeID(cfValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = cfValue as! AXValue
        var rect = CGRect.zero
        AXValueGetValue(axValue, .cgRect, &rect)
        return rect
    }

    func attributeString(for attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute, &value) == .success else { return nil }
        return value as? String
    }

    func attributeBool(for attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute, &value) == .success else { return nil }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    func parent() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, AXAttribute.parent, &value) == .success,
              let unwrapped = value
        else {
            return nil
        }
        guard CFGetTypeID(unwrapped) == AXUIElementGetTypeID() else {
            return nil
        }
        return (unwrapped as! AXUIElement)
    }

    func children() -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, AXAttribute.children, &value) == .success,
              let unwrapped = value
        else {
            return []
        }
        if let elements = unwrapped as? [AXUIElement] {
            return elements
        }
        if CFGetTypeID(unwrapped) == CFArrayGetTypeID() {
            let cfArray = unwrapped as! CFArray
            var results: [AXUIElement] = []
            let count = CFArrayGetCount(cfArray)
            for index in 0..<count {
                let rawValue = CFArrayGetValueAtIndex(cfArray, index)
                let cfValue = unsafeBitCast(rawValue, to: CFTypeRef.self)
                guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { continue }
                let element = unsafeBitCast(cfValue, to: AXUIElement.self)
                results.append(element)
            }
            return results
        }
        return []
    }

    func actionNames() -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(self, &value) == .success,
              let names = value as? [String]
        else {
            return []
        }
        return names
    }

    func supportsPress() -> Bool {
        actionNames().contains(AXActionName.press as String)
    }

    func isWithinCollectionContainer(maxDepth: Int = 4) -> Bool {
        var current = parent()
        var depth = 0
        while let element = current, depth < maxDepth {
            if let role = element.attributeString(for: AXAttribute.role),
               role == AXRole.table ||
               role == AXRole.outline ||
               role == AXRole.collection ||
               role == AXRole.list {
                return true
            }
            current = element.parent()
            depth += 1
        }
        return false
    }

    /// Walks up the hierarchy to find a press-capable or control-role ancestor with a usable frame.
    func promoteToInteractive(maxDepth: Int = 6) -> AXUIElement? {
        var current: AXUIElement? = self
        for _ in 0..<maxDepth {
            guard let element = current else { return nil }

            if element.supportsPress(), element.frameOrUnion() != nil {
                return element
            }

            if let role = element.attributeString(for: AXAttribute.role),
               (role == AXRole.button ||
                role == AXRole.link ||
                role == AXRole.popUpButton ||
                role == AXRole.textField),
               element.frameOrUnion() != nil {
                return element
            }

            if element.attributeString(for: AXAttribute.role) == AXRole.webArea {
                return nil
            }

            current = element.parent()
        }

        return nil
    }

    /// Returns the element's frame, or the union of its child frames when a direct frame is unavailable.
    func frameOrUnion() -> CGRect? {
        if let f = frame, f.isUsableFrame { return f }

        let bounds = CGGeometry.aggregateScreenBounds()
        let rects = children()
            .compactMap { $0.frame }
            .filter { $0.isUsableFrame }
            .map { $0.intersection(bounds) }
            .filter { !$0.isNull && $0.isUsableFrame }

        guard var union = rects.first else { return nil }
        for rect in rects.dropFirst() {
            union = union.union(rect)
        }

        let screenArea = bounds.width * bounds.height
        guard screenArea > 0 else { return union }

        let unionArea = union.width * union.height
        return unionArea / screenArea < 0.35 ? union : nil
    }
}

// MARK: - AX Constants

private enum AXAttribute {
    static let role: CFString = "AXRole" as CFString
    static let subrole: CFString = "AXSubrole" as CFString
    static let title: CFString = "AXTitle" as CFString
    static let description: CFString = "AXDescription" as CFString
    static let enabled: CFString = "AXEnabled" as CFString
    static let frame: CFString = "AXFrame" as CFString
    static let parent: CFString = "AXParent" as CFString
    static let children: CFString = "AXChildren" as CFString
}

private enum CGGeometry {
    static func aggregateScreenBounds() -> CGRect {
        var bounds = CGRect.null
        for screen in NSScreen.screens {
            bounds = bounds.union(screen.frame)
        }
        return bounds
    }
}

private extension CGRect {
    var isFiniteRect: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }

    var isUsableFrame: Bool {
        isFiniteRect && width > 1 && height > 1
    }
}
