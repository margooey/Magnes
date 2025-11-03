//
//  CursorView.swift
//  Magnes
//
//  Created by margooey on 5/27/25.
//

import AppKit
import CoreGraphics
import Foundation

/// Draws the custom cursor, including pointer press animation and alternate cursor shapes.
class CursorView: NSView {
    enum CursorMode {
        case pointer
        case ibeam
        case fill
        case horizontalResize
        case verticalResize
        case diagonalResize
    }

    var targetFrame: CGRect?
    var mousePosition: CGPoint = .zero
    var cursorMode: CursorMode = .pointer
    let cursorPointerImage = NSImage(named: "cursorOutline")!
    let cursorIBeamImage = NSImage(named: "cursorIBeam")!
    var isMouseButtonDown: Bool = false {
        didSet {
            guard isMouseButtonDown != oldValue else { return }
            targetPointerScale = isMouseButtonDown ? pointerPressedScale : 1.0
            lastPointerScaleUpdateTime = CFAbsoluteTimeGetCurrent()
        }
    }
    private let pointerBaseSize: CGFloat = 24
    private let pointerPressedScale: CGFloat = 0.88
    private var pointerScale: CGFloat = 1.0
    private var targetPointerScale: CGFloat = 1.0
    private var lastPointerScaleUpdateTime: CFTimeInterval = CFAbsoluteTimeGetCurrent()
    var isPointerAnimating: Bool {
        abs(pointerScale - targetPointerScale) > 0.001
    }

    /// Renders the pointer sprite at the current location, applying the animated scale.
    private func drawPointer() {
        updatePointerScale()

        let width = pointerBaseSize * pointerScale
        let height = pointerBaseSize * pointerScale
        let hotspotOffset = CGPoint(x: 0, y: 0)
        
        let originX = mousePosition.x - hotspotOffset.x
        let originY = mousePosition.y - height + hotspotOffset.y
        
        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        
        NSGraphicsContext.current?.imageInterpolation = .high
        
        cursorPointerImage.draw(in: rect,
                   from: NSRect(origin: .zero, size: cursorPointerImage.size),
                   operation: .sourceOver,
                   fraction: 1, // alpha
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
    }

    /// Drives a smooth transition between the resting and pressed scale using exponential smoothing.
    private func updatePointerScale() {
        let now = CFAbsoluteTimeGetCurrent()
        let delta = min(max(now - lastPointerScaleUpdateTime, 0), 1.0 / 30.0)
        lastPointerScaleUpdateTime = now
        let smoothingConstant: Double = 20.0 /// How fast the animation scales, higher = faster
        let interpolation = 1 - exp(-smoothingConstant * delta)
        pointerScale += (targetPointerScale - pointerScale) * CGFloat(interpolation)
        if abs(pointerScale - targetPointerScale) < 0.001 {
            pointerScale = targetPointerScale
        }
    }

    /// Renders the I-beam overlay centered on the cursor position.
    private func drawIBeam() {
        let width: CGFloat = 24
        let height: CGFloat = 24
        
        let originX = mousePosition.x - height / 2
        let originY = mousePosition.y - height / 2
        
        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        
        NSGraphicsContext.current?.imageInterpolation = .high
        
        cursorIBeamImage.draw(in: rect,
                   from: NSRect(origin: .zero, size: cursorIBeamImage.size),
                   operation: .sourceOver,
                   fraction: 1, // alpha
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
    }
    
    /// Draws the fill cursor by shading the target element with a gradient biased to the cursor position.
    private func drawFill() {
        if let frame = targetFrame {
            let flippedFrame = CGRect(
                x: frame.origin.x,
                y: bounds.height - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
            let path = NSBezierPath(roundedRect: flippedFrame, xRadius: 10.0, yRadius: 10.0)
            
            /// Relative center position for the gradient
            let center = mousePosition
            let localX = center.x - flippedFrame.minX
            let localY = center.y - flippedFrame.minY
            let relX = (localX / flippedFrame.width) * 2.0 - 1.0
            let relY = (localY / flippedFrame.height) * 2.0 - 1.0
            
            /// Gradient is lightest at the position of the cursor
            if let gradient = NSGradient(
                starting: NSColor.white.withAlphaComponent(0.5),
                ending: NSColor.gray.withAlphaComponent(0.5)
            ) {
                gradient.draw(in: path, relativeCenterPosition: NSPoint(x: relX, y: relY))
            }
        }
    }

    /// Renders a simple horizontal resize glyph (line + arrow heads).
    private func drawHorizontalResize() {
        let lineWidth: CGFloat = 2.0
        let lineLength: CGFloat = 20.0
        let arrowSize: CGFloat = 5.0
        let centerY = mousePosition.y
        let centerX = mousePosition.x

        /// Horizontal line
        let lineRect = CGRect(
            x: centerX - lineLength / 2,
            y: centerY - lineWidth / 2,
            width: lineLength,
            height: lineWidth
        )
        NSBezierPath(rect: lineRect).fill()

        /// Left arrow
        let leftArrow = NSBezierPath()
        leftArrow.move(to: CGPoint(x: centerX - lineLength / 2, y: centerY))
        leftArrow.line(to: CGPoint(x: centerX - lineLength / 2 + arrowSize, y: centerY + arrowSize))
        leftArrow.line(to: CGPoint(x: centerX - lineLength / 2 + arrowSize, y: centerY - arrowSize))
        leftArrow.close()
        leftArrow.fill()

        /// Right arrow
        let rightArrow = NSBezierPath()
        rightArrow.move(to: CGPoint(x: centerX + lineLength / 2, y: centerY))
        rightArrow.line(to: CGPoint(x: centerX + lineLength / 2 - arrowSize, y: centerY + arrowSize))
        rightArrow.line(to: CGPoint(x: centerX + lineLength / 2 - arrowSize, y: centerY - arrowSize))
        rightArrow.close()
        rightArrow.fill()
    }

    /// Renders a simple vertical resize glyph (stacked arrows).
    private func drawVerticalResize() {
        let lineWidth: CGFloat = 2.0
        let lineLength: CGFloat = 20.0
        let arrowSize: CGFloat = 5.0
        let centerY = mousePosition.y
        let centerX = mousePosition.x

        let lineRect = CGRect(
            x: centerX - lineWidth / 2,
            y: centerY - lineLength / 2,
            width: lineWidth,
            height: lineLength
        )
        NSBezierPath(rect: lineRect).fill()

        /// Top arrow
        let topArrow = NSBezierPath()
        topArrow.move(to: CGPoint(x: centerX, y: centerY - lineLength / 2))
        topArrow.line(to: CGPoint(x: centerX + arrowSize, y: centerY - lineLength / 2 + arrowSize))
        topArrow.line(to: CGPoint(x: centerX - arrowSize, y: centerY - lineLength / 2 + arrowSize))
        topArrow.close()
        topArrow.fill()

        /// Bottom arrow
        let bottomArrow = NSBezierPath()
        bottomArrow.move(to: CGPoint(x: centerX, y: centerY + lineLength / 2))
        bottomArrow.line(to: CGPoint(x: centerX + arrowSize, y: centerY + lineLength / 2 - arrowSize))
        bottomArrow.line(to: CGPoint(x: centerX - arrowSize, y: centerY + lineLength / 2 - arrowSize))
        bottomArrow.close()
        bottomArrow.fill()
    }

    private func drawDiagonalResize() {}

    private func cursorBrightness() {}

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // TODO: Implement cursor brightness with CGDisplayCreateImage()
        //NSColor.gray.withAlphaComponent(0.5).setFill()

        switch cursorMode {
        case .pointer:
            drawPointer()
        case .ibeam:
            drawIBeam()
        case .fill:
            drawFill()
            drawPointer()
        case .horizontalResize:
            drawHorizontalResize()
        case .verticalResize:
            drawVerticalResize()
        case .diagonalResize:
            drawDiagonalResize()
        }
    }
}
