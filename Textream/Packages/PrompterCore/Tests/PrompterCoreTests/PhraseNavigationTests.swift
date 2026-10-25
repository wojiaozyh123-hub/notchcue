//
//  PhraseNavigationTests.swift
//  PrompterCoreTests
//

import Testing
@testable import PrompterCore

@Suite("Phrase navigation")
struct PhraseNavigationTests {
    // Phrases start at tokens 0 (大家好), 3 (今天我们来聊一聊), 11 (考试时间是2026年)
    private let script = TokenizedScript(text: "大家好，今天我们来聊一聊。考试时间是2026年。")

    @Test func phraseStarts() {
        #expect(script.phraseStarts == [0, 3, 11])
        #expect(script.tokens.count == 18)
    }

    @Test func backRestartsTheCurrentPhrase() {
        // Six tokens into 今天我们来聊一聊: back to 今.
        #expect(script.previousPhraseStart(before: 9) == 3)
    }

    @Test func backFromAPhraseStartGoesToThePreviousPhrase() {
        #expect(script.previousPhraseStart(before: 11) == 3)
        // One token in still counts as "just started".
        #expect(script.previousPhraseStart(before: 12) == 3)
        #expect(script.previousPhraseStart(before: 3) == 0)
        #expect(script.previousPhraseStart(before: 0) == 0)
    }

    @Test func forwardGoesToTheNextPhrase() {
        #expect(script.nextPhraseStart(after: 0) == 3)
        #expect(script.nextPhraseStart(after: 5) == 11)
        #expect(script.nextPhraseStart(after: 11) == nil)
    }

    @Test func stepsInDisplayOffsets() {
        let at今 = script.cursorOffset(forToken: 3)
        let at考 = script.cursorOffset(forToken: 11)
        #expect(script.phraseStepOffset(from: script.cursorOffset(forToken: 8), direction: -1) == at今)
        #expect(script.phraseStepOffset(from: at今, direction: 1) == at考)
        #expect(script.phraseStepOffset(from: at考, direction: 1) == nil)
        #expect(script.phraseStepOffset(from: 0, direction: -1) == nil)
    }
}
