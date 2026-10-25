//
//  AnchorStripLayout.swift
//  PrompterCore
//
//  Where the anchor display sits. The anchor (the next word to read) is
//  horizontally under the camera, the centre of the notch, found from the
//  screen areas left and right of it; screens without a notch use their
//  centre. The black strip hangs from the top of the screen, starts at the
//  notch's left edge (or a few characters left of the anchor, whichever is
//  wider) and extends right far enough for the preview.
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
    static let readCharacters: CGFloat = 3.5
    static let edgePadding: CGFloat = 16

    public init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        notchLeftArea: CGRect?,
        notchRightArea: CGRect?,
        fontSize: CGFloat,
        lineHeight: CGFloat,
        previewCount: Int
    ) {
        let cameraX: CGFloat
        let notchMinX: CGFloat
        let topInset: CGFloat
        if let left = notchLeftArea, let right = notchRightArea, safeAreaTop > 0, right.minX > left.maxX {
            notchMinX = left.maxX
            cameraX = (left.maxX + right.minX) / 2
            topInset = safeAreaTop
        } else {
            cameraX = screenFrame.midX
            notchMinX = cameraX
            topInset = max(0, screenFrame.maxY - visibleFrame.maxY)
        }

        let leftExtent = min(
            max(Self.readCharacters * fontSize, cameraX - notchMinX + 6),
            cameraX - screenFrame.minX
        )
        let rightExtent = min(
            fontSize / 2 + CGFloat(previewCount) * fontSize + Self.edgePadding,
            screenFrame.maxX - cameraX
        )
        let height = topInset + Self.lineGap + lineHeight + Self.bottomPadding

        self.frame = CGRect(
            x: cameraX - leftExtent,
            y: screenFrame.maxY - height,
            width: leftExtent + rightExtent,
            height: height
        )
        self.anchorX = leftExtent
        self.topInset = topInset
        self.lineTop = topInset + Self.lineGap
        self.lineHeight = lineHeight
    }

    /// The camera's x in screen coordinates.
    public var cameraX: CGFloat { frame.minX + anchorX }
}
