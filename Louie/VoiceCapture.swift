//
//  VoiceCapture.swift
//  Louie
//
//  Push-to-talk capture surface: requests permissions, streams mic audio
//  into the on-device `SFSpeechRecognizer`, and plays text back via
//  `AVSpeechSynthesizer`. Lives behind a protocol so previews can swap in a
//  fake that returns a canned transcript without touching the audio stack
//  (the real permission prompt can't be resolved in Xcode's preview sandbox
//  and would hang).
//

import AVFoundation
import Foundation
import Speech

enum VoiceCaptureError: LocalizedError {
    case microphoneDenied
    case speechRecognitionDenied
    case recognizerUnavailable
    case noSpeechDetected
    case audioEngine(String)
    case recognition(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access was denied. Enable it in Settings to use voice."
        case .speechRecognitionDenied:
            "Speech recognition access was denied. Enable it in Settings."
        case .recognizerUnavailable:
            "Speech recognition is unavailable on this device or locale."
        case .noSpeechDetected:
            "I didn't catch that — no speech detected."
        case let .audioEngine(detail):
            "Couldn't start audio capture: \(detail)"
        case let .recognition(detail):
            "Recognition failed: \(detail)"
        }
    }
}

/// Audio capture + TTS surface used by `VoiceAgentController`.
@MainActor
protocol VoiceCapture: AnyObject {
    /// Begin capturing mic audio. Must be paired with a `stopRecording` or
    /// `cancel` call.
    func startRecording() async throws
    /// Stop capture and return the final transcript.
    func stopRecording() async throws -> String
    /// Speak `text` through the device speaker. Returns when synthesis
    /// finishes naturally or is cancelled via `cancel()`. Awaitable so the
    /// per-turn Sentry transaction can include TTS latency.
    func speak(_ text: String) async
    /// Abort any in-flight recording or playback. Idempotent.
    func cancel()
}

// MARK: - Live implementation

@MainActor
final class LiveVoiceCapture: NSObject, VoiceCapture, AVSpeechSynthesizerDelegate {
    private let recognizer: SFSpeechRecognizer?
    private let synthesizer = AVSpeechSynthesizer()

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var currentTranscript: String = ""
    private var finishContinuation: CheckedContinuation<String, Error>?
    /// Resumed when AVSpeechSynthesizer fires didFinish or didCancel — both
    /// terminal for our purposes. Speech is non-throwing so we don't need to
    /// distinguish here; the controller checks `Task.isCancelled` after the
    /// await to decide on the transaction status.
    private var speechContinuation: CheckedContinuation<Void, Never>?

    override init() {
        recognizer = SFSpeechRecognizer()
        super.init()
        synthesizer.delegate = self
    }

    // MARK: Permissions

    func requestAuthorization() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .denied:
            throw VoiceCaptureError.microphoneDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw VoiceCaptureError.microphoneDenied }
        @unknown default:
            throw VoiceCaptureError.microphoneDenied
        }

        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw VoiceCaptureError.speechRecognitionDenied
        }
    }

    // MARK: Recording

    func startRecording() async throws {
        try await requestAuthorization()

        guard let recognizer, recognizer.isAvailable else {
            throw VoiceCaptureError.recognizerUnavailable
        }

        // Tear down any prior session before starting a new one.
        teardownEngine()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker],
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw VoiceCaptureError.audioEngine(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = Self.contextualVocabulary
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // The tap callback runs on an audio thread. `SFSpeechAudioBufferRecognitionRequest.append`
        // is documented as thread-safe, so we capture `request` for the buffer pump.
        nonisolated(unsafe) let pumpRequest = request
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            pumpRequest.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw VoiceCaptureError.audioEngine(error.localizedDescription)
        }

        currentTranscript = ""

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // The callback fires on a private Speech queue. Marshal Sendable
            // snapshots back to the main actor and let the class state machine
            // own the recognition lifecycle.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = (error as NSError?)?.localizedDescription

            Task { @MainActor [weak self] in
                self?.handleRecognition(
                    transcript: transcript,
                    isFinal: isFinal,
                    errorMessage: errorMessage,
                )
            }
        }

        audioEngine = engine
        self.request = request
    }

    func stopRecording() async throws -> String {
        guard request != nil else {
            throw VoiceCaptureError.recognition("No active recording")
        }

        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            request?.endAudio()
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            // Wait for the recognizer to deliver its final result via the task
            // callback; the continuation is resumed in `handleRecognition`.
        }
    }

    func cancel() {
        if let continuation = finishContinuation {
            finishContinuation = nil
            continuation.resume(throwing: VoiceCaptureError.noSpeechDetected)
        }
        synthesizer.stopSpeaking(at: .immediate)
        // didCancel normally resumes the speech continuation, but if nothing
        // is currently speaking (or queued), it won't fire. Resume directly
        // to avoid leaking a pending `await speak`.
        resumeSpeechContinuation()
        teardownEngine()
    }

    // MARK: TTS

    // Domain words/phrases the recognizer should bias toward when it would
    // otherwise produce a more common homophone (e.g. "Louie" vs "Louis").
    private static let contextualVocabulary: [String] = [
        "Louie",
    ]

    func speak(_ text: String) async {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(forBaseLanguage: "en")

        // If a prior speech is somehow still pending its continuation, resume
        // it before starting the new one — guards against state corruption
        // if speak is called twice without an intervening cancel.
        resumeSpeechContinuation()

        await withCheckedContinuation { continuation in
            speechContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    private func resumeSpeechContinuation() {
        guard let continuation = speechContinuation else { return }
        speechContinuation = nil
        continuation.resume()
    }

    // MARK: AVSpeechSynthesizerDelegate

    // The delegate fires on the main thread by default, but with strict
    // concurrency we declare these nonisolated and hop explicitly.
    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.resumeSpeechContinuation()
        }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.resumeSpeechContinuation()
        }
    }

    // Picks the highest-quality installed voice for the locale. Premium and
    // enhanced variants only show up here once the user has downloaded them
    // under Settings → Accessibility → Spoken Content (or via Siri Voice),
    // so on a fresh device this falls back to the compact default.
    private static func bestVoice(forBaseLanguage languageCode: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == languageCode || $0.language.hasPrefix("\(languageCode)-") }
        return candidates.first(where: { $0.quality == .premium })
            ?? candidates.first(where: { $0.quality == .enhanced })
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: Internals

    private func handleRecognition(
        transcript: String?,
        isFinal: Bool,
        errorMessage: String?,
    ) {
        if let transcript {
            currentTranscript = transcript
        }

        guard isFinal || errorMessage != nil else {
            return
        }

        teardownEngine()

        guard let continuation = finishContinuation else {
            return
        }
        finishContinuation = nil

        if let errorMessage, currentTranscript.isEmpty {
            continuation.resume(throwing: VoiceCaptureError.recognition(errorMessage))
        } else if currentTranscript.isEmpty {
            continuation.resume(throwing: VoiceCaptureError.noSpeechDetected)
        } else {
            continuation.resume(returning: currentTranscript)
        }
    }

    private func teardownEngine() {
        task?.cancel()
        task = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation,
        )
    }
}

// MARK: - Preview implementation

#if DEBUG
    /// Fake capture for SwiftUI previews: returns a canned transcript after a
    /// short delay so the scripted agent flow can be exercised without
    /// touching `SFSpeechRecognizer` (which hangs on permission in previews).
    @MainActor
    final class PreviewVoiceCapture: VoiceCapture {
        var transcript: String

        init(transcript: String = "play chainsmoking") {
            self.transcript = transcript
        }

        func startRecording() async throws {
            // No-op; pretend mic is hot.
        }

        func stopRecording() async throws -> String {
            try? await Task.sleep(for: .milliseconds(300))
            return transcript
        }

        func speak(_: String) async {
            // No-op in previews.
        }

        func cancel() {
            // No-op in previews.
        }
    }
#endif
