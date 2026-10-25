//
//  RecognitionRunLog.swift
//  PrompterCore
//
//  What the audio-file debug run records: every recognition result and where
//  the cursor ended up. Saved logs can be dropped into
//  Tests/PrompterCoreTests/Fixtures to replay a real recording in tests.
//

import Foundation

public struct RecognitionRunLog: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        /// Seconds since the run started.
        public var time: Double
        /// The recognizer's transcript for this result.
        public var transcript: String
        /// The part matched against the script (the transcript after the last
        /// jump anchor).
        public var matchedText: String
        public var isFinal: Bool
        /// `recognizedCharCount` after this result.
        public var charCount: Int

        public init(time: Double, transcript: String, matchedText: String, isFinal: Bool, charCount: Int) {
            self.time = time
            self.transcript = transcript
            self.matchedText = matchedText
            self.isFinal = isFinal
            self.charCount = charCount
        }
    }

    public var script: String
    public var locale: String
    public var fuzzyPinyin: Bool
    /// "fast" (SFSpeechURLRecognitionRequest) or "realtime" (played back
    /// through the live buffer pipeline).
    public var mode: String
    public var audioFile: String
    public var onDevice: Bool
    public var entries: [Entry] = []

    public init(script: String, locale: String, fuzzyPinyin: Bool, mode: String, audioFile: String, onDevice: Bool) {
        self.script = script
        self.locale = locale
        self.fuzzyPinyin = fuzzyPinyin
        self.mode = mode
        self.audioFile = audioFile
        self.onDevice = onDevice
    }
}
