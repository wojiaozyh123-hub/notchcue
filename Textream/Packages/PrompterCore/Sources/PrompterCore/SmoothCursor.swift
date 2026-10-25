//
//  SmoothCursor.swift
//  PrompterCore
//
//  The anchor display's position. Recognition results arrive in bursts of a
//  few characters; showing them as they arrive makes the line jump. The
//  displayed position instead chases the recognized one at a capped speed so
//  the text flows toward the anchor. A large gap (the speaker skipped a
//  sentence) is closed in one quick slide rather than crawled at the cap.
//

import Foundation

public struct SmoothCursor: Sendable {
    /// Displayed position in tokens: the token at this index sits on the
    /// anchor; fractions are between two tokens.
    public private(set) var position: Double
    /// Tokens per second while catching up.
    public var maxSpeed: Double
    /// Gaps larger than this many tokens are closed with a quick slide.
    public var slideGap: Double = 12
    public var slideDuration: Double = 0.25

    private struct Slide: Sendable {
        var from: Double
        var to: Double
        var elapsed: Double
    }
    private var slide: Slide?

    /// Speed is proportional to the gap (per second) below the cap, so the
    /// last token settles instead of stopping dead.
    static let easing = 6.0
    static let minimumSpeed = 1.0

    public init(position: Double = 0, maxSpeed: Double = 8) {
        self.position = position
        self.maxSpeed = maxSpeed
    }

    /// Explicit moves (tap, hotkeys, new page) go straight to the target.
    public mutating func jump(to target: Double) {
        position = target
        slide = nil
    }

    public var isMoving: Bool { slide != nil }

    public mutating func step(toward target: Double, dt: Double) {
        guard dt > 0 else { return }
        // Recognition never moves back, so a target behind the display is
        // an explicit move.
        if target < position {
            jump(to: target)
            return
        }
        if var current = slide {
            current.elapsed += dt
            let t = min(1, current.elapsed / slideDuration)
            let eased = 1 - pow(1 - t, 3)
            position = min(target, current.from + (current.to - current.from) * eased)
            slide = t >= 1 ? nil : current
            return
        }
        let gap = target - position
        guard gap > 0 else { return }
        if gap > slideGap {
            slide = Slide(from: position, to: target, elapsed: 0)
            step(toward: target, dt: dt)
            return
        }
        let speed = min(maxSpeed, max(Self.minimumSpeed, gap * Self.easing))
        position = min(target, position + speed * dt)
    }
}
