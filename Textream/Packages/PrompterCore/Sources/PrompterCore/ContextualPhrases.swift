//
//  ContextualPhrases.swift
//  PrompterCore
//
//  `contextualStrings` hints for the speech recognizer, built from the script
//  still to be read.
//

import Foundation
import NaturalLanguage

public enum ContextualPhrases {
    /// The original hints, moved unchanged: up to 50 distinct upcoming words
    /// of five or more letters. Every Chinese character is its own one-letter
    /// word here, so Chinese scripts produce no hints from this.
    public static func legacy(sourceText: String, matchStartOffset: Int) -> [String] {
        let upcoming = String(sourceText.dropFirst(matchStartOffset))
        let contextWords = upcoming.split(separator: " ")
            .map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { $0.count >= 5 }
        return Array(Set(contextWords).prefix(50))
    }

    /// Chinese hints: the upcoming script split into clauses at punctuation,
    /// each clause cut at word boundaries into phrases of 2–6 characters, in
    /// reading order. A Latin word or a number counts as one character.
    public static func chinese(
        words: [String],
        fromWord startWord: Int,
        maxLength: Int = 6,
        limit: Int = 50
    ) -> [String] {
        guard startWord < words.count else { return [] }
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)
        var phrases: [String] = []
        var seen = Set<String>()
        var clause: [String] = []

        func flushClause() {
            defer { clause = [] }
            guard !clause.isEmpty else { return }
            for phrase in phrasesInClause(clause, maxLength: maxLength) where !seen.contains(phrase) {
                seen.insert(phrase)
                phrases.append(phrase)
            }
        }

        for index in max(0, startWord)..<words.count {
            if phrases.count >= limit { break }
            let word = words[index]
            if annotationFlags[index] || ScriptTokenizer.isAnnotationWord(word) {
                flushClause()
                continue
            }
            let text = word.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "%" }
            if !text.isEmpty { clause.append(text) }
            if let last = word.last, ScriptTokenizer.isPhraseBreak(last) {
                flushClause()
            }
        }
        flushClause()
        return Array(phrases.prefix(limit))
    }

    /// One clause (display words without punctuation) → phrases.
    static func phrasesInClause(_ clauseWords: [String], maxLength: Int) -> [String] {
        // Rejoin the way it is read: no spaces between Chinese characters,
        // a space between neighbouring Latin words or numbers.
        var text = ""
        for word in clauseWords {
            if let last = text.last, !last.isHan, let first = word.first, !first.isHan {
                text.append(" ")
            }
            text.append(word)
        }

        var segments: [String] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            segments.append(String(text[range]))
            return true
        }

        func length(_ segment: String) -> Int {
            segment.contains(where: \.isHan) ? segment.filter(\.isHan).count : 1
        }
        func join(_ parts: [String]) -> String {
            var out = ""
            for part in parts {
                if let last = out.last, !last.isHan, let first = part.first, !first.isHan {
                    out.append(" ")
                }
                out.append(part)
            }
            return out
        }

        var phrases: [(parts: [String], length: Int)] = []
        var current: [String] = []
        var currentLength = 0
        func flush() {
            defer { current = []; currentLength = 0 }
            guard !current.isEmpty else { return }
            if currentLength < 2 && current.allSatisfy({ $0.contains(where: \.isHan) }) {
                // A lone character is a poor hint: attach it to the previous
                // phrase when that still fits, otherwise drop it.
                if let last = phrases.last, last.length + currentLength <= maxLength {
                    phrases[phrases.count - 1] = (last.parts + current, last.length + currentLength)
                }
                return
            }
            phrases.append((current, currentLength))
        }

        for segment in segments {
            let segmentLength = length(segment)
            if segmentLength > maxLength {
                flush()
                // A long word: cut it into maxLength pieces.
                var rest = Substring(segment)
                while !rest.isEmpty {
                    current = [String(rest.prefix(maxLength))]
                    currentLength = min(maxLength, rest.count)
                    rest = rest.dropFirst(maxLength)
                    flush()
                }
                continue
            }
            if currentLength + segmentLength > maxLength {
                flush()
            }
            current.append(segment)
            currentLength += segmentLength
        }
        flush()
        return phrases.map { join($0.parts) }
    }
}
