//
//  CursorAppearanceResolver.swift
//  Magnes
//
//  Created by margooey on 11/24/24.
//

import AppKit
import ApplicationServices

/// Maps low-level cursor metadata to the mode rendered by `CursorView`.
/// Pairs the current system cursor type with Accessibility role hints to choose the right overlay.
struct CursorAppearanceResolver {
    private let fillRoles: Set<String> = [
        kAXButtonRole,
        kAXDockItemRole
    ]

    /// Determines which cursor art/behaviour should be displayed.
    /// Precedence:
    /// 1. Certain accessibility roles trigger the fill cursor regardless of system cursor type.
    /// 2. Otherwise the C-level cursor type is mapped to the nearest overlay enum.
    func cursorMode(for cursorType: CursorType, elementRole: String?) -> CursorView.CursorMode {
        if let role = elementRole, fillRoles.contains(role) {
            return .fill
        }

        switch cursorType {
        case IBEAM:
            return .ibeam
        case HORIZONTAL_RESIZE:
            return .horizontalResize
        case VERTICAL_RESIZE:
            return .verticalResize
        case DIAGONAL_RESIZE:
            return .diagonalResize
        default:
            return .pointer
        }
    }
}
