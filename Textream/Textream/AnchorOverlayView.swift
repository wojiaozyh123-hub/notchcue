//
//  AnchorOverlayView.swift
//  Textream
//
//  Anchor display: one line hanging from the notch, with the next word to
//  read held under the camera. Upcoming words flow toward that spot; words
//  already read slide left and fade. The reader's eyes stay on one place just
//  below the lens.
//

import AppKit
import SwiftUI
import Combine
import PrompterCore

// MARK: - Line layout

/// Every word of the script laid out on one line, measured once per script
/// and font.
final class AnchorLineLayout {
    let words: [String]
    let script: TokenizedScript
    let font: NSFont
    /// Left edge of each word on the line.
    let wordX: [CGFloat]
    /// Display offset where each word starts (what a tap jumps to).
    let wordOffset: [Int]
    let wordIsAnnotation: [Bool]
    /// The token whose state colours each word: its first token, or for
    /// punctuation the token it follows.
    let wordToken: [Int]
    /// Horizontal centre of each token.
    let tokenCenter: [CGFloat]

    init(words: [String], paragraphBreaks: Set<Int>, font: NSFont) {
        self.words = words
        self.font = font
        let script = TokenizedScript(words: words, paragraphBreakBeforeWordIndices: paragraphBreaks)
        self.script = script
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: attributes).width
        }
        let spaceWidth = width(" ")
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)

        var wordX: [CGFloat] = []
        var wordOffset: [Int] = []
        var x: CGFloat = 0
        var offset = 0
        for (index, word) in words.enumerated() {
            wordX.append(x)
            wordOffset.append(offset)
            x += width(word)
            if index + 1 < words.count, !displaySeparator(between: word, and: words[index + 1]).isEmpty {
                x += spaceWidth
            }
            offset += word.count + 1
        }

        var tokenCenter: [CGFloat] = []
        var firstTokenOfWord = Array(repeating: -1, count: words.count)
        for (index, token) in script.tokens.enumerated() {
            let word = words[token.wordIndex]
            let start = token.start - wordOffset[token.wordIndex]
            let length = token.end - token.start
            let prefix = String(word.prefix(start))
            let body = String(word.dropFirst(start).prefix(length))
            tokenCenter.append(wordX[token.wordIndex] + width(prefix) + width(body) / 2)
            if firstTokenOfWord[token.wordIndex] < 0 {
                firstTokenOfWord[token.wordIndex] = index
            }
        }

        var wordToken: [Int] = []
        var lastToken = 0
        for index in words.indices {
            if firstTokenOfWord[index] >= 0 {
                lastToken = firstTokenOfWord[index]
            }
            wordToken.append(lastToken)
        }

        self.wordX = wordX
        self.wordOffset = wordOffset
        self.wordIsAnnotation = words.indices.map { annotationFlags[$0] || WordFlowLayout.isAnnotationWord(words[$0]) }
        self.wordToken = wordToken
        self.tokenCenter = tokenCenter
    }

    /// Line x that should sit on the anchor at a (fractional) token position.
    func centerX(at position: Double) -> CGFloat {
        guard let last = tokenCenter.indices.last else { return 0 }
        if position <= 0 { return tokenCenter[0] }
        if position >= Double(last) {
            return tokenCenter[last] + CGFloat(position - Double(last)) * font.pointSize
        }
        let index = Int(position)
        let fraction = CGFloat(position - Double(index))
        return tokenCenter[index] + (tokenCenter[index + 1] - tokenCenter[index]) * fraction
    }

    /// Words worth drawing around a position: a few already read, the
    /// preview, and one more fading in.
    func visibleWords(around position: Double, ahead: Int) -> Range<Int> {
        guard !script.tokens.isEmpty else { return 0..<0 }
        let current = max(0, min(script.tokens.count - 1, Int(position)))
        let firstToken = max(0, current - 4)
        let lastToken = min(script.tokens.count - 1, current + ahead + 2)
        let firstWord = script.tokens[firstToken].wordIndex
        let lastWord = lastToken + 1 < script.tokens.count
            ? script.tokens[lastToken + 1].wordIndex
            : words.count
        return firstWord..<max(firstWord, lastWord)
    }

    /// Token index of the first token at or after a word (for taps in
    /// timer-driven modes).
    func tokenIndex(atWord word: Int) -> Int {
        script.tokenIndex(forOffset: wordOffset[word])
    }

    // Measured layouts for the live overlay and the settings preview, which
    // can be on screen together. Both ask on every update, so neither may
    // push the other out and force the whole script to be measured again.
    private static var cache: [AnchorLineLayout] = []

    static func layout(words: [String], paragraphBreaks: Set<Int>, font: NSFont) -> AnchorLineLayout {
        if let hit = cache.first(where: {
            $0.words == words && $0.font.fontName == font.fontName && $0.font.pointSize == font.pointSize
        }) {
            return hit
        }
        let layout = AnchorLineLayout(words: words, paragraphBreaks: paragraphBreaks, font: font)
        cache = Array(([layout] + cache).prefix(2))
        return layout
    }
}

// MARK: - Playhead

/// Per-frame state: the smoothed position and when each token was read.
final class AnchorPlayhead {
    private(set) var cursor = SmoothCursor()
    private var lastTime: TimeInterval?
    private var lastJumpCount: Int?
    private var readBoundary = 0
    private(set) var readAt: [Int: TimeInterval] = [:]

    static let fadeDuration: TimeInterval = 0.3

    func advance(now: TimeInterval, target: Double, maxSpeed: Double, jumpCount: Int) {
        cursor.maxSpeed = maxSpeed
        if jumpCount != lastJumpCount {
            lastJumpCount = jumpCount
            cursor.jump(to: target)
            readAt.removeAll()
            readBoundary = Self.boundary(for: target)
            lastTime = now
            return
        }
        let dt = lastTime.map { min(0.1, now - $0) } ?? 0
        lastTime = now
        cursor.step(toward: target, dt: dt)

        // A token is read once the line has carried it half a token past the anchor.
        let boundary = Self.boundary(for: cursor.position)
        if boundary > readBoundary {
            for token in readBoundary..<boundary {
                readAt[token] = now
            }
        } else if boundary < readBoundary {
            readAt = readAt.filter { $0.key < boundary }
        }
        readBoundary = boundary
        readAt = readAt.filter { now - $0.value < Self.fadeDuration }
    }

    private static func boundary(for position: Double) -> Int {
        max(0, Int((position - 0.5).rounded(.up)))
    }

    func opacity(ofToken token: Int, now: TimeInterval, previewCount: Int) -> Double {
        let distance = Double(token) - cursor.position
        if distance < -0.5 {
            guard let readTime = readAt[token] else { return 0 }
            return max(0, 1 - (now - readTime) / Self.fadeDuration)
        }
        if distance <= 0.5 { return 1 }
        let preview = Double(previewCount)
        if distance <= preview + 0.5 {
            return max(0.3, 1 - 0.7 * (distance - 0.5) / preview)
        }
        if distance <= preview + 1.5 {
            return 0.3 * (preview + 1.5 - distance)
        }
        return 0
    }
}

// MARK: - Line view

struct AnchorLineView: View {
    let layout: AnchorLineLayout
    let playhead: AnchorPlayhead
    /// Tokens read (the token at this index belongs on the anchor).
    let target: Double
    let jumpCount: Int
    let anchorX: CGFloat
    let previewCount: Int
    let maxSpeed: Double
    let color: Color
    let cueColor: Color
    var dimmed = false
    var onTapWord: ((Int) -> Void)? = nil

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let _ = playhead.advance(now: now, target: target, maxSpeed: maxSpeed, jumpCount: jumpCount)
            let position = playhead.cursor.position
            let shift = anchorX - layout.centerX(at: position)
            ZStack(alignment: .topLeading) {
                ForEach(layout.visibleWords(around: position, ahead: previewCount), id: \.self) { index in
                    let annotation = layout.wordIsAnnotation[index]
                    let opacity = playhead.opacity(ofToken: layout.wordToken[index], now: now, previewCount: previewCount)
                    Text(layout.words[index])
                        .font(annotation ? Font(layout.font).italic() : Font(layout.font))
                        .foregroundStyle(annotation ? cueColor : color)
                        .opacity(annotation ? opacity * 0.5 : opacity)
                        .fixedSize()
                        .offset(x: layout.wordX[index] + shift)
                        .onTapGesture { onTapWord?(index) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(dimmed ? 0.4 : 1)
        }
    }
}

// MARK: - Strip geometry

@Observable
final class AnchorStripState {
    private(set) var layout: AnchorStripLayout
    private(set) var screen: NSScreen
    @ObservationIgnored weak var panel: NSPanel?

    init(screen: NSScreen) {
        self.screen = screen
        self.layout = Self.layout(for: screen)
    }

    func move(to screen: NSScreen) {
        self.screen = screen
        refresh()
    }

    /// Recompute after a font or preview-count change, and resize the panel.
    func refresh() {
        let updated = Self.layout(for: screen)
        guard updated != layout else { return }
        layout = updated
        panel?.setFrame(updated.frame, display: true)
    }

    static func layout(for screen: NSScreen) -> AnchorStripLayout {
        let settings = NotchSettings.shared
        let font = settings.anchorFont
        return AnchorStripLayout(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            notchLeftArea: screen.auxiliaryTopLeftArea,
            notchRightArea: screen.auxiliaryTopRightArea,
            fontSize: font.pointSize,
            lineHeight: ceil(font.ascender - font.descender + font.leading),
            previewCount: settings.anchorPreviewCount,
            horizontalOffset: CGFloat(settings.anchorOffset)
        )
    }
}

/// The black strip, square at the top where it meets the screen edge and the
/// notch, rounded at the bottom. Centred on the anchor.
struct AnchorStripShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 14,
            bottomTrailingRadius: 14,
            topTrailingRadius: 0,
            style: .continuous
        ).path(in: rect)
    }
}

// MARK: - Live overlay

struct AnchorOverlayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let strip: AnchorStripState

    @State private var playhead = AnchorPlayhead()
    @State private var visible = false
    // Classic and voice-activated modes advance on a timer instead of speech.
    @State private var timerProgress: Double = 0
    @State private var timerJumpCount = 0
    @State private var autoNextWork: DispatchWorkItem?
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var settings: NotchSettings { NotchSettings.shared }
    private var listeningMode: ListeningMode { settings.listeningMode }

    private var lineLayout: AnchorLineLayout {
        AnchorLineLayout.layout(
            words: content.words,
            paragraphBreaks: content.paragraphBreakBeforeWordIndices,
            font: settings.anchorFont
        )
    }

    private var target: Double {
        switch listeningMode {
        case .wordTracking:
            return Double(lineLayout.script.tokenIndex(forOffset: speechRecognizer.recognizedCharCount))
        case .classic, .silencePaused:
            return min(timerProgress, Double(lineLayout.script.tokens.count))
        }
    }

    private var jumpCount: Int {
        listeningMode == .wordTracking ? speechRecognizer.cursorJumpCount : timerJumpCount
    }

    private var isDone: Bool {
        switch listeningMode {
        case .wordTracking:
            return content.totalCharCount > 0 && speechRecognizer.recognizedCharCount >= content.totalCharCount
        case .classic, .silencePaused:
            return !lineLayout.script.tokens.isEmpty && timerProgress >= Double(lineLayout.script.tokens.count)
        }
    }

    private var isPaused: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused:
            return !speechRecognizer.isListening && !speechRecognizer.isStarting
        case .classic:
            return content.isPaused
        }
    }

    var body: some View {
        let layout = strip.layout
        ZStack(alignment: .topLeading) {
            AnchorStripShape().fill(.black)

            Group {
                if let error = speechRecognizer.error {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    AnchorLineView(
                        layout: lineLayout,
                        playhead: playhead,
                        target: target,
                        jumpCount: jumpCount,
                        anchorX: layout.anchorX,
                        previewCount: settings.anchorPreviewCount,
                        maxSpeed: settings.anchorMaxSpeed,
                        color: settings.fontColorPreset.color,
                        cueColor: settings.cueColorPreset.color,
                        dimmed: isPaused,
                        onTapWord: jump(toWord:)
                    )
                }
            }
            .frame(height: layout.lineHeight)
            .offset(y: layout.lineTop)
        }
        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .topLeading)
        .clipShape(AnchorStripShape())
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { visible = true }
        }
        .onChange(of: speechRecognizer.shouldDismiss) { _, dismissing in
            if dismissing {
                withAnimation(.easeIn(duration: 0.25)) { visible = false }
            }
        }
        .onChange(of: settings.anchorFontSize) { _, _ in strip.refresh() }
        .onChange(of: settings.anchorPreviewCount) { _, _ in strip.refresh() }
        .onChange(of: settings.anchorOffset) { _, _ in strip.refresh() }
        .onChange(of: settings.fontFamilyPreset) { _, _ in strip.refresh() }
        .onChange(of: content.phraseStep) { _, step in
            // ⌃⌥←/→ in timer-driven modes; word tracking is moved by the controller.
            guard listeningMode != .wordTracking else { return }
            let script = lineLayout.script
            let current = script.cursorOffset(forToken: Int(min(timerProgress, Double(script.tokens.count))))
            guard let offset = content.phraseStepOffset(from: current, direction: step.direction) else { return }
            timerProgress = Double(script.tokenIndex(forOffset: offset))
            timerJumpCount &+= 1
        }
        .onChange(of: content.currentPageIndex) { _, _ in
            timerProgress = 0
            timerJumpCount &+= 1
        }
        .onChange(of: content.totalCharCount) { _, _ in
            timerProgress = 0
            timerJumpCount &+= 1
        }
        .onChange(of: isDone) { _, done in
            autoNextWork?.cancel()
            autoNextWork = nil
            guard done else { return }
            // Same rules as the notch overlay: word tracking stops and closes
            // after the last page; auto next page advances after its delay.
            if listeningMode == .wordTracking {
                speechRecognizer.stop()
            }
            if !content.hasNextPage {
                if listeningMode == .wordTracking {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        speechRecognizer.shouldDismiss = true
                    }
                }
            } else if settings.autoNextPage {
                let work = DispatchWorkItem { speechRecognizer.shouldAdvancePage = true }
                autoNextWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(settings.autoNextPageDelay), execute: work)
            }
        }
        .onReceive(scrollTimer) { _ in
            guard !isDone else { return }
            switch listeningMode {
            case .classic:
                if !content.isPaused {
                    timerProgress += settings.scrollSpeed * 0.05
                }
            case .silencePaused:
                if speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerProgress += settings.scrollSpeed * 0.05
                }
            case .wordTracking:
                break
            }
        }
    }

    private func jump(toWord index: Int) {
        switch listeningMode {
        case .wordTracking:
            speechRecognizer.jumpTo(charOffset: lineLayout.wordOffset[index])
        case .classic, .silencePaused:
            timerProgress = Double(lineLayout.tokenIndex(atWord: index))
            timerJumpCount &+= 1
        }
    }
}

// MARK: - Settings preview

/// The strip as it will appear, reading a sample script by itself, so font
/// size, preview length and speed can be judged while changing them.
struct AnchorPreviewStrip: View {
    @Bindable var settings: NotchSettings
    let screen: NSScreen

    private static let sampleText = "大家好，今天我们来聊一聊期中考试的安排。考试时间是2026年11月3日，地点在三号楼。请大家提前十分钟到场，带好学生证和iPhone以外的计时工具。"
    private static let sampleWords = splitTextIntoWords(sampleText)

    @State private var playhead = AnchorPlayhead()
    @State private var progress = 0
    @State private var loop = 0
    // Recognition arrives in bursts; the preview does too, two words at a time.
    private let burstTimer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    var body: some View {
        let layout = AnchorStripState.layout(for: screen)
        let lineLayout = AnchorLineLayout.layout(words: Self.sampleWords, paragraphBreaks: [], font: settings.anchorFont)
        ZStack(alignment: .topLeading) {
            AnchorStripShape().fill(.black)
            AnchorLineView(
                layout: lineLayout,
                playhead: playhead,
                target: Double(progress),
                jumpCount: loop,
                anchorX: layout.anchorX,
                previewCount: settings.anchorPreviewCount,
                maxSpeed: settings.anchorMaxSpeed,
                color: settings.fontColorPreset.color,
                cueColor: settings.cueColorPreset.color
            )
            .frame(height: layout.lineHeight)
            .offset(y: layout.lineTop)
        }
        .frame(width: layout.frame.width, height: layout.frame.height, alignment: .topLeading)
        .clipShape(AnchorStripShape())
        .offset(x: layout.frame.minX - screen.frame.minX)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(burstTimer) { _ in
            let count = lineLayout.script.tokens.count
            if progress >= count {
                progress = 0
                loop &+= 1
            } else {
                progress = min(count, progress + 2)
            }
        }
    }
}
