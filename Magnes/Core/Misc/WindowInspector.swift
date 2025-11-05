//
//  WindowInspector.swift
//  Magnes
//
//  Created by Codex on 11/04/25.
//

import AppKit
import CoreGraphics
import Foundation

/// Lightweight helper to query the front-most window at a screen point.
/// Used to detect when a foreign overlay/palette (e.g., screenshot tool) is
/// above the underlying app so we can suspend magnetism.
final class WindowInspector {
    private let knownOverlayOwnerNameSubstrings: [String] = [
        "cleanshot", // CleanShot X
        "shottr",
        "snagit",
        "skitch",
        "xnapper",
        "monosnap",
        "lightshot",
        "kap",
    ]
    /// Returns the owner PID of the front-most window at `point`, excluding windows owned by `excludedPID`.
    func topWindowOwnerPID(at point: CGPoint, excludingPID excludedPID: pid_t?) -> pid_t? {
        guard let windowList = CGWindowListCopyWindowInfo([
            .optionOnScreenOnly,
            .excludeDesktopElements
        ], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Convert to the top-left origin used by CGWindow bounds for comparison.
        var cgPoint = point
        if let screenHeight = NSScreen.main?.frame.height {
            cgPoint.y = screenHeight - cgPoint.y
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != excludedPID,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let xNum = boundsDict["X"] as? NSNumber,
                  let yNum = boundsDict["Y"] as? NSNumber,
                  let wNum = boundsDict["Width"] as? NSNumber,
                  let hNum = boundsDict["Height"] as? NSNumber else {
                continue
            }
            let x = CGFloat(truncating: xNum)
            let y = CGFloat(truncating: yNum)
            let w = CGFloat(truncating: wNum)
            let h = CGFloat(truncating: hNum)
            let alpha = (window[kCGWindowAlpha as String] as? CGFloat) ?? 1.0
            if alpha <= 0 { continue }

            let rect = CGRect(x: x, y: y, width: w, height: h)
            if rect.contains(cgPoint) {
                return ownerPID
            }
        }
        return nil
    }

    /// Returns true if a known screenshot/utility overlay window owns the topmost pixel at `point`.
    func isKnownOverlayOwnerTopmost(at point: CGPoint) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([
            .optionOnScreenOnly,
            .excludeDesktopElements
        ], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        var cgPoint = point
        if let screenHeight = NSScreen.main?.frame.height {
            cgPoint.y = screenHeight - cgPoint.y
        }

        for window in windowList {
            let alpha = (window[kCGWindowAlpha as String] as? CGFloat) ?? 1.0
            if alpha <= 0 { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let xNum = boundsDict["X"] as? NSNumber,
                  let yNum = boundsDict["Y"] as? NSNumber,
                  let wNum = boundsDict["Width"] as? NSNumber,
                  let hNum = boundsDict["Height"] as? NSNumber else {
                continue
            }
            let rect = CGRect(x: CGFloat(truncating: xNum),
                              y: CGFloat(truncating: yNum),
                              width: CGFloat(truncating: wNum),
                              height: CGFloat(truncating: hNum))
            guard rect.contains(cgPoint) else { continue }
            if let ownerName = window[kCGWindowOwnerName as String] as? String {
                let lower = ownerName.lowercased()
                if knownOverlayOwnerNameSubstrings.contains(where: { lower.contains($0) }) {
                    return true
                }
            }
            // Only evaluate topmost; windowList is front-to-back
            return false
        }
        return false
    }

    /// True if the topmost window at point is owned by a different process than `axPID`.
    /// This is a good signal that a floating utility palette/popover sits above the app,
    /// and pointer magnetism should be suspended.
    func hasForeignTopWindow(at point: CGPoint, axPID: pid_t?) -> Bool {
        let selfPID = getpid()
        guard let topPID = topWindowOwnerPID(at: point, excludingPID: selfPID) else { return false }
        guard let axPID else { return true }
        return topPID != axPID
    }
}
