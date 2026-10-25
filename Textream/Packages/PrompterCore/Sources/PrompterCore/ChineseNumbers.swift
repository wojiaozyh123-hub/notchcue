//
//  ChineseNumbers.swift
//  PrompterCore
//
//  How a written number can be said in Mandarin, as pinyin, so "2026" in the
//  script matches 二零二六 / 两千零二十六 in the transcript (and 三 in the
//  script matches a recognized "3"). A reading is a sequence of slots; each
//  slot lists the syllables accepted at that position (2 before 千/百/万/亿 can
//  be er or liang, 1 read digit by digit can be yi or yao).
//

import Foundation

public typealias NumberReading = [Set<String>]

public enum ChineseNumberReadings {
    /// Largest integer read positionally (below one trillion, 万亿). Longer
    /// numbers are only read digit by digit.
    static let maxPositionalDigits = 12

    private static let digitSyllables: [Set<String>] = [
        ["ling"], ["yi", "yao"], ["er"], ["san"], ["si"],
        ["wu"], ["liu"], ["qi"], ["ba"], ["jiu"],
    ]
    private static let positionalDigitSyllables: [String] = [
        "ling", "yi", "er", "san", "si", "wu", "liu", "qi", "ba", "jiu",
    ]

    /// All readings of a canonical number token (see `TokenKind.number`).
    public static func readings(of number: String) -> [NumberReading] {
        var body = Substring(number)
        let isPercent = body.hasSuffix("%")
        if isPercent { body = body.dropLast() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard let integerPart = parts.first, parts.count <= 2,
              integerPart.allSatisfy(\.isNumber) else { return [] }
        let integerDigits = integerPart.compactMap(\.wholeNumberValue)
        let fractionDigits = parts.count == 2 ? parts[1].compactMap(\.wholeNumberValue) : []
        if parts.count == 2 && fractionDigits.isEmpty { return [] }

        var integerReadings: [NumberReading] = []
        if !integerDigits.isEmpty {
            integerReadings.append(integerDigits.map { digitSyllables[$0] })
            let hasLeadingZero = integerDigits.count > 1 && integerDigits[0] == 0
            if !hasLeadingZero && integerDigits.count <= maxPositionalDigits {
                integerReadings.append(contentsOf: positional(integerDigits))
            }
        } else if !fractionDigits.isEmpty {
            // ".5" is read 零点五
            integerReadings.append([["ling"]])
        }

        var fraction: NumberReading = []
        if !fractionDigits.isEmpty {
            fraction = [["dian"]] + fractionDigits.map { digitSyllables[$0] }
        }

        var result: [NumberReading] = []
        for reading in integerReadings {
            let full = (isPercent ? [["bai"], ["fen"], ["zhi"]] : []) + reading + fraction
            if !result.contains(full) {
                result.append(full)
            }
        }
        return result
    }

    /// 二千零二十六 style readings. Returns two when the number starts with
    /// 1 in the tens place (十五 and 一十五).
    static func positional(_ digits: [Int]) -> [NumberReading] {
        if digits.allSatisfy({ $0 == 0 }) { return [[["ling"]]] }

        // Groups of four from the right: units, 万, 亿.
        var groups: [[Int]] = []
        var end = digits.count
        while end > 0 {
            let start = max(0, end - 4)
            let group = Array(digits[start..<end])
            groups.insert(Array(repeating: 0, count: 4 - group.count) + group, at: 0)
            end = start
        }
        let groupUnits = ["", "wan", "yi"]

        var withLeadingOne: NumberReading = []
        var omittingLeadingOne: NumberReading? = nil
        var started = false
        var zeroPending = false
        for (position, group) in groups.enumerated() {
            let groupIndex = groups.count - 1 - position
            let groupValue = group.reduce(0) { $0 * 10 + $1 }
            if groupValue == 0 {
                if started { zeroPending = true }
                continue
            }
            if started && (zeroPending || group[0] == 0) {
                withLeadingOne.append(["ling"])
                omittingLeadingOne?.append(["ling"])
            }
            zeroPending = false
            let section = sectionReading(group, isLeading: !started, groupIndex: groupIndex)
            if !started, section.startsWithTensOne {
                omittingLeadingOne = Array(section.slots.dropFirst())
            } else {
                omittingLeadingOne?.append(contentsOf: section.slots)
            }
            withLeadingOne.append(contentsOf: section.slots)
            if !groupUnits[groupIndex].isEmpty {
                withLeadingOne.append([groupUnits[groupIndex]])
                omittingLeadingOne?.append([groupUnits[groupIndex]])
            }
            started = true
        }
        if let omittingLeadingOne {
            return [omittingLeadingOne, withLeadingOne]
        }
        return [withLeadingOne]
    }

    /// One four-digit group, e.g. [2, 0, 2, 6] → 二千零二十六.
    private static func sectionReading(
        _ group: [Int],
        isLeading: Bool,
        groupIndex: Int
    ) -> (slots: NumberReading, startsWithTensOne: Bool) {
        let units = ["qian", "bai", "shi", ""]
        let groupValue = group.reduce(0) { $0 * 10 + $1 }
        var slots: NumberReading = []
        var startsWithTensOne = false
        var any = false
        var zeroPending = false
        for (place, digit) in group.enumerated() {
            if digit == 0 {
                if any { zeroPending = true }
                continue
            }
            if zeroPending {
                slots.append(["ling"])
                zeroPending = false
            }
            var syllables: Set<String> = [positionalDigitSyllables[digit]]
            if digit == 2 {
                // 两千, 两百, 两万, and a bare 2 (两个); never 两十 or 十两.
                let beforeBigUnit = place <= 1
                let bareTwo = place == 3 && groupValue == 2 && (groupIndex > 0 || isLeading)
                if beforeBigUnit || bareTwo { syllables.insert("liang") }
            }
            if place == 2 && digit == 1 && isLeading && !any {
                startsWithTensOne = true
            }
            slots.append(syllables)
            if !units[place].isEmpty {
                slots.append([units[place]])
            }
            any = true
        }
        return (slots, startsWithTensOne)
    }
}
