//
//  ScriptTokenizer.swift
//  PrompterCore
//
//  Match tokens for the Chinese aligner. The display keeps its own words
//  (`splitTextIntoWords`) and character offsets; tokens are what speech is
//  matched against. Every token remembers where it sits in display offsets,
//  so the aligner's cursor (a token index) converts to the
//  `recognizedCharCount` every display consumer already understands.
//
//  One Chinese character is one token, one Latin word is one token, one number
//  ("2026", "1,000", "3.5", "50%") is one token. Punctuation, emoji and
//  [bracket] annotations produce no tokens; punctuation only marks where a
//  short phrase ends.
//

import Foundation

public enum TokenKind: Equatable, Sendable {
    case han(Character)
    /// Lowercased letters and digits of a non-Chinese word ("iphone", "gpt",
    /// "4o", or a kana/hangul character).
    case word(String)
    /// ASCII digits with an optional ".fraction" and an optional trailing "%".
    /// Thousands separators are removed and full-width digits are converted.
    case number(String)
}

public struct ScriptToken: Equatable, Sendable {
    public let kind: TokenKind
    /// Display offset (words joined by single spaces) where the token starts.
    public let start: Int
    /// Display offset just past the token's characters.
    public let end: Int
    public let wordIndex: Int
}

public struct TokenizedScript: Sendable {
    public let words: [String]
    public let tokens: [ScriptToken]
    /// `words.joined(separator: " ").count`, the display's `totalCharCount`.
    public let totalCount: Int
    /// Token indices that begin a short phrase: the first token, and every
    /// token after punctuation, an annotation, or a paragraph break.
    public let phraseStarts: [Int]

    public init(words: [String], paragraphBreakBeforeWordIndices: Set<Int> = []) {
        self.words = words
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)
        var tokens: [ScriptToken] = []
        var phraseStarts: [Int] = []
        var pendingBreak = true
        var offset = 0
        for (wordIndex, word) in words.enumerated() {
            if paragraphBreakBeforeWordIndices.contains(wordIndex) {
                pendingBreak = true
            }
            if annotationFlags[wordIndex] || ScriptTokenizer.isAnnotationWord(word) {
                if annotationFlags[wordIndex] || word.contains(where: ScriptTokenizer.isPhraseBreak) {
                    pendingBreak = true
                }
            } else {
                for piece in ScriptTokenizer.tokens(inWord: word) {
                    if pendingBreak {
                        phraseStarts.append(tokens.count)
                        pendingBreak = false
                    }
                    tokens.append(ScriptToken(
                        kind: piece.kind,
                        start: offset + piece.range.lowerBound,
                        end: offset + piece.range.upperBound,
                        wordIndex: wordIndex
                    ))
                }
                if let last = word.last, ScriptTokenizer.isPhraseBreak(last) {
                    pendingBreak = true
                }
            }
            offset += word.count + 1
        }
        self.tokens = tokens
        self.phraseStarts = phraseStarts
        self.totalCount = max(0, offset - 1)
    }

    public init(text: String) {
        self.init(
            words: splitTextIntoWords(text),
            paragraphBreakBeforeWordIndices: paragraphBreakWordIndices(in: text)
        )
    }

    /// The display offset to report when `index` tokens have been read: the
    /// start of the next token (so punctuation and annotations before it count
    /// as read), or the full length once everything is read.
    public func cursorOffset(forToken index: Int) -> Int {
        index < tokens.count ? tokens[max(0, index)].start : totalCount
    }

    /// How many tokens lie wholly before a display offset. Inverse of
    /// `cursorOffset(forToken:)`; an offset inside a token leaves that token
    /// unread.
    public func tokenIndex(forOffset offset: Int) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].end <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

public enum ScriptTokenizer {
    static let phraseBreakCharacters: Set<Character> = [
        "，", "。", "！", "？", "；", "：", "、", "…", "—", "–",
        ",", ".", "!", "?", ";", ":",
    ]

    static func isPhraseBreak(_ character: Character) -> Bool {
        phraseBreakCharacters.contains(character)
    }

    /// Same rule the display uses for dimmed words: [bracketed] cues and words
    /// without any letter or digit.
    static func isAnnotationWord(_ word: String) -> Bool {
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        return !word.contains { $0.isLetter || $0.isNumber }
    }

    /// Tokens of recognized speech, in order.
    public static func spokenTokens(_ text: String) -> [TokenKind] {
        splitTextIntoWords(text).flatMap { tokens(inWord: $0).map(\.kind) }
    }

    /// Splits one display word into tokens with character ranges inside the word.
    static func tokens(inWord word: String) -> [(kind: TokenKind, range: Range<Int>)] {
        let chars = Array(word)
        var result: [(kind: TokenKind, range: Range<Int>)] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char.isHan {
                result.append((.han(char), index..<(index + 1)))
                index += 1
                continue
            }
            if char.isCJK {
                // Kana and hangul: matched by exact character.
                result.append((.word(String(char)), index..<(index + 1)))
                index += 1
                continue
            }
            guard isRunCharacter(char) else {
                index += 1
                continue
            }
            let runStart = index
            var hasLetter = false
            while index < chars.count {
                let c = chars[index]
                if c.isHan || c.isCJK { break }
                if c.asciiDigit != nil {
                    index += 1
                } else if c.isLetter {
                    hasLetter = true
                    index += 1
                } else if isNumberSeparator(c, at: index, in: chars) {
                    index += 1
                } else if c == "'" || c == "’",
                          index + 1 < chars.count, chars[index + 1].isLetter,
                          index > runStart, chars[index - 1].isLetter {
                    index += 1
                } else {
                    break
                }
            }
            var runEnd = index
            if !hasLetter, index < chars.count, chars[index] == "%" || chars[index] == "％" {
                index += 1
                runEnd = index
            }
            let run = chars[runStart..<runEnd]
            if hasLetter {
                let text = String(run.compactMap { c -> Character? in
                    if let digit = c.asciiDigit { return digit }
                    return c.isLetter ? c : nil
                }).lowercased()
                if !text.isEmpty {
                    result.append((.word(text), runStart..<runEnd))
                }
            } else {
                result.append((.number(canonicalNumber(run)), runStart..<runEnd))
            }
        }
        return result
    }

    private static func isRunCharacter(_ c: Character) -> Bool {
        c.asciiDigit != nil || c.isLetter
    }

    /// "," between digits followed by exactly three digits is a thousands
    /// separator; "." between digits is a decimal point.
    private static func isNumberSeparator(_ c: Character, at index: Int, in chars: [Character]) -> Bool {
        guard index > 0, chars[index - 1].asciiDigit != nil,
              index + 1 < chars.count, chars[index + 1].asciiDigit != nil else { return false }
        switch c {
        case ".", "．":
            return true
        case ",", "，":
            var digits = 0
            var next = index + 1
            while next < chars.count, chars[next].asciiDigit != nil {
                digits += 1
                next += 1
            }
            return digits == 3
        default:
            return false
        }
    }

    private static func canonicalNumber(_ run: ArraySlice<Character>) -> String {
        var text = ""
        for c in run {
            if let digit = c.asciiDigit {
                text.append(digit)
            } else if c == "." || c == "．" {
                text.append(".")
            } else if c == "%" || c == "％" {
                text.append("%")
            }
        }
        return text
    }
}

extension Character {
    /// Chinese characters (no kana or hangul). 〇 counts: it is read as a digit.
    var isHan: Bool {
        guard unicodeScalars.count == 1, let v = unicodeScalars.first?.value else { return false }
        return (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x20000 && v <= 0x2A6DF)
            || (v >= 0xF900 && v <= 0xFAFF)
            || v == 0x3007
    }

    var isCJK: Bool {
        unicodeScalars.first.map(\.isCJK) == true
    }

    /// ASCII digit for "0"–"9" and full-width "０"–"９".
    var asciiDigit: Character? {
        guard unicodeScalars.count == 1, let v = unicodeScalars.first?.value else { return nil }
        if v >= 0x30 && v <= 0x39 { return self }
        if v >= 0xFF10 && v <= 0xFF19, let scalar = Unicode.Scalar(v - 0xFF10 + 0x30) {
            return Character(scalar)
        }
        return nil
    }
}

// MARK: - Phrase navigation

extension TokenizedScript {
    /// Tokens into a phrase within which "back" still means the phrase before:
    /// pressed right after a new phrase began, the speaker wants the one they
    /// just finished.
    static let phraseRestartSlack = 1

    /// "Back one phrase" from a cursor (tokens read): the start of the phrase
    /// being read, or of the previous one when the cursor is at its start.
    public func previousPhraseStart(before cursor: Int) -> Int {
        guard let current = phraseStarts.last(where: { $0 <= cursor }) else { return 0 }
        if cursor - current > Self.phraseRestartSlack {
            return current
        }
        return phraseStarts.last(where: { $0 < current }) ?? 0
    }

    /// "Forward one phrase": the start of the next phrase, or nil in the last
    /// one (jumping to the end would finish the page).
    public func nextPhraseStart(after cursor: Int) -> Int? {
        phraseStarts.first(where: { $0 > cursor })
    }

    /// Display offset after stepping one phrase back (direction < 0) or
    /// forward from a display offset, or nil when there is nowhere to go.
    public func phraseStepOffset(from offset: Int, direction: Int) -> Int? {
        let cursor = tokenIndex(forOffset: offset)
        let target = direction < 0 ? previousPhraseStart(before: cursor) : nextPhraseStart(after: cursor)
        guard let target, target != cursor else { return nil }
        return cursorOffset(forToken: target)
    }
}
