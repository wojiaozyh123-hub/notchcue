//
//  TextUnitTests.swift
//  PrompterCoreTests
//
//  Tokens and display offsets, pinyin, number readings, recognizer hints.
//

import Testing
@testable import PrompterCore

@Suite("Tokens and display offsets")
struct TokenizerTests {
    @Test func tokensMapToDisplayOffsets() {
        let script = TokenizedScript(text: "期中考试2026年iPhone，好")
        #expect(script.words == ["期", "中", "考", "试", "2026", "年", "iPhone，", "好"])
        #expect(script.tokens.map(\.kind) == [
            .han("期"), .han("中"), .han("考"), .han("试"),
            .number("2026"), .han("年"), .word("iphone"), .han("好"),
        ])
        // Display text is the words joined by single spaces.
        #expect(script.tokens.map(\.start) == [0, 2, 4, 6, 8, 13, 15, 23])
        #expect(script.tokens[6].end == 21)
        #expect(script.totalCount == 24)
        #expect(script.phraseStarts == [0, 7])
    }

    @Test func cursorOffsetAndTokenIndexAreInverse() {
        let script = TokenizedScript(text: "[smile] 大家好，今天 [pause] 我们 Hello, world.")
        for index in 0...script.tokens.count {
            #expect(script.tokenIndex(forOffset: script.cursorOffset(forToken: index)) == index)
        }
        // Leading annotation is already read at the start.
        #expect(script.cursorOffset(forToken: 0) == script.tokens[0].start)
        #expect(script.cursorOffset(forToken: script.tokens.count) == script.totalCount)
        // An offset inside a word leaves that token unread.
        let hello = script.tokens.firstIndex { $0.kind == .word("hello") }!
        #expect(script.tokenIndex(forOffset: script.tokens[hello].start + 2) == hello)
    }

    @Test func annotationsAndPunctuationBreakPhrases() {
        let script = TokenizedScript(text: "[smile] 大家好 [pause] 谢谢。再见")
        #expect(script.tokens.count == 7)
        #expect(script.phraseStarts == [0, 3, 5])
    }

    @Test func paragraphBreakStartsPhrase() {
        let script = TokenizedScript(text: "第一段\n\n第二段")
        #expect(script.phraseStarts == [0, 3])
    }

    @Test func numberForms() {
        func kinds(_ text: String) -> [TokenKind] { ScriptTokenizer.spokenTokens(text) }
        #expect(kinds("共1,000人") == [.han("共"), .number("1000"), .han("人")])
        #expect(kinds("增长3.5%") == [.han("增"), .han("长"), .number("3.5%")])
        #expect(kinds("１２３") == [.number("123")])
        #expect(kinds("1,2,3") == [.number("1"), .number("2"), .number("3")])
        #expect(kinds("二〇二六") == [.han("二"), .han("〇"), .han("二"), .han("六")])
    }

    @Test func latinWords() {
        func kinds(_ text: String) -> [TokenKind] { ScriptTokenizer.spokenTokens(text) }
        #expect(kinds("Hello, world.") == [.word("hello"), .word("world")])
        #expect(kinds("GPT-4o") == [.word("gpt"), .word("4o")])
        #expect(kinds("don't") == [.word("dont")])
        #expect(kinds("mp3") == [.word("mp3")])
    }
}

@Suite("Pinyin")
struct PinyinTests {
    @Test func homophonesShareReadings() {
        #expect(Pinyin.primarySyllable(of: "期") == "qi")
        #expect(Pinyin.primarySyllable(of: "中") == "zhong")
        #expect(Pinyin.primarySyllable(of: "终") == "zhong")
        #expect(Pinyin.primarySyllable(of: "A") == nil)
        #expect(Pinyin.primarySyllable(of: "，") == nil)
    }

    @Test func polyphonesCarryEveryReading() {
        let options = PinyinOptions()
        #expect(Pinyin.readings(of: "行", options: options) == ["xing", "hang"])
        #expect(Pinyin.readings(of: "乐", options: options).contains("yue"))
        #expect(Pinyin.readings(of: "觉", options: options).contains("jiao"))
        #expect(Pinyin.readings(of: "〇", options: options) == ["ling"])
    }

    @Test func fuzzyPairsCollapse() {
        let pairs = [("zhong", "zong"), ("chi", "ci"), ("shi", "si"), ("nan", "lan"),
                     ("lang", "lan"), ("feng", "fen"), ("xing", "xin"), ("niang", "lian")]
        for (a, b) in pairs {
            #expect(Pinyin.fuzzyNormalized(a) == Pinyin.fuzzyNormalized(b), "\(a) / \(b)")
        }
        #expect(Pinyin.fuzzyNormalized("ng") == "ng")
        #expect(Pinyin.fuzzyNormalized("zhong") != Pinyin.fuzzyNormalized("zhang"))
    }

    @Test func cantoneseHasNoMandarinReadings() {
        #expect(Pinyin.readings(of: "中", options: PinyinOptions(mandarin: false)).isEmpty)
    }
}

@Suite("Number readings")
struct NumberReadingTests {
    /// True when some reading of `number` accepts the space-separated pinyin.
    private func accepts(_ number: String, _ pinyin: String) -> Bool {
        let syllables = pinyin.split(separator: " ").map(String.init)
        return ChineseNumberReadings.readings(of: number).contains { reading in
            reading.count == syllables.count && zip(reading, syllables).allSatisfy { $0.contains($1) }
        }
    }

    @Test func years() {
        #expect(accepts("2026", "er ling er liu"))
        #expect(accepts("2026", "liang qian ling er shi liu"))
        #expect(accepts("2026", "er qian ling er shi liu"))
        #expect(!accepts("2026", "er qian er shi liu"))
        #expect(!accepts("2026", "liang ling er liu"))
    }

    @Test func tens() {
        #expect(accepts("10", "shi"))
        #expect(accepts("10", "yi shi"))
        #expect(accepts("11", "shi yi"))
        #expect(accepts("11", "yi shi yi"))
        #expect(accepts("15", "shi wu"))
        #expect(accepts("12", "shi er"))
        #expect(!accepts("12", "shi liang"))
        #expect(accepts("20", "er shi"))
        #expect(!accepts("20", "liang shi"))
    }

    @Test func twoAsLiang() {
        #expect(accepts("2", "liang"))
        #expect(accepts("2", "er"))
        #expect(accepts("200", "liang bai"))
        #expect(accepts("20000", "liang wan"))
        #expect(accepts("10002", "yi wan ling er"))
        #expect(!accepts("10002", "yi wan ling liang"))
    }

    @Test func zerosAndLargeUnits() {
        #expect(accepts("110", "yi bai yi shi"))
        #expect(accepts("1005", "yi qian ling wu"))
        #expect(accepts("1050", "yi qian ling wu shi"))
        #expect(accepts("1000", "yi qian"))
        #expect(accepts("10000", "yi wan"))
        #expect(accepts("10050", "yi wan ling wu shi"))
        #expect(accepts("150000", "shi wu wan"))
        #expect(accepts("150000", "yi shi wu wan"))
        #expect(accepts("100000000", "yi yi"))
        #expect(accepts("100000001", "yi yi ling yi"))
        #expect(accepts("0", "ling"))
    }

    @Test func digitByDigit() {
        #expect(accepts("110", "yao yao ling"))
        #expect(accepts("007", "ling ling qi"))
        #expect(!accepts("007", "qi"))
        #expect(accepts("1234567890123", "yi er san si wu liu qi ba jiu ling yi er san"))
    }

    @Test func decimalsAndPercent() {
        #expect(accepts("3.5", "san dian wu"))
        #expect(accepts(".5", "ling dian wu"))
        #expect(accepts("50%", "bai fen zhi wu shi"))
        #expect(accepts("3.5%", "bai fen zhi san dian wu"))
    }
}

@Suite("Recognizer hints")
struct ContextualPhraseTests {
    private let text = "大家好，今天我们来聊一聊期中考试的安排。考试时间是2026年11月3日，地点在三号楼。请大家提前十分钟到场，带好学生证和iPhone以外的计时工具。"

    private func units(_ phrase: String) -> Int {
        let han = phrase.filter(\.isHan).count
        let latin = phrase.split(whereSeparator: { $0.isHan || $0 == " " }).count
        return han + latin
    }

    @Test func phrasesAreShortAndInReadingOrder() {
        let words = splitTextIntoWords(text)
        let phrases = ContextualPhrases.chinese(words: words, fromWord: 0)
        #expect(!phrases.isEmpty)
        #expect(phrases.count <= 50)
        let flat = text.filter { !ScriptTokenizer.isPhraseBreak($0) }
        var searchFrom = flat.startIndex
        for phrase in phrases {
            #expect((2...6).contains(units(phrase)) || phrase.allSatisfy({ !$0.isHan }), "«\(phrase)»")
            let needle = phrase.replacingOccurrences(of: " ", with: "")
            guard let range = flat.range(of: needle, range: searchFrom..<flat.endIndex) else {
                Issue.record("«\(phrase)» not found in reading order")
                continue
            }
            searchFrom = range.upperBound
        }
        #expect(phrases.first?.hasPrefix("大家") == true)
        #expect(phrases.contains { $0.contains("iPhone") })
    }

    @Test func phrasesStartAtTheCursor() {
        let words = splitTextIntoWords(text)
        let start = words.firstIndex(of: "请")!
        let phrases = ContextualPhrases.chinese(words: words, fromWord: start)
        #expect(phrases.first?.hasPrefix("请") == true)
        #expect(!phrases.contains { $0.contains("考试") })
    }

    @Test func limitIsRespected() {
        let long = String(repeating: "今天天气很好我们一起出去玩，", count: 80)
        let phrases = ContextualPhrases.chinese(words: splitTextIntoWords(long), fromWord: 0, limit: 50)
        #expect(phrases.count <= 50)
    }

    @Test func legacyHintsDropChinese() {
        let words = splitTextIntoWords(text)
        let hints = ContextualPhrases.legacy(sourceText: words.joined(separator: " "), matchStartOffset: 0)
        #expect(hints.allSatisfy { !$0.contains(where: \.isHan) })
    }
}
