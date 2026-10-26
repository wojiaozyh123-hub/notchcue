//
//  AnchorStripLayout.swift
//  PrompterCore
//
//  Where the anchor display sits. The anchor (the next word to read) is
//  horizontally under the camera, the centre of the notch, found from the
//  screen areas left and right of it; screens without a notch use their
//  centre. The black strip hangs from the top of the screen and is centred
//  on the anchor, wide enough for the preview on the right and the same on
//  the left, so the whole strip reads as centred under the camera. A user
//  offset moves anchor and strip together.
//

import CoreGraphics

public struct AnchorStripLayout: Equatable, Sendable {
    /// Strip frame in screen coordinates (origin bottom-left, like NSScreen).
    public let frame: CGRect
    /// Anchor x inside the strip.
    public let anchorX: CGFloat
    /// Height of the notch (or menu bar) the strip hangs below.
    public let topInset: CGFloat
    /// Top of the text line inside the strip, measured from the strip's top.
    public let lineTop: CGFloat
    public let lineHeight: CGFloat

    static let lineGap: CGFloat = 4
    static let bottomPadding: CGFloat = 8
    static let edgePadding: CGFloat = 16

    public init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        notchLeftArea: CGRect?,
        notchRightArea: CGRect?,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        previewCount: Int,
        horizontalOffset: CGFloat = 0
    ) {
        let cameraX: CGFloat
        let topInset: CGFloat
        if let left = notchLeftArea, let right = notchRightArea, safeAreaTop > 0, right.minX > left.maxX {
            cameraX = (left.maxX + right.minX) / 2
            topInset = safeAreaTop
        } else {
            cameraX = screenFrame.midX
            topInset = max(0, screenFrame.maxY - visibleFrame.maxY)
        }

        let halfWidth = fontSize / 2 + CGFloat(previewCount) * fontSize + Self.edgePadding
        // The anchor itself always stays on screen; the strip is cut at the
        // screen edges.
        let anchorScreenX = min(
            max(cameraX + horizontalOffset, screenFrame.minX + fontSize),
            screenFrame.maxX - fontSize
        )
        let left = max(screenFrame.minX, anchorScreenX - halfWidth)
        let right = min(screenFrame.maxX, anchorScreenX + halfWidth)
        let height = topInset + Self.lineGap + lineHeight + Self.bottomPadding

        self.frame = CGRect(
            x: left,
            y: screenFrame.maxY - height,
            width: right - left,
            height: height
        )
        self.anchorX = anchorScreenX - left
        self.topInset = topInset
        self.lineTop = topInset + Self.lineGap
        self.lineHeight = lineHeight
    }

    /// The anchor's x in screen coordinates: the camera, plus any offset.
    public var anchorScreenX: CGFloat { frame.minX + anchorX }
}
