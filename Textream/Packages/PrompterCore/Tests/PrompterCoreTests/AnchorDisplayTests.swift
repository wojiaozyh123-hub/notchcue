//
//  AnchorDisplayTests.swift
//  PrompterCoreTests
//

import CoreGraphics
import Testing
@testable import PrompterCore

@Suite("Smooth cursor")
struct SmoothCursorTests {
    private let frame = 1.0 / 60.0

    @Test func flowsAtTheCappedSpeed() {
        var cursor = SmoothCursor(maxSpeed: 8)
        var previous = cursor.position
        var elapsed = 0.0
        while cursor.position < 10 && elapsed < 5 {
            cursor.step(toward: 10, dt: frame)
            let moved = cursor.position - previous
            #expect(moved >= 0)
            #expect(moved <= 8 * frame + 1e-9, "moved \(moved) in one frame")
            previous = cursor.position
            elapsed += frame
        }
        #expect(cursor.position == 10)
        // 10 tokens at 8 per second, plus the eased final token or two.
        #expect(elapsed > 1.2 && elapsed < 2.5)
    }

    @Test func burstsDoNotJump() {
        // A recognition result adds five characters at once.
        var cursor = SmoothCursor(maxSpeed: 8)
        cursor.step(toward: 5, dt: frame)
        #expect(cursor.position < 0.2)
    }

    @Test func largeGapSlidesQuickly() {
        var cursor = SmoothCursor(maxSpeed: 8)
        var elapsed = 0.0
        while cursor.position < 30 && elapsed < 2 {
            cursor.step(toward: 30, dt: frame)
            elapsed += frame
        }
        #expect(cursor.position == 30)
        #expect(elapsed <= 0.25 + 2 * frame)
    }

    @Test func explicitMovesSnap() {
        var cursor = SmoothCursor(position: 20, maxSpeed: 8)
        cursor.step(toward: 5, dt: frame)
        #expect(cursor.position == 5)
        cursor.jump(to: 40)
        #expect(cursor.position == 40)
    }

    @Test func targetGrowingDuringSlideIsFollowed() {
        var cursor = SmoothCursor(maxSpeed: 8)
        var target = 25.0
        for _ in 0..<120 {
            cursor.step(toward: target, dt: frame)
            target += 0.05
        }
        #expect(abs(cursor.position - target) < 1)
    }
}

@Suite("Anchor strip layout")
struct AnchorStripLayoutTests {
    // This MacBook: 1512×982, notch between x 663 and 848, 32 points tall.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 42, width: 1512, height: 907)
    private let left = CGRect(x: 0, y: 950, width: 663, height: 32)
    private let right = CGRect(x: 848, y: 950, width: 664, height: 32)

    @Test func anchorSitsUnderTheCamera() {
        let layout = AnchorStripLayout(screenFrame: screen, visibleFrame: visible, safeAreaTop: 32,
                                       notchLeftArea: left, notchRightArea: right,
                                       fontSize: 26, lineHeight: 32, previewCount: 12)
        #expect(layout.cameraX == 755.5)
        #expect(layout.topInset == 32)
        #expect(layout.lineTop == 36)
        // Hangs from the top of the screen.
        #expect(layout.frame.maxY == 982)
        let expectedHeight: CGFloat = 32 + 4 + 32 + 8
        #expect(layout.frame.height == expectedHeight)
        // Starts just left of the notch, extends right for the preview.
        let expectedMinX: CGFloat = 663 - 6
        let expectedMaxX: CGFloat = 755.5 + 13 + 312 + 16
        #expect(layout.frame.minX == expectedMinX)
        #expect(layout.frame.maxX == expectedMaxX)
    }

    @Test func largeFontReachesFurtherLeft() {
        let layout = AnchorStripLayout(screenFrame: screen, visibleFrame: visible, safeAreaTop: 32,
                                       notchLeftArea: left, notchRightArea: right,
                                       fontSize: 40, lineHeight: 48, previewCount: 12)
        let expectedAnchor: CGFloat = 140
        #expect(layout.anchorX == expectedAnchor)
    }

    @Test func stripStaysOnScreen() {
        let layout = AnchorStripLayout(screenFrame: screen, visibleFrame: visible, safeAreaTop: 32,
                                       notchLeftArea: left, notchRightArea: right,
                                       fontSize: 40, lineHeight: 48, previewCount: 20)
        #expect(layout.frame.maxX <= screen.maxX)
    }

    @Test func screensWithoutANotchUseTheCentre() {
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let externalVisible = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        let layout = AnchorStripLayout(screenFrame: external, visibleFrame: externalVisible, safeAreaTop: 0,
                                       notchLeftArea: nil, notchRightArea: nil,
                                       fontSize: 26, lineHeight: 32, previewCount: 12)
        #expect(layout.cameraX == external.midX)
        #expect(layout.topInset == 25)
        #expect(layout.frame.maxY == external.maxY)
    }
}

@Suite("Display spacing")
struct DisplaySpacingTests {
    @Test func noSpaceAroundChinese() {
        #expect(displaySeparator(between: "大", and: "家") == "")
        #expect(displaySeparator(between: "和", and: "iPhone") == "")
        #expect(displaySeparator(between: "iPhone", and: "以") == "")
        #expect(displaySeparator(between: "好", and: "，") == "")
        #expect(displaySeparator(between: "2026", and: "年") == "")
        #expect(displaySeparator(between: "二", and: "〇") == "")
    }

    @Test func spaceBetweenLatinWords() {
        #expect(displaySeparator(between: "Hello,", and: "world.") == " ")
        #expect(displaySeparator(between: "GPT-4o", and: "is") == " ")
    }
}
