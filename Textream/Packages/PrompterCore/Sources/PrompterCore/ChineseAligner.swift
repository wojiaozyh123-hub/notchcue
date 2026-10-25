//
//  ChineseAligner.swift
//  PrompterCore
//
//  Follows a Chinese (or mixed Chinese/English) script from speech.
//
//  Every recognition result is the whole transcript since the task (or the
//  last jump) began, and earlier words may be revised. Each result is matched
//  afresh: the last `spokenTail` tokens are locally aligned against the script
//  around the cursor (a few already-read tokens for context, `windowAhead`
//  tokens to read). Characters match when they are the same or sound the same
//  (pinyin); numbers match their spoken forms.
//
//  The cursor only moves when the alignment ends on the newest spoken token.
//  If the speaker says something that is not in the script, the newest token
//  matches nothing nearby and the cursor stays put. The original follower
//  advanced whenever a common character such as 我 or 天 appeared within a few
//  tokens, which carried the cursor through ad-libs.
//

import Foundation

public struct ChineseAlignerConfig: Equatable, Sendable {
    /// Script tokens after the cursor searched for the newest speech.
    public var windowAhead = 40
    /// Already-read tokens before the cursor kept in the window, so a run of
    /// matches can continue across the cursor.
    public var contextBehind = 8
    /// Newest spoken tokens aligned per result.
    public var spokenTail = 30
    /// Unmatched script tokens between the cursor and the final run of
    /// matches that still count as ordinary reading (a word the recognizer
    /// garbled or dropped).
    public var readingSkip = 2
    /// Skips up to this many tokens are small; longer ones are jumps.
    public var smallSkip = 8
    /// Consecutive matches the alignment must end with to advance while
    /// reading in order.
    public var minRunForStep = 2
    /// Consecutive matches required to skip more than `readingSkip` tokens.
    public var minRunForJump = 3
    /// A skip longer than `smallSkip` also needs two of the last three
    /// candidates within this many tokens of each other (the original
    /// follower's 2-of-3 gate).
    public var agreementTolerance = 3
    public var pinyin = PinyinOptions()

    public init() {}
}

public struct ChineseAligner {
    public let script: TokenizedScript
    public let config: ChineseAlignerConfig
    /// Number of script tokens read.
    public private(set) var cursor: Int
    private var recentCandidates: [Int] = []
    private let scriptReadings: [Set<String>]
    private let scriptNumberReadings: [[NumberReading]]

    private static let exactScore = 3
    private static let soundScore = 2
    private static let mismatchScore = -2
    private static let gapScore = -1
    private static let numberSyllableScore = 2

    public init(script: TokenizedScript, config: ChineseAlignerConfig = ChineseAlignerConfig(), cursor: Int = 0) {
        self.script = script
        self.config = config
        self.cursor = max(0, min(cursor, script.tokens.count))
        self.scriptReadings = script.tokens.map { Self.readings(of: $0.kind, options: config.pinyin) }
        self.scriptNumberReadings = script.tokens.map { token in
            if case .number(let value) = token.kind {
                return Self.normalized(ChineseNumberReadings.readings(of: value), options: config.pinyin)
            }
            return []
        }
    }

    public var cursorOffset: Int { script.cursorOffset(forToken: cursor) }

    /// Explicit moves (tap, hotkeys, page restore). May go backward.
    public mutating func setCursor(_ index: Int) {
        cursor = max(0, min(index, script.tokens.count))
        recentCandidates = []
    }

    public mutating func resetConfirmation() {
        recentCandidates = []
    }

    /// Feeds one recognition result. Returns true when the cursor advanced.
    @discardableResult
    public mutating func feed(_ spokenText: String) -> Bool {
        guard cursor < script.tokens.count else { return false }
        let spokenKinds = ScriptTokenizer.spokenTokens(spokenText).suffix(config.spokenTail)
        guard !spokenKinds.isEmpty else { return false }
        let spoken = spokenKinds.map { kind in
            SpokenToken(
                kind: kind,
                readings: Self.readings(of: kind, options: config.pinyin),
                numberReadings: {
                    if case .number(let value) = kind {
                        return Self.normalized(ChineseNumberReadings.readings(of: value), options: config.pinyin)
                    }
                    return []
                }()
            )
        }

        let low = max(0, cursor - config.contextBehind)
        let high = min(script.tokens.count, cursor + config.windowAhead)
        guard let end = bestAlignmentEnd(sourceRange: low..<high, spoken: spoken) else { return false }

        let candidate = end.sourceEnd
        guard candidate > cursor else { return false }

        recentCandidates.append(candidate)
        if recentCandidates.count > 3 {
            recentCandidates.removeFirst()
        }
        let agreeing = recentCandidates.filter { abs($0 - candidate) <= config.agreementTolerance }.count
        let confirmed = recentCandidates.count >= 2 && agreeing >= 2

        // How much script the speaker skipped to reach the final run of
        // matches. A long burst read in order skips nothing; skipping a
        // sentence skips the whole sentence.
        let skipped = max(0, end.runStart - cursor)
        let commits: Bool
        if skipped <= config.readingSkip {
            commits = end.run >= config.minRunForStep
        } else if skipped <= config.smallSkip {
            commits = end.run >= config.minRunForJump
        } else {
            commits = end.run >= config.minRunForJump && confirmed
        }
        guard commits else { return false }
        cursor = candidate
        return true
    }

    // MARK: - Alignment

    struct SpokenToken {
        let kind: TokenKind
        let readings: Set<String>
        let numberReadings: [NumberReading]
    }

    struct AlignmentEnd: Equatable {
        /// Script token index just past the last matched token.
        let sourceEnd: Int
        let score: Int
        /// Consecutive matched units at the end of the alignment (a number
        /// said as four characters is four units).
        let run: Int
        /// Script index where that final run of matches begins.
        let runStart: Int
    }

    private struct Cell {
        var score = 0
        var run = 0
        /// Script tokens covered by `run`.
        var runTokens = 0
        var endsWithMatch = false
    }

    /// Local alignment of the spoken tokens against the script range, keeping
    /// only alignments that end on the newest spoken token with a match. The
    /// highest score wins; ties go to the end nearest the cursor.
    func bestAlignmentEnd(sourceRange: Range<Int>, spoken: [SpokenToken]) -> AlignmentEnd? {
        let source = Array(sourceRange)
        let rows = source.count
        let columns = spoken.count
        guard rows > 0, columns > 0 else { return nil }
        var table = Array(repeating: Array(repeating: Cell(), count: columns + 1), count: rows + 1)

        for i in 1...rows {
            let sourceIndex = source[i - 1]
            for j in 1...columns {
                var best = Cell()
                func consider(_ score: Int, run: Int = 0, runTokens: Int = 0, match: Bool = false) {
                    guard score > 0 else { return }
                    if score > best.score
                        || (score == best.score && match && !best.endsWithMatch)
                        || (score == best.score && match == best.endsWithMatch && run > best.run) {
                        best = Cell(score: score, run: run, runTokens: runTokens, endsWithMatch: match)
                    }
                }

                let pair = similarity(sourceIndex: sourceIndex, spoken: spoken[j - 1])
                let diagonal = table[i - 1][j - 1]
                if pair > 0 {
                    consider(diagonal.score + pair, run: diagonal.run + 1, runTokens: diagonal.runTokens + 1, match: true)
                } else {
                    consider(diagonal.score + pair)
                }
                consider(table[i - 1][j].score + Self.gapScore)
                consider(table[i][j - 1].score + Self.gapScore)

                // A script number said as several characters (2026 → 二零二六).
                for reading in scriptNumberReadings[sourceIndex] where reading.count <= j {
                    let first = j - reading.count
                    if spokenRun(spoken[first..<j], matches: reading) {
                        let previous = table[i - 1][first]
                        consider(
                            previous.score + Self.numberSyllableScore * reading.count,
                            run: previous.run + reading.count,
                            runTokens: previous.runTokens + 1,
                            match: true
                        )
                    }
                }
                // Script characters recognized as a number (三号楼 → 3号楼).
                for reading in spoken[j - 1].numberReadings where reading.count <= i {
                    let first = i - reading.count
                    if scriptRun(source[first..<i], matches: reading) {
                        let previous = table[first][j - 1]
                        consider(
                            previous.score + Self.numberSyllableScore * reading.count,
                            run: previous.run + reading.count,
                            runTokens: previous.runTokens + reading.count,
                            match: true
                        )
                    }
                }
                table[i][j] = best
            }
        }

        var result: AlignmentEnd?
        for i in 1...rows {
            let cell = table[i][columns]
            guard cell.endsWithMatch, cell.score > 0 else { continue }
            if result == nil || cell.score > result!.score {
                let sourceEnd = source[i - 1] + 1
                result = AlignmentEnd(
                    sourceEnd: sourceEnd,
                    score: cell.score,
                    run: cell.run,
                    runStart: sourceEnd - cell.runTokens
                )
            }
        }
        return result
    }

    private func similarity(sourceIndex: Int, spoken: SpokenToken) -> Int {
        switch (script.tokens[sourceIndex].kind, spoken.kind) {
        case let (.han(a), .han(b)):
            if a == b { return Self.exactScore }
            return scriptReadings[sourceIndex].isDisjoint(with: spoken.readings) ? Self.mismatchScore : Self.soundScore
        case let (.word(a), .word(b)):
            if a == b { return Self.exactScore }
            return LegacyAligner().isFuzzyMatch(a, b) ? Self.soundScore : Self.mismatchScore
        case let (.number(a), .number(b)):
            return a == b ? Self.exactScore : Self.mismatchScore
        default:
            return Self.mismatchScore
        }
    }

    private func spokenRun(_ tokens: ArraySlice<SpokenToken>, matches reading: NumberReading) -> Bool {
        zip(tokens, reading).allSatisfy { token, slot in
            if case .han = token.kind { return !token.readings.isDisjoint(with: slot) }
            return false
        }
    }

    private func scriptRun(_ indices: ArraySlice<Int>, matches reading: NumberReading) -> Bool {
        zip(indices, reading).allSatisfy { index, slot in
            if case .han = script.tokens[index].kind { return !scriptReadings[index].isDisjoint(with: slot) }
            return false
        }
    }

    // MARK: - Readings

    static func readings(of kind: TokenKind, options: PinyinOptions) -> Set<String> {
        if case .han(let character) = kind {
            return Pinyin.readings(of: character, options: options)
        }
        return []
    }

    static func normalized(_ readings: [NumberReading], options: PinyinOptions) -> [NumberReading] {
        guard options.mandarin else { return [] }
        guard options.fuzzy else { return readings }
        return readings.map { reading in reading.map { Set($0.map(Pinyin.fuzzyNormalized)) } }
    }
}

extension ChineseAlignerConfig {
    /// The configuration for a speech recognizer locale, or nil when the
    /// locale is not Chinese and the original follower should be used.
    /// Cantonese (zh-HK, zh-MO, yue) matches characters exactly: Mandarin
    /// pinyin does not describe what that recognizer hears.
    public static func forSpeechLocale(_ identifier: String, fuzzyPinyin: Bool) -> ChineseAlignerConfig? {
        let id = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
        guard id == "zh" || id.hasPrefix("zh-") || id == "yue" || id.hasPrefix("yue-") else { return nil }
        var config = ChineseAlignerConfig()
        config.pinyin.mandarin = !(id.hasPrefix("yue") || id.hasPrefix("zh-hk") || id.hasPrefix("zh-mo"))
        config.pinyin.fuzzy = fuzzyPinyin && config.pinyin.mandarin
        return config
    }
}
