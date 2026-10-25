//
//  LegacyAndFixtureTests.swift
//  PrompterCoreTests
//

import Foundation
import Testing
@testable import PrompterCore

/// The original follower must behave exactly as before the move. Expected
/// counts were produced by running the unmodified upstream SpeechRecognizer
/// matching code (commit 2c02f3e) on the same inputs.
@Suite("Original English follower")
struct LegacyGoldenTests {
    private let text = "Welcome to Textream! This is your personal teleprompter that sits right below your MacBook's notch. [smile] As you read aloud, the text will highlight in real-time, following your voice."

    private func wordPrefixes(_ transcript: String, step: Int) -> [String] {
        let words = transcript.split(separator: " ").map(String.init)
        var result: [String] = []
        var count = step
        while count < words.count {
            result.append(words.prefix(count).joined(separator: " "))
            count += step
        }
        result.append(transcript)
        return result
    }

    private func counts(_ results: [String]) -> [Int] {
        var aligner = LegacyAligner(words: splitTextIntoWords(text))
        return results.map { result in
            aligner.match(spoken: result)
            return aligner.recognizedCharCount
        }
    }

    @Test func cleanReading() {
        let results = wordPrefixes("Welcome to Textream this is your personal teleprompter that sits right below your MacBook's notch as you read aloud the text will highlight in real time following your voice", step: 2)
        #expect(counts(results) == [11, 26, 34, 56, 66, 78, 93, 111, 120, 131, 141, 154, 165, 180, 186])
    }

    @Test func recognitionErrors() {
        let results = wordPrefixes("welcome to text stream this is your personal teleprompter that sits right below your Mac books notch as you read allowed the text will highlight in real time following your voice", step: 3)
        #expect(counts(results) == [18, 29, 56, 72, 89, 111, 123, 141, 162, 180, 186])
    }

    @Test func revisions() {
        let results = ["Welcome to", "Welcome to Tex", "Welcome to Textream this", "Welcome to Textream this is your person", "Welcome to Textream this is your personal teleprompter"]
        #expect(counts(results) == [11, 17, 26, 41, 56])
    }
}

/// Logs saved by the audio-file debug run, replayed. Drop a log into
/// Tests/PrompterCoreTests/Fixtures to turn a real recording into a
/// regression test. With no logs present this checks nothing.
@Suite("Recorded runs")
struct RecordedRunTests {
    static func logs() -> [(name: String, log: RecognitionRunLog)] {
        guard let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let log = try? decoder.decode(RecognitionRunLog.self, from: data) else { return nil }
            return (url.lastPathComponent, log)
        }
    }

    @Test func replayedRunsMatchTheRecording() {
        for (name, log) in Self.logs() where log.locale.hasPrefix("zh") || log.locale.hasPrefix("yue") {
            let script = TokenizedScript(text: log.script)
            var config = ChineseAlignerConfig()
            config.pinyin.fuzzy = log.fuzzyPinyin
            config.pinyin.mandarin = !(log.locale.hasPrefix("zh-HK") || log.locale.hasPrefix("yue"))
            var aligner = ChineseAligner(script: script, config: config)
            var previous = aligner.cursorOffset
            for entry in log.entries {
                aligner.feed(entry.matchedText)
                #expect(aligner.cursorOffset >= previous, "\(name): moved back at \(entry.time)s")
                previous = aligner.cursorOffset
            }
            #expect(aligner.cursorOffset == log.entries.last?.charCount, "\(name): final position changed")
        }
    }
}
