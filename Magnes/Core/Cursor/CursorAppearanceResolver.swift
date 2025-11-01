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
        kAXDockItemRole,
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        kAXPopUpButtonRole,
        kAXRadioButtonRole,
        kAXCheckBoxRole,
        kAXMenuButtonRole,
        kAXImageRole,
        kAXGroupRole,
        kAXToolbarRole,
        "AXTab",
        "AXLink"
    ]
    private let actionableAXActions: Set<String> = ["AXPress", "AXConfirm", "AXPick", "AXShowMenu"]

    /// Maximum area (in pixels) for an element to receive fill overlay
    /// Elements larger than this will use the default cursor for their type
    private let maxFillArea: CGFloat = 10000 // ~100x100 pixels

    /// Determines which cursor art/behaviour should be displayed.
    /// Precedence:
    /// 1. Certain accessibility roles trigger the fill cursor if they're small enough.
    /// 2. Otherwise the C-level cursor type is mapped to the nearest overlay enum.
    func cursorMode(
        for cursorType: CursorType,
        elementRole: String?,
        elementActionNames: [String]?,
        elementHasLink: Bool,
        elementFrame: CGRect?
    ) -> CursorView.CursorMode {
        let hasPressAction = elementActionNames?.contains(where: actionableAXActions.contains) ?? false
        let isInteractiveText = hasPressAction || elementHasLink

        if let role = elementRole, fillRoles.contains(role) {
            // Check if element is small enough for fill overlay
            if let frame = elementFrame {
                let area = frame.width * frame.height
                if area <= maxFillArea {
                    return .fill
                }
            } else {
                // If we don't have frame info, apply fill (safe fallback)
                return .fill
            }
        } else if elementRole == kAXStaticTextRole && isInteractiveText {
            if let frame = elementFrame {
                let area = frame.width * frame.height
                if area <= maxFillArea {
                    return .fill
                }
            } else {
                return .fill
            }
        } else if elementRole == nil && isInteractiveText {
            if let frame = elementFrame {
                let area = frame.width * frame.height
                if area <= maxFillArea {
                    return .fill
                }
            } else {
                return .fill
            }
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
