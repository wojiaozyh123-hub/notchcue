//
//  SpeechRecognizer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Foundation
import Speech
import AVFoundation
import CoreAudio
import PrompterCore

private let waveformUpdatesPerSecond = 20.0
private let speechCaptureBuffersPerSecond = 40.0

func speechCaptureFormat(for hardwareFormat: AVAudioFormat) -> AVAudioFormat? {
    guard hardwareFormat.channelCount > 1 else { return hardwareFormat }

    // An input-node tap must use the hardware sample rate. AVAudioEngine can
    // downmix channels here, but requesting a different rate raises an
    // uncaught AVFAudio format-mismatch exception on high-rate USB devices.
    return AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: hardwareFormat.sampleRate,
        channels: 1,
        interleaved: false
    )
}

func speechCaptureBufferSize(for format: AVAudioFormat) -> AVAudioFrameCount {
    AVAudioFrameCount(max(1024, format.sampleRate / speechCaptureBuffersPerSecond))
}

enum DebugAudioMode: String {
    /// SFSpeechURLRecognitionRequest: the file is recognized as fast as the
    /// recognizer can go. For logs, not for watching the overlay.
    case fast
    /// The file is played through the audio engine at real speed and fed to
    /// the same buffer request, restarts and matching as the microphone.
    case realtime
}

struct DebugAudioRun {
    let url: URL
    let mode: DebugAudioMode
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &uid) { uidPointer in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, uidPointer)
            }
            guard uidStatus == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameStatus = withUnsafeMutablePointer(to: &name) { namePointer in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, namePointer)
            }
            guard nameStatus == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid as String, name: name as String))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}

@Observable
class SpeechRecognizer {
    var recognizedCharCount: Int = 0
    var isListening: Bool = false
    var isStarting: Bool = false
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false
    /// Bumped whenever the position is set rather than recognized (new
    /// script, tap, hotkey), so displays can move there at once instead of
    /// animating.
    var cursorJumpCount: Int = 0

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        voiceActivityDetector.isActive(at: ProcessInfo.processInfo.systemUptime)
    }

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var sourceText: String = ""
    /// The script as passed to start/updateText. Kept so resume() can rebuild
    /// the aligner when the speech language or fuzzy setting changed.
    private var scriptText: String = ""
    private var annotationRanges: [Range<Int>] = []
    /// Follows the script for Chinese speech locales (including mixed
    /// Chinese/English); nil means the original Textream follower.
    private var chineseAligner: ChineseAligner?
    private var voiceActivityDetector = VoiceActivityDetector()
    private var matchStartOffset: Int = 0  // char offset to start matching from
    private var retryCount: Int = 0
    private let maxRetries: Int = 10
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var recognitionGeneration: Int = 0
    private var shouldListen: Bool = false
    private var suppressConfigChange: Bool = false
    private var requestLock = NSLock()
    private var preemptiveRestartTimer: Timer?
    /// Sliding window of recent match positions for confidence gating.
    /// We require 2-of-3 recent results to agree before committing a forward jump.
    private var recentMatchPositions: [Int] = []
    /// Transcript prefix to ignore when matching — set on jumps so the task
    /// can keep running instead of being restarted (a restart loses the words
    /// the user re-speaks right after the jump). Stored as the prefix string,
    /// not a char count: partial results revise earlier text, and trimming by
    /// the surviving common prefix avoids swallowing post-jump speech when
    /// the pre-jump portion changes length. Cleared whenever a new
    /// recognition task starts a fresh transcript.
    private var spokenAnchorPrefix: String = ""
    /// Results computed before a jump can be delivered after it; matching
    /// ignores results for a short window so pre-jump speech isn't matched
    /// against the text at the new offset.
    private var lastJumpAt: Date = .distantPast

    /// An audio-file debug run to use instead of the microphone. Set before
    /// the overlay starts listening; `start(with:)` takes it.
    var pendingDebugAudio: DebugAudioRun?
    private var debugAudio: DebugAudioRun?
    private var debugPlayer: AVAudioPlayerNode?
    private var runLog: RecognitionRunLog?
    private var runStartedAt = Date()
    private var debugRunFinishWork: DispatchWorkItem?
    private var debugPlaybackDone = false

    /// Update the source text while preserving the current recognized char count.
    /// Used by Director Mode to live-edit unread text without resetting read progress.
    func updateText(_ text: String, preservingCharCount: Int) {
        cursorJumpCount &+= 1
        loadScript(text)
        recognizedCharCount = settledCursor(at: min(preservingCharCount, sourceText.count))
        matchStartOffset = recognizedCharCount
        resetMatchConfirmation()
    }

    /// Jump highlight to a specific char offset (e.g. when user taps a word).
    /// Nearby jumps keep the recognition task alive and anchor matching past
    /// the already-spoken transcript, so tracking resumes on the first
    /// re-spoken word. Far jumps restart the task instead: contextualStrings
    /// are built for the section being read, and after a page-scale jump
    /// stale hints hurt recognition more than the task warm-up costs.
    /// retryCount is deliberately not touched here — resetting it on every
    /// tap would let a user keep a failing availability-retry loop alive
    /// forever.
    func jumpTo(charOffset: Int) {
        let clampedOffset = max(0, min(charOffset, sourceText.count))
        let targetOffset = settledCursor(at: clampedOffset)
        let distance = abs(targetOffset - recognizedCharCount)
        cursorJumpCount &+= 1
        recognizedCharCount = targetOffset
        matchStartOffset = targetOffset
        resetMatchConfirmation()
        if isListening && (distance > 500 || !audioEngine.isRunning) {
            // Far jump, or the engine died without a config-change callback —
            // fall back to a full restart (also refreshes contextualStrings).
            restartRecognition(resetRetryCount: false)
            return
        }
        spokenAnchorPrefix = lastSpokenText
        lastJumpAt = Date()
    }

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()
        // A page change starts over without stop(); save that run's log.
        endDebugRun()

        cursorJumpCount &+= 1
        loadScript(text)
        recognizedCharCount = settledCursor(at: 0)
        matchStartOffset = recognizedCharCount
        retryCount = 0
        resetMatchConfirmation()
        debugAudio = pendingDebugAudio
        pendingDebugAudio = nil
        if let debugAudio {
            beginRunLog(for: debugAudio)
        }
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    private func requestMicrophoneAccessAndBegin(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }

        // An audio-file run never opens the microphone.
        if debugAudio != nil {
            beginAfterMicrophoneAccess(for: generation)
            return
        }

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            failListening("Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow 刘海提词.")
            openMicrophoneSettings()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self,
                          self.shouldListen,
                          self.sessionGeneration == generation else { return }
                    if granted {
                        self.beginAfterMicrophoneAccess(for: generation)
                    } else {
                        self.failListening("Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow 刘海提词.")
                    }
                }
            }
        case .authorized:
            beginAfterMicrophoneAccess(for: generation)
        @unknown default:
            failListening("Microphone authorization is unavailable.")
        }
    }

    private func beginAfterMicrophoneAccess(for generation: Int) {
        guard shouldListen, sessionGeneration == generation else { return }
        if NotchSettings.shared.listeningMode == .wordTracking {
            requestSpeechAuthAndBegin(for: generation)
        } else {
            beginRecognition()
        }
    }

    private func requestSpeechAuthAndBegin(for generation: Int) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == generation else { return }
                switch status {
                case .authorized:
                    self.beginRecognition()
                default:
                    self.failListening("Speech recognition not authorized. Open System Settings → Privacy & Security → Speech Recognition to allow 刘海提词.")
                    self.openSpeechRecognitionSettings()
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    private func failListening(_ message: String) {
        voiceActivityDetector.reset()
        shouldListen = false
        isListening = false
        isStarting = false
        error = message
        cleanupRecognition()
    }

    func stop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        endDebugRun()
        cleanupRecognition()
    }

    func forceStop() {
        shouldListen = false
        sessionGeneration &+= 1
        isListening = false
        isStarting = false
        sourceText = ""
        scriptText = ""
        annotationRanges = []
        chineseAligner = nil
        retryCount = maxRetries
        recentMatchPositions = []
        endDebugRun()
        cleanupRecognition()
    }

    func resume() {
        guard !sourceText.isEmpty else { return }
        cleanupRecognition()
        retryCount = 0
        // Picks up a speech language or fuzzy-pinyin change made while paused.
        loadScript(scriptText)
        recognizedCharCount = settledCursor(at: recognizedCharCount)
        matchStartOffset = recognizedCharCount
        resetMatchConfirmation()
        shouldDismiss = false
        error = nil
        sessionGeneration &+= 1
        shouldListen = true
        isListening = false
        isStarting = true
        requestMicrophoneAccessAndBegin(for: sessionGeneration)
    }

    private func cleanupRecognitionTask() {
        recognitionGeneration &+= 1
        // Cancel any pending restart to prevent overlapping beginRecognition calls
        pendingRestart?.cancel()
        pendingRestart = nil

        stopPreemptiveTimer()

        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func cleanupAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if let debugPlayer {
            // Real-time audio-file run: the engine has no microphone input,
            // and touching inputNode would create one.
            debugPlayer.removeTap(onBus: 0)
            debugPlayer.stop()
            audioEngine.detach(debugPlayer)
            self.debugPlayer = nil
        } else {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    private func cleanupRecognition() {
        cleanupRecognitionTask()
        cleanupAudioEngine()
        voiceActivityDetector.reset()
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    /// Any previously scheduled restart is cancelled before the new one is queued.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        guard shouldListen, !sourceText.isEmpty else { return }
        isListening = false
        isStarting = true
        let expectedSessionGeneration = sessionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldListen,
                  self.sessionGeneration == expectedSessionGeneration,
                  !self.sourceText.isEmpty else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginRecognition() {
        guard shouldListen, !sourceText.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        let expectedSessionGeneration = sessionGeneration
        let requiresSpeechRecognition = NotchSettings.shared.listeningMode == .wordTracking
        // Ensure clean state
        cleanupRecognition()
        guard shouldListen, sessionGeneration == expectedSessionGeneration else {
            isListening = false
            isStarting = false
            return
        }
        isListening = false
        isStarting = true
        // New session = fresh transcript (see restartTask for why
        // lastSpokenText must be cleared alongside the anchor)
        spokenAnchorPrefix = ""
        lastSpokenText = ""

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()
        suppressConfigChange = false

        // Set selected microphone if configured
        let micUID = NotchSettings.shared.selectedMicUID
        if debugAudio == nil, !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            // Suppress config-change observer during our own device switch
            suppressConfigChange = true
            let inputUnit = audioEngine.inputNode.audioUnit
            if let audioUnit = inputUnit {
                var devID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                // Re-initialize audio unit so it picks up the new device's format
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            // Allow config changes again after a settle period
            let expectedSessionGeneration = sessionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.suppressConfigChange = false
            }
        }

        if requiresSpeechRecognition {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: NotchSettings.shared.speechLocale))
            guard let speechRecognizer else {
                // nil means the locale isn't supported for speech recognition —
                // that's permanent, so fail immediately instead of retrying.
                failListening("Speech recognition isn't supported for the selected language.")
                return
            }
            guard speechRecognizer.isAvailable else {
                // Unavailability is often transient (the recognition service
                // churns briefly after a task cancellation or device change).
                // Giving up here leaves the engine stopped and the app deaf —
                // retry like the invalid-format guard below does.
                if retryCount < maxRetries {
                    retryCount += 1
                    scheduleBeginRecognition(after: 0.5)
                } else {
                    failListening("Speech recognizer is not available.")
                }
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                failListening("Unable to create a speech recognition request.")
                return
            }
            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.taskHint = .dictation

            // Add contextual strings from the source text to improve STT accuracy
            let hints = recognitionHints()
            if !hints.isEmpty {
                recognitionRequest.contextualStrings = hints
            }

            if let debugAudio, debugAudio.mode == .fast {
                beginFastFileRecognition(debugAudio, recognizer: speechRecognizer, hints: hints)
                return
            }
        } else {
            speechRecognizer = nil
            recognitionRequest = nil
        }

        let tapNode: AVAudioNode
        let tapFormat: AVAudioFormat
        var debugPlayback: (player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer)?
        if let debugAudio, debugAudio.mode == .realtime {
            // Play the file through the engine and tap the player instead of
            // the microphone, so recognition runs at real speed through the
            // same request, restarts and matching as live speech.
            guard let buffer = Self.monoBuffer(from: debugAudio.url) else {
                failListening("Couldn't read the audio file.")
                return
            }
            let player = AVAudioPlayerNode()
            audioEngine.attach(player)
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: buffer.format)
            debugPlayer = player
            debugPlayback = (player, buffer)
            tapNode = player
            tapFormat = buffer.format
        } else {
            let inputNode = audioEngine.inputNode
            let hardwareFormat = inputNode.outputFormat(forBus: 0)

            // Guard against invalid format during device transitions (e.g. mic switch)
            guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
                // Retry after a longer delay to let the audio system settle
                if retryCount < maxRetries {
                    retryCount += 1
                    scheduleBeginRecognition(after: 0.5)
                } else {
                    failListening("Audio input is unavailable.")
                }
                return
            }

            // SFSpeechRecognizer expects mono voice audio. Downmix multi-channel
            // devices without changing the input node's hardware sample rate.
            guard let format = speechCaptureFormat(for: hardwareFormat) else {
                failListening("Audio input format is unsupported.")
                return
            }
            tapNode = inputNode
            tapFormat = format

            // Observe audio configuration changes (e.g. mic switched externally) to restart gracefully
            configurationChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: audioEngine,
                queue: .main
            ) { [weak self] _ in
                guard let self,
                      self.shouldListen,
                      !self.suppressConfigChange,
                      !self.sourceText.isEmpty else { return }
                self.restartRecognition()
            }
        }

        // Belt-and-suspenders: ensure no stale tap exists before installing
        tapNode.removeTap(onBus: 0)

        let waveformFrameInterval = AVAudioFrameCount(
            max(1, tapFormat.sampleRate / waveformUpdatesPerSecond)
        )
        var framesSinceWaveformUpdate = waveformFrameInterval

        // A player is already connected in the mono file format; a format may
        // only be given for the unconnected input node.
        tapNode.installTap(
            onBus: 0,
            bufferSize: speechCaptureBufferSize(for: tapFormat),
            format: debugPlayback == nil ? tapFormat : nil
        ) { [weak self] buffer, _ in
            self?.appendBufferToRequest(buffer)

            framesSinceWaveformUpdate &+= buffer.frameLength
            guard framesSinceWaveformUpdate >= waveformFrameInterval else { return }
            framesSinceWaveformUpdate %= waveformFrameInterval

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))

            DispatchQueue.main.async {
                guard let self,
                      self.shouldListen,
                      self.sessionGeneration == expectedSessionGeneration else { return }
                self.recordAudioLevel(level)
            }
        }

        if let speechRecognizer, let recognitionRequest {
            recognitionGeneration &+= 1
            let currentRecognitionGeneration = recognitionGeneration
            let currentGeneration = sessionGeneration
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    let isFinal = result.isFinal
                    DispatchQueue.main.async {
                        // Ignore stale results from a previous session
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        self.retryCount = 0 // Reset on success
                        self.lastSpokenText = spoken
                        self.matchCharacters(spoken: spoken, isFinal: isFinal)
                    }
                }
                if let error {
                    DispatchQueue.main.async {
                        guard self.sessionGeneration == currentGeneration,
                              self.recognitionGeneration == currentRecognitionGeneration else { return }
                        // If recognitionRequest is nil, cleanup already ran (intentional cancel) — don't retry
                        guard self.recognitionRequest != nil else { return }
                        guard self.shouldListen && !self.shouldDismiss && !self.sourceText.isEmpty else {
                            self.isListening = false
                            self.isStarting = false
                            return
                        }

                        self.matchStartOffset = self.recognizedCharCount

                        // Distinguish timeout errors (expected every ~60s) from real errors.
                        // SFSpeechRecognizer timeout is error code 1110 in kAFAssistantErrorDomain,
                        // or 216 (kAudioConverterErr_FormatNotSupported). Retry immediately for
                        // timeouts with no retry limit; use backoff for real errors.
                        let nsError = error as NSError
                        let isTimeout = nsError.code == 1110 || nsError.code == 216

                        if isTimeout {
                            // Expected timeout — restart immediately, no retry limit
                            self.retryCount = 0
                            if self.audioEngine.isRunning {
                                self.restartTask()
                            } else {
                                self.scheduleBeginRecognition(after: 0.1)
                            }
                        } else if self.retryCount < self.maxRetries {
                            self.retryCount += 1
                            let delay = min(Double(self.retryCount) * 0.5, 1.5)
                            self.scheduleBeginRecognition(after: delay)
                        } else {
                            self.failListening("Speech recognition stopped: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            guard shouldListen, sessionGeneration == expectedSessionGeneration else {
                cleanupRecognition()
                return
            }
            error = nil
            isStarting = false
            isListening = true
            if requiresSpeechRecognition {
                startPreemptiveTimer()
            }
            if let debugPlayback {
                startDebugPlayback(debugPlayback.player, buffer: debugPlayback.buffer)
            }
        } catch {
            // Transient failure after a device switch — retry with longer delay
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                failListening("Audio engine failed: \(error.localizedDescription)")
            }
        }
    }

    private func restartRecognition(resetRetryCount: Bool = true) {
        guard shouldListen, !sourceText.isEmpty else {
            isListening = false
            isStarting = false
            return
        }
        if resetRetryCount {
            retryCount = 0
        }
        isListening = false
        isStarting = true
        cleanupRecognition()
        scheduleBeginRecognition(after: 0.5)
    }

    // MARK: - Thread-safe buffer appending

    private func recordAudioLevel(_ level: CGFloat) {
        audioLevels.append(level)
        if audioLevels.count > 30 {
            audioLevels.removeFirst()
        }
        voiceActivityDetector.process(level: level, at: ProcessInfo.processInfo.systemUptime)
    }

    private func appendBufferToRequest(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        recognitionRequest?.append(buffer)
        requestLock.unlock()
    }

    // MARK: - Soft restart (task only, keeps audio engine running)

    private func restartTask() {
        guard shouldListen, isListening, audioEngine.isRunning, !sourceText.isEmpty else {
            isListening = false
            if shouldListen, !sourceText.isEmpty {
                cleanupRecognition()
                scheduleBeginRecognition(after: 0.5)
            }
            return
        }
        recognitionGeneration &+= 1
        let currentRecognitionGeneration = recognitionGeneration
        // Update match offset before restarting
        matchStartOffset = recognizedCharCount
        resetMatchConfirmation()
        // New task = fresh transcript. lastSpokenText must be cleared too:
        // a jump taken before the first new result would otherwise anchor on
        // the old task's transcript and trim away everything the new task
        // ever produces.
        spokenAnchorPrefix = ""
        lastSpokenText = ""

        // Cancel any pending restart to avoid stale beginRecognition clobbering this session
        pendingRestart?.cancel()
        pendingRestart = nil

        // Cancel the old task and atomically swap to a new request under lock.
        // The lock prevents the audio tap from appending to the old request
        // between endAudio() and the new assignment.
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation

        // Add contextual strings for the remaining text
        let hints = recognitionHints()
        if !hints.isEmpty {
            newRequest.contextualStrings = hints
        }

        // Nil out recognitionRequest before cancelling the old task so the
        // old task's error callback sees nil and skips retry logic. Then set
        // the new request after cancellation.
        requestLock.lock()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil

        requestLock.lock()
        recognitionRequest = newRequest
        requestLock.unlock()

        // Start new recognition task
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            // Transient unavailability — fall back to a full session restart
            // with retries rather than going permanently deaf.
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                // Don't leave the mic hot with no session consuming it
                failListening("Speech recognizer is not available.")
            }
            return
        }

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration,
                          self.recognitionGeneration == currentRecognitionGeneration else { return }
                    self.retryCount = 0
                    self.lastSpokenText = spoken
                    self.matchCharacters(spoken: spoken, isFinal: isFinal)
                }
            }
            if let error {
                DispatchQueue.main.async {
                    guard self.sessionGeneration == currentGeneration,
                          self.recognitionGeneration == currentRecognitionGeneration else { return }
                    guard self.recognitionRequest != nil else { return }
                    guard self.shouldListen && !self.shouldDismiss && !self.sourceText.isEmpty else {
                        self.isListening = false
                        self.isStarting = false
                        return
                    }

                    self.matchStartOffset = self.recognizedCharCount

                    let nsError = error as NSError
                    let isTimeout = nsError.code == 1110 || nsError.code == 216

                    if isTimeout {
                        self.retryCount = 0
                        if self.audioEngine.isRunning {
                            self.restartTask()
                        } else {
                            self.scheduleBeginRecognition(after: 0.1)
                        }
                    } else if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        let delay = min(Double(self.retryCount) * 0.5, 1.5)
                        self.scheduleBeginRecognition(after: delay)
                    } else {
                        self.failListening("Speech recognition stopped: \(error.localizedDescription)")
                    }
                }
            }
        }

        startPreemptiveTimer()
    }

    // MARK: - Pre-emptive restart timer

    private func startPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = Timer.scheduledTimer(withTimeInterval: 55.0, repeats: true) { [weak self] _ in
            guard let self, self.isListening, !self.sourceText.isEmpty else { return }
            self.restartTask()
        }
    }

    private func stopPreemptiveTimer() {
        preemptiveRestartTimer?.invalidate()
        preemptiveRestartTimer = nil
    }

    // MARK: - Following the script

    /// Loads a script for matching. Chinese speech locales get the Chinese
    /// aligner; every other locale keeps the original follower.
    private func loadScript(_ text: String) {
        scriptText = text
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        annotationRanges = SpeechTextAlignment.annotationRanges(in: collapsed)
        let settings = NotchSettings.shared
        if let config = ChineseAlignerConfig.forSpeechLocale(settings.speechLocale, fuzzyPinyin: settings.fuzzyPinyin) {
            let script = TokenizedScript(
                words: words,
                paragraphBreakBeforeWordIndices: paragraphBreakWordIndices(in: text)
            )
            chineseAligner = ChineseAligner(script: script, config: config)
        } else {
            chineseAligner = nil
        }
    }

    /// Where the highlight rests for a requested offset: past any annotation
    /// (original follower) or at the start of the next unread token (Chinese
    /// aligner, whose cursor is moved there too).
    private func settledCursor(at offset: Int) -> Int {
        guard var aligner = chineseAligner else {
            return advancePastAnnotations(from: offset)
        }
        aligner.setCursor(aligner.script.tokenIndex(forOffset: offset))
        chineseAligner = aligner
        return aligner.cursorOffset
    }

    /// Forget recent match candidates (the 2-of-3 confirmation window).
    private func resetMatchConfirmation() {
        recentMatchPositions = []
        chineseAligner?.resetConfirmation()
    }

    /// contextualStrings for the next recognition request.
    private func recognitionHints() -> [String] {
        if let aligner = chineseAligner {
            let script = aligner.script
            let startWord = aligner.cursor < script.tokens.count
                ? script.tokens[aligner.cursor].wordIndex
                : script.words.count
            return ContextualPhrases.chinese(words: script.words, fromWord: startWord)
        }
        return ContextualPhrases.legacy(sourceText: sourceText, matchStartOffset: matchStartOffset)
    }

    private func matchCharacters(spoken fullSpoken: String, isFinal: Bool = false) {
        // Results computed before a jump can be delivered just after it —
        // don't match pre-jump speech against the text at the new offset.
        guard Date().timeIntervalSince(lastJumpAt) > 0.3 else { return }

        // Ignore transcript from before the most recent jump. Trim by the
        // common prefix that survived the recognizer's revisions, but never
        // less than the anchor length minus a small slack — a revision very
        // early in the transcript would otherwise leak the whole pre-jump
        // transcript back into matching.
        var spoken = fullSpoken
        if !spokenAnchorPrefix.isEmpty {
            let common = zip(spokenAnchorPrefix, fullSpoken).prefix(while: { $0 == $1 }).count
            let trimLen = min(fullSpoken.count, max(common, spokenAnchorPrefix.count - 24))
            spoken = String(fullSpoken.dropFirst(trimLen))
        }
        defer { recordRunEntry(transcript: fullSpoken, matchedText: spoken, isFinal: isFinal) }
        guard !spoken.isEmpty else { return }

        if var aligner = chineseAligner {
            // recognizedCharCount is also written from outside (page changes,
            // the overlay); it is the position of record.
            if aligner.cursorOffset != recognizedCharCount {
                aligner.setCursor(aligner.script.tokenIndex(forOffset: recognizedCharCount))
            }
            if aligner.feed(spoken) {
                recognizedCharCount = aligner.cursorOffset
            }
            chineseAligner = aligner
            return
        }

        var legacy = LegacyAligner()
        legacy.sourceText = sourceText
        legacy.annotationRanges = annotationRanges
        legacy.matchStartOffset = matchStartOffset
        legacy.recognizedCharCount = recognizedCharCount
        legacy.recentMatchPositions = recentMatchPositions
        legacy.match(spoken: spoken)
        recentMatchPositions = legacy.recentMatchPositions
        if legacy.recognizedCharCount != recognizedCharCount {
            recognizedCharCount = legacy.recognizedCharCount
        }
    }

    private func advancePastAnnotations(from offset: Int) -> Int {
        SpeechTextAlignment.advancePastAnnotations(
            in: sourceText,
            ranges: annotationRanges,
            from: offset
        )
    }

    // MARK: - Audio-file debug runs

    private func beginRunLog(for run: DebugAudioRun) {
        let settings = NotchSettings.shared
        runLog = RecognitionRunLog(
            script: scriptText,
            locale: settings.speechLocale,
            fuzzyPinyin: settings.fuzzyPinyin,
            mode: run.mode.rawValue,
            audioFile: run.url.lastPathComponent,
            onDevice: false
        )
        runStartedAt = Date()
        debugPlaybackDone = false
    }

    private func recordRunEntry(transcript: String, matchedText: String, isFinal: Bool) {
        guard runLog != nil else { return }
        runLog?.entries.append(RecognitionRunLog.Entry(
            time: Date().timeIntervalSince(runStartedAt),
            transcript: transcript,
            matchedText: matchedText,
            isFinal: isFinal,
            charCount: recognizedCharCount
        ))
        // The file is fully recognized: stop, which saves the log. Async so
        // the result callback finishes first.
        if isFinal && (debugAudio?.mode == .fast || debugPlaybackDone) {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
            }
        }
    }

    /// Ends an audio-file run, if one is active, and saves its log.
    private func endDebugRun() {
        debugRunFinishWork?.cancel()
        debugRunFinishWork = nil
        debugPlaybackDone = false
        let log = runLog
        let run = debugAudio
        runLog = nil
        debugAudio = nil
        if let log, let run {
            saveRunLog(log, audioURL: run.url)
        }
    }

    private func saveRunLog(_ log: RecognitionRunLog, audioURL: URL) {
        do {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("DebugRuns", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "\(audioURL.deletingPathExtension().lastPathComponent)-\(log.mode)-\(formatter.string(from: Date())).json"
            let url = directory.appendingPathComponent(name)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(log).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            self.error = "Couldn't save the debug log: \(error.localizedDescription)"
        }
    }

    private func beginFastFileRecognition(_ run: DebugAudioRun, recognizer: SFSpeechRecognizer, hints: [String]) {
        // The buffer request built for the microphone is not used.
        recognitionRequest = nil
        let request = SFSpeechURLRecognitionRequest(url: run.url)
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if !hints.isEmpty {
            request.contextualStrings = hints
        }
        // Server recognition stops after about a minute of audio; on-device
        // recognition has no such limit.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        runLog?.onDevice = request.requiresOnDeviceRecognition

        recognitionGeneration &+= 1
        let currentRecognitionGeneration = recognitionGeneration
        let currentGeneration = sessionGeneration
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let spoken = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                guard let self,
                      self.sessionGeneration == currentGeneration,
                      self.recognitionGeneration == currentRecognitionGeneration else { return }
                if let spoken {
                    self.lastSpokenText = spoken
                    self.matchCharacters(spoken: spoken, isFinal: isFinal)
                }
                if let message, !isFinal {
                    self.stop()
                    self.error = "Audio-file recognition stopped: \(message)"
                }
            }
        }
        isStarting = false
        isListening = true
    }

    private func startDebugPlayback(_ player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer) {
        let generation = sessionGeneration
        debugPlaybackDone = false
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == generation, self.debugAudio != nil else { return }
                self.debugPlaybackDone = true
                // End the request so the recognizer delivers its final
                // result; stop anyway if none arrives.
                self.requestLock.lock()
                self.recognitionRequest?.endAudio()
                self.requestLock.unlock()
                let work = DispatchWorkItem { [weak self] in
                    self?.stop()
                }
                self.debugRunFinishWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            }
        }
        player.play()
    }

    /// The whole file as one mono float buffer at the file's sample rate.
    private static func monoBuffer(from url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil,
              let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: file.processingFormat.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: source.frameLength),
              let input = source.floatChannelData,
              let output = mono.floatChannelData else { return nil }
        let channels = Int(source.format.channelCount)
        for frame in 0..<Int(source.frameLength) {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += input[channel][frame]
            }
            output[0][frame] = sum / Float(channels)
        }
        mono.frameLength = source.frameLength
        return mono
    }
}
