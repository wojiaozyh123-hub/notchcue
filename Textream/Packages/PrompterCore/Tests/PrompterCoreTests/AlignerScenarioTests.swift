//
//  AlignerScenarioTests.swift
//  PrompterCoreTests
//
//  Feeds the Chinese aligner sequences shaped like SFSpeechRecognizer partial
//  results: each result is the whole transcript so far, and later results may
//  rewrite earlier characters.
//

import Testing
@testable import PrompterCore

private let script = "大家好，今天我们来聊一聊期中考试的安排。考试时间是2026年11月3日，地点在三号楼。请大家提前十分钟到场，带好学生证和iPhone以外的计时工具。"

/// Cumulative transcripts growing by `step` words (a Chinese character, a
/// Latin word or a number each), like partial results.
private func partials(_ transcript: String, step: Int = 3) -> [String] {
    let words = splitTextIntoWords(transcript)
    func join(_ count: Int) -> String {
        var text = ""
        for word in words.prefix(count) {
            if let last = text.last, !last.isHan, let first = word.first, !first.isHan {
                text.append(" ")
            }
            text.append(word)
        }
        return text
    }
    var result: [String] = []
    var count = step
    while count < words.count {
        result.append(join(count))
        count += step
    }
    result.append(join(words.count))
    return result
}

/// Script text from the cursor on, without spaces or punctuation, for
/// readable assertions.
private func remainder(_ aligner: ChineseAligner) -> String {
    aligner.script.tokens.dropFirst(aligner.cursor).map { token -> String in
        switch token.kind {
        case .han(let c): return String(c)
        case .word(let w): return w
        case .number(let n): return n
        }
    }.joined()
}

/// Runs the results through a fresh aligner, checking the cursor never moves
/// back. Returns the aligner and the cursor after each result.
@discardableResult
private func run(
    _ results: [String],
    text: String = script,
    config: ChineseAlignerConfig = ChineseAlignerConfig(),
    sourceLocation: SourceLocation = #_sourceLocation
) -> (aligner: ChineseAligner, cursors: [Int]) {
    var aligner = ChineseAligner(script: TokenizedScript(text: text), config: config)
    var cursors: [Int] = []
    var previous = aligner.cursor
    for result in results {
        aligner.feed(result)
        #expect(aligner.cursor >= previous, "cursor moved back on «\(result)»", sourceLocation: sourceLocation)
        previous = aligner.cursor
        cursors.append(aligner.cursor)
    }
    return (aligner, cursors)
}

@Suite("Chinese aligner scenarios")
struct AlignerScenarioTests {
    @Test func readingStraightThroughFollowsEveryResult() {
        let (aligner, cursors) = run(partials("大家好今天我们来聊一聊期中考试的安排考试时间是2026年11月3日地点在三号楼"))
        #expect(remainder(aligner).hasPrefix("请大家提前"))
        // Ordinary reading never stalls: every result after the first moves on.
        #expect(Set(cursors.dropFirst()).count == cursors.count - 1)
    }

    @Test func homophoneSubstitutionIsAbsorbed() {
        // 期中 recognized as 期终 (same pinyin, qi zhong).
        var (aligner, _) = run(partials("大家好今天我们来聊一聊期终"))
        #expect(remainder(aligner).hasPrefix("考试"), "the homophone at the end of the transcript should count")
        aligner.feed("大家好今天我们来聊一聊期终考试的安排考试时间是")
        #expect(remainder(aligner).hasPrefix("2026"))
    }

    @Test func polyphoneReadingFromTableMatches() {
        // CFStringTransform reads 行 as xing; 银航 (yin hang) only matches
        // through the polyphone table.
        let (aligner, _) = run(["我们去银航"], text: "我们去银行办事")
        #expect(remainder(aligner) == "办事")
    }

    @Test func numbersReadDigitByDigit() {
        var (aligner, _) = run(partials("大家好今天我们来聊一聊期中考试的安排考试时间是二零二六"))
        #expect(remainder(aligner).hasPrefix("年11月"))
        aligner.feed("大家好今天我们来聊一聊期中考试的安排考试时间是二零二六年十一月三日地点在三号楼")
        #expect(remainder(aligner).hasPrefix("请大家"))
    }

    @Test func numbersReadPositionally() {
        let (aligner, _) = run(partials("大家好今天我们来聊一聊期中考试的安排考试时间是两千零二十六年十一月三日"))
        #expect(remainder(aligner).hasPrefix("地点在"))
    }

    @Test func recognizerDigitsMatchChineseNumeralsInScript() {
        // Script writes 三, recognizer writes 3.
        let (aligner, _) = run(["地点在3号楼"], text: "地点在三号楼请大家")
        #expect(remainder(aligner) == "请大家")
    }

    @Test func adLibDoesNotMoveTheCursor() {
        var (aligner, _) = run(["大家好"])
        let afterGreeting = aligner.cursor
        #expect(remainder(aligner).hasPrefix("今天"))
        for result in partials("大家好嗯那个我先说一下天气不错") {
            aligner.feed(result)
            #expect(aligner.cursor == afterGreeting, "moved on ad-lib «\(result)»")
        }
        // Back on script: tracking resumes.
        for result in partials("大家好嗯那个我先说一下天气不错今天我们来聊一聊") {
            aligner.feed(result)
        }
        #expect(remainder(aligner).hasPrefix("期中考试"))
    }

    @Test func skippedSentenceIsJumpedOnceMatchesAreStrong() {
        // The speaker skips 考试时间是2026年11月3日，地点在三号楼 (17 tokens).
        let (aligner, cursors) = run(partials("大家好今天我们来聊一聊期中考试的安排请大家提前十分钟到场带好学生证"))
        #expect(remainder(aligner).hasPrefix("和iphone"))
        // The jump waits for a second result to agree (2-of-3) instead of
        // taking the first one.
        let skipStart = aligner.script.tokens.firstIndex { $0.kind == .han("排") }! + 1
        let stuckAtSkip = cursors.filter { $0 == skipStart }.count
        #expect(stuckAtSkip >= 2)
    }

    @Test func singleMatchFarAheadDoesNotJump() {
        // 考试 alone matches 20 tokens ahead, but a jump needs three
        // consecutive matches and agreement.
        var (aligner, _) = run(["大家好今天"])
        let before = aligner.cursor
        aligner.feed("大家好今天说到考试")
        #expect(aligner.cursor == before)
    }

    @Test func mixedChineseAndEnglish() {
        let lead = "大家好今天我们来聊一聊期中考试的安排考试时间是2026年11月3日地点在三号楼请大家提前十分钟到场带好学生证和"
        let (aligner, _) = run(partials(lead) + [
            lead + "iPhone",
            lead + "iPhone以外的",
            lead + "iPhone以外的计时工具",
        ])
        #expect(aligner.cursor == aligner.script.tokens.count)
        #expect(aligner.cursorOffset == aligner.script.totalCount)
    }

    @Test func englishWordCaseAndSpacingDoNotMatter() {
        let (aligner, _) = run(["学生证和 iphone 以外"], text: "带好学生证和iPhone以外的计时工具")
        #expect(remainder(aligner) == "的计时工具")
    }

    @Test func revisedPartialResults() {
        // 来了 is rewritten to 来聊一聊; a shorter rewrite never moves back.
        let (aligner, _) = run([
            "大家好今天",
            "大家好今天我们来了",
            "大家好今天我们来聊一聊",
            "大家好今天我们来聊一聊期中考试的安排考试",
            "大家好今天我们来聊一聊期中考试的安排",
            "大家好今天我们来聊一聊期中考试的安排考试时间",
        ])
        #expect(remainder(aligner).hasPrefix("是2026"))
    }

    @Test func fuzzyPinyinIsOffByDefault() {
        // 思 (si) for 师 (shi) only matches with fuzzy pinyin on.
        let strict = run(["老思"], text: "老师你好")
        #expect(remainder(strict.aligner) == "老师你好")

        var config = ChineseAlignerConfig()
        config.pinyin.fuzzy = true
        let fuzzy = run(["老思"], text: "老师你好", config: config)
        #expect(remainder(fuzzy.aligner) == "你好")
    }

    @Test func cantoneseMatchesCharactersExactly() {
        var config = ChineseAlignerConfig()
        config.pinyin.mandarin = false
        let (homophone, _) = run(["期终"], text: "期中考试", config: config)
        #expect(homophone.cursor == 0)
        let (exact, _) = run(["期中"], text: "期中考试", config: config)
        #expect(remainder(exact) == "考试")
    }

    @Test func cursorNeverMovesBackOnNoise() {
        var aligner = ChineseAligner(script: TokenizedScript(text: script))
        var transcript = ""
        var previous = 0
        let pieces = ["大家", "好", "嗯", "今天", "我们", "那个", "来聊", "一聊", "期终", "啊", "考试", "的", "安排",
                      "考试时间", "是", "2026", "年", "这个", "11", "月", "3", "日", "地点", "呃", "在三号楼"]
        for piece in pieces {
            transcript += piece
            aligner.feed(transcript)
            #expect(aligner.cursor >= previous)
            previous = aligner.cursor
        }
        #expect(remainder(aligner).hasPrefix("请大家"))
    }

    @Test func explicitJumpCanGoBack() {
        var (aligner, _) = run(partials("大家好今天我们来聊一聊期中考试"))
        aligner.setCursor(3)
        #expect(remainder(aligner).hasPrefix("今天"))
        aligner.feed("今天我们")
        #expect(remainder(aligner).hasPrefix("来聊"))
    }
}

@Suite("Locale routing")
struct LocaleRoutingTests {
    @Test func chineseLocalesUseTheChineseAligner() {
        #expect(ChineseAlignerConfig.forSpeechLocale("zh-CN", fuzzyPinyin: false)?.pinyin.mandarin == true)
        #expect(ChineseAlignerConfig.forSpeechLocale("zh_TW", fuzzyPinyin: true)?.pinyin.fuzzy == true)
        #expect(ChineseAlignerConfig.forSpeechLocale("zh-HK", fuzzyPinyin: true)?.pinyin.mandarin == false)
        #expect(ChineseAlignerConfig.forSpeechLocale("zh-HK", fuzzyPinyin: true)?.pinyin.fuzzy == false)
        #expect(ChineseAlignerConfig.forSpeechLocale("yue-CN", fuzzyPinyin: false)?.pinyin.mandarin == false)
    }

    @Test func otherLocalesKeepTheOriginalFollower() {
        #expect(ChineseAlignerConfig.forSpeechLocale("en-US", fuzzyPinyin: false) == nil)
        #expect(ChineseAlignerConfig.forSpeechLocale("ja-JP", fuzzyPinyin: false) == nil)
    }
}
