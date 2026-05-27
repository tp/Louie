//
//  VoiceCapture.swift
//  Louie
//
//  Tap-to-talk voice surface backed by iOS 26's SpeechAnalyzer +
//  SpeechTranscriber. End-of-utterance is detected by computing RMS
//  on every input buffer — `silenceTimeout` of buffers below
//  `audibleThreshold` means the user has stopped. (Earlier versions
//  debounced the transcriber's result stream; the progressive
//  transcriber emits results too sparsely for that — a single early
//  partial would trip the silence timer mid-utterance. Apple's
//  `SpeechDetector` also tried; its `results` stream stays empty in
//  this build even with `reportResults: true`.) STT and TTS live behind
//  separate protocols (`VoiceCapture`, `VoiceSynthesizer`) but share one
//  concrete `LiveVoice` so the AVAudioSession transitions between record
//  and playback stay in one place.
//
//  Flow per tap (see VoiceAgentController for the calling side):
//    tap → startRecording(onEvent:) returns the final transcript when the
//    silence timer fires, the user taps to stop early, the 15s safety
//    timeout fires, or cancel() is called (which throws). Pre-warming
//    (built once via `prewarm()`) takes the SpeechAnalyzer cold-start cost
//    off the critical PTT path entirely.
//

@preconcurrency import AVFoundation
import Foundation
import OSLog
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

/// State hints delivered to the caller during a live recording so the UI
/// can reflect what the audio layer is doing.
enum VoiceCaptureEvent: Sendable {
    case micHot // first audio buffer accepted by the engine
    case speechStarted // first audio buffer above audibleThreshold (or first transcriber result, if quieter)
    case speechEnded // silence timer fired (or manual stopRecording)
}

/// Audio capture / STT surface. Owned by `VoiceAgentController`.
@MainActor
protocol VoiceCapture: AnyObject {
    /// Pre-build transcriber + analyzer + cache audio format using only
    /// read-only checks. Never prompts, never downloads, never touches the
    /// audio session. No-op if model or permissions aren't already in place.
    func prewarm() async

    /// Begin listening. Async-returns the final transcript once recording
    /// ends — either via the silence timer firing, an explicit
    /// `stopRecording()` call, the safety timeout, or `cancel()` (which
    /// throws `CancellationError`). UI state hints are delivered via
    /// `onEvent`.
    func startRecording(onEvent: @escaping @MainActor (VoiceCaptureEvent) -> Void) async throws
        -> String

    /// Force end-of-speech early. The in-flight `startRecording` returns
    /// shortly with the accumulated transcript. No-op if not recording.
    func stopRecording()

    /// Abort the in-flight recording. `startRecording` throws
    /// `CancellationError`. Does not affect TTS. Idempotent.
    func cancel()
}

/// TTS surface. Split out from `VoiceCapture` so the controller's STT and
/// playback dependencies are explicit.
@MainActor
protocol VoiceSynthesizer: AnyObject {
    /// Speak `text`. Returns when synthesis finishes naturally or is
    /// cancelled. Awaitable so per-turn telemetry can include TTS latency.
    func speak(_ text: String) async

    /// Stop any in-flight speech. Resumes a pending `speak`. Does not
    /// affect recording. Idempotent.
    func cancel()
}

// MARK: - Live implementation

@MainActor
final class LiveVoice: NSObject, VoiceCapture, VoiceSynthesizer, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let log = TimedLogger(label: "STT", category: "LiveVoice")
    private let sttLogger = Logger(subsystem: "Louie", category: "LiveVoice")

    // Reusable preparation state cached across turns. Not part of the
    // pipeline itself — these are inputs to building one. The model stays
    // in process memory via `Options.modelRetention = .processLifetime`,
    // so subsequent analyzers skip the cold load.
    private var cachedFormat: AVAudioFormat?
    private var analysisContext: AnalysisContext?
    private var pipelineLocale: Locale?

    /// The active recognition session, if any. `SpeechAnalyzer` instances
    /// can't be resumed after `finalize*` / `cancelAndFinishNow`, so the
    /// pipeline is built fresh per turn and dropped on completion.
    private var activePipeline: RecognitionPipeline?

    // Per-turn state.
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var transcriberTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Error>?
    private var maxDurationTask: Task<Void, Never>?

    /// Single-shot debounce: rescheduled on every transcriber result;
    /// fires `speechEnded` + `signalEnd(.silence)` if it ever reaches the
    /// timeout without being rescheduled.
    private var silenceTask: Task<Void, Never>?

    /// Periodic logger that emits the max RMS observed in each
    /// `audioWindowPeriod` window. Pure diagnostic — drives no logic.
    private var audioWindowLogTask: Task<Void, Never>?
    /// Updated from the audio tap on every buffer; consumed and reset
    /// by `audioWindowLogTask`. Main-actor isolated so we don't need a
    /// lock; the tap hops through `Task { @MainActor in ... }`.
    private var audioWindowMaxRMS: Float = 0

    /// Accumulated final-result text for the current turn. Updated as the
    /// transcriber yields isFinal results.
    private var currentTranscript = ""

    /// Resolves the awaiting `startRecording` continuation. Replaced
    /// per-turn; any of {silence, manual stop, timeout, cancel} can fire it.
    private enum EndReason { case silence, manual, timeout }
    private var endContinuation: CheckedContinuation<EndReason, Error>?
    private var hasFiredMicHot = false
    private var hasFiredSpeechStarted = false
    private var hasFiredSpeechEnded = false
    /// Gate for the transcriber backstop in `markAudible`. True once
    /// any audio-tap buffer crossed `audibleThreshold` for this turn.
    /// See `markAudible` for the full rationale.
    private var hasAudibleAudioFired = false

    /// AVSpeechSynthesizer's `didFinish`/`didCancel` delegate resumes this.
    private var speechContinuation: CheckedContinuation<Void, Never>?

    // Domain words/phrases to bias toward when the model would otherwise
    // produce a more common homophone (e.g. "Louie" vs "Louis").
    private static let contextualVocabulary: [String] = ["Louie"]

    /// Trailing silence (audio RMS below `audibleThreshold`) before we
    /// declare the user is done. Long enough to ride out think-pauses
    /// ("play, uh, Thriller"), short enough to feel snappy. Endpointing
    /// draws on every audio buffer, so the wall-clock end-to-end
    /// latency is roughly this plus the analyzer's final drain
    /// (typically a few hundred ms).
    private static let silenceTimeout: Duration = .milliseconds(1000)

    /// Period of the `audio_window` diagnostic log line. Every window,
    /// the max observed RMS is logged and then reset, so the recording
    /// produces a coarse audio-level trace useful for tuning
    /// `audibleThreshold`.
    private static let audioWindowPeriod: Duration = .milliseconds(250)

    /// RMS threshold above which an input buffer counts as voice rather
    /// than room noise / silence. Float32 input; 0.0015 ≈ −56 dBFS.
    /// `.measurement` mode (no AGC, no noise suppression) gives quite
    /// low headroom — observed speech at iPad arm's-length peaks around
    /// 0.005 but most syllables sit at 0.002–0.003, while ambient sits
    /// at 0.0003–0.0006. 0.0015 catches the bulk of speech buffers
    /// without tripping on room noise. Tune via the periodic
    /// `audio_window` log line (max RMS per 250 ms) and the
    /// `speech_started` line (RMS that triggered the first fire).
    private static let audibleThreshold: Float = 0.0015

    /// Hard cap on a single recording, in case the silence timer never
    /// fires (e.g., transcriber stuck or no speech at all).
    private static let maxRecordingDuration: Duration = .seconds(15)

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: VoiceCapture

    func prewarm() async {
        log.reset()
        log.event("prewarm_start")

        // Only act if both prerequisites are already in place: Speech
        // permission previously authorized AND the locale's model
        // installed. Either missing → defer to first tap.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            log.event("prewarm_skipped", detail: "speech auth not granted")
            return
        }

        let locale = await preferredLocale()
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
        else {
            log.event("model_missing", detail: locale.identifier)
            return
        }
        log.event("model_present", detail: locale.identifier)

        // Build a throwaway analyzer just to call `prepareToAnalyze`,
        // which loads the model. `modelRetention: .processLifetime` on
        // the Options keeps the model in process memory after this
        // analyzer is dropped, so the first real turn skips the load.
        // Also caches the audio format + analysis context for reuse.
        do {
            let pipeline = try await buildPipeline(locale: locale)
            try await pipeline.analyzer.prepareToAnalyze(in: pipeline.format)
            cachedFormat = pipeline.format
            pipelineLocale = locale
            log.event("analyzer_ready")
        } catch {
            sttLogger.warning(
                "prewarm pipeline build failed: \(error.localizedDescription, privacy: .public)")
            log.event("prewarm_failed", detail: error.localizedDescription)
        }
    }

    func startRecording(onEvent: @escaping @MainActor (VoiceCaptureEvent) -> Void) async throws
        -> String
    {
        log.reset()
        log.event("start_called")

        try await requestAuthorization()
        log.event("auth_ready")

        // Always build fresh — `SpeechAnalyzer` can't be resumed after
        // `finalize*` / `cancelAndFinishNow`. Cheap on subsequent turns
        // because the model stays loaded (modelRetention: .processLifetime).
        let locale = await preferredLocale()
        try await ensureModelInstalled(for: locale)
        let pipeline = try await buildPipeline(locale: locale)
        activePipeline = pipeline
        cachedFormat = pipeline.format
        pipelineLocale = locale
        log.event("pipeline_ready")

        // Local aliases keep the rest of this function readable; we still
        // own the lifetime via `activePipeline`.
        let analyzer = pipeline.analyzer
        let transcriber = pipeline.transcriber
        let analyzerFormat = pipeline.format

        // Reset per-turn state.
        currentTranscript = ""
        hasFiredMicHot = false
        hasFiredSpeechStarted = false
        hasFiredSpeechEnded = false
        hasAudibleAudioFired = false
        teardownEngine()

        // Activate audio session.
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
        log.event("session_active")

        // Wire the input stream into the analyzer.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        // Subscribe to transcriber results before the analyzer starts
        // producing them, so we don't lose the first events. This loop
        // accumulates final text into `currentTranscript`; endpointing
        // is driven by the audio tap, with this loop as a backstop —
        // see `markAudible`.
        let weakSelf = self
        transcriberTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    // Endpointing backstop — only matters if the audio
                    // tap never crosses `audibleThreshold` (quiet
                    // speaker / far mic). `markAudible` ignores us
                    // once the audio path has fired at least once.
                    weakSelf.markAudible(rms: nil, onEvent: onEvent)

                    // result.text is AttributedString; flatten to plain.
                    let plain = String(result.text.characters)
                    if result.isFinal {
                        if weakSelf.currentTranscript.isEmpty {
                            weakSelf.currentTranscript = plain
                        } else {
                            weakSelf.currentTranscript += " \(plain)"
                        }
                    }
                    // Apple's terms: a `volatile` result is a tentative
                    // hypothesis that may change; an `isFinal` result is
                    // a committed segment that joins the solid transcript.
                    weakSelf.log.event(
                        result.isFinal ? "result_final" : "result_volatile",
                        detail: "solid=\(weakSelf.currentTranscript.debugDescription) "
                            + "this=\(plain.debugDescription)",
                    )
                }
            } catch is CancellationError {
                // Expected on cancel.
            } catch {
                weakSelf.sttLogger.warning(
                    "transcriber stream error: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Start the analyzer (consumes the input stream until it finishes).
        analyzerTask = Task {
            try await analyzer.start(inputSequence: stream)
        }

        // Start engine + install tap.
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let converter =
            nativeFormat == analyzerFormat
                ? nil
                : AVAudioConverter(from: nativeFormat, to: analyzerFormat)

        let pumpContinuation = continuation
        let target = analyzerFormat
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { buffer, _ in
            if let converter {
                if let converted = Self.convert(buffer, with: converter, to: target) {
                    pumpContinuation.yield(AnalyzerInput(buffer: converted))
                }
            } else {
                pumpContinuation.yield(AnalyzerInput(buffer: buffer))
            }
            // Fire mic_hot on first buffer (back on main actor).
            Task { @MainActor [weak self] in
                guard let self, !self.hasFiredMicHot else { return }
                hasFiredMicHot = true
                log.event("first_buffer")
                onEvent(.micHot)
            }
            // RMS-based VAD: every audible buffer drives `speechStarted`
            // + (re)arms the silence timer. Independent of how sparsely
            // the transcriber emits results, so the timer only fires
            // after true trailing silence.
            let rms = Self.computeRMS(buffer)
            let isAudible = rms > Self.audibleThreshold
            Task { @MainActor [weak self] in
                guard let self else { return }
                if rms > audioWindowMaxRMS { audioWindowMaxRMS = rms }
                if isAudible {
                    markAudible(rms: rms, onEvent: onEvent)
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            teardownEngine()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw VoiceCaptureError.audioEngine(error.localizedDescription)
        }
        audioEngine = engine
        log.event("engine_started")

        // Safety timeout — covers the case where the silence timer
        // never gets armed (no speech) or never gets to fire (transcriber
        // stuck emitting forever). `try await` (not `try?`) so a cancel
        // propagates out cleanly instead of falsely logging a timeout.
        maxDurationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.maxRecordingDuration) } catch { return }
            guard let self else { return }
            log.event("max_duration_reached")
            signalEnd(.timeout)
        }

        // Diagnostic: log the max RMS observed per `audioWindowPeriod`.
        // Lets us correlate "cut off mid-sentence" reports against the
        // actual audio level relative to `audibleThreshold`.
        audioWindowMaxRMS = 0
        audioWindowLogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.audioWindowPeriod) } catch { return }
                guard let self else { return }
                let maxRMS = audioWindowMaxRMS
                audioWindowMaxRMS = 0
                log.event(
                    "audio_window",
                    detail: "max_rms=\(String(format: "%.4f", maxRMS))",
                )
            }
        }

        // Await any termination signal.
        let reason: EndReason
        do {
            reason = try await withCheckedThrowingContinuation { continuation in
                self.endContinuation = continuation
            }
        } catch {
            // Cancel path — clean up and rethrow.
            teardownEngine()
            activePipeline = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        log.event("end_signal", detail: "\(reason)")

        // Cancel safety/auxiliary tasks and stop the engine immediately.
        maxDurationTask?.cancel()
        maxDurationTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        audioWindowLogTask?.cancel()
        audioWindowLogTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        // Finish the input stream and drain the analyzer.
        inputContinuation?.finish()
        inputContinuation = nil
        log.event("finalize_requested")
        do {
            try await pipeline.finalize()
        } catch {
            sttLogger.warning("finalize failed: \(error.localizedDescription, privacy: .public)")
        }

        // The transcriber task ends when the analyzer ends; await it so
        // currentTranscript reflects all isFinal results.
        await transcriberTask?.value
        analyzerTask?.cancel()

        // Fire speechEnded once if we never did (e.g., manual stop or
        // timeout before any transcriber result arrived).
        if !hasFiredSpeechEnded {
            hasFiredSpeechEnded = true
            onEvent(.speechEnded)
        }

        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        audioEngine = nil
        // The analyzer is dead after finalize; ensure the next turn rebuilds.
        activePipeline = nil
        log.event("final_result", detail: currentTranscript)

        if currentTranscript.isEmpty {
            throw VoiceCaptureError.noSpeechDetected
        }
        return currentTranscript
    }

    func stopRecording() {
        log.event("manual_stop")
        signalEnd(.manual)
    }

    /// The single concrete `cancel()` satisfies both `VoiceCapture.cancel`
    /// and `VoiceSynthesizer.cancel` — Swift can't dispatch two same-name
    /// protocol methods to different impls on one class. We tear down both
    /// sides: idempotent, and matches how `VoiceAgentController` actually
    /// uses cancel (always called for the whole turn).
    func cancel() {
        // STT side.
        if let continuation = endContinuation {
            endContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        maxDurationTask?.cancel()
        maxDurationTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        audioWindowLogTask?.cancel()
        audioWindowLogTask = nil
        transcriberTask?.cancel()
        analyzerTask?.cancel()
        if let pipeline = activePipeline {
            Task { await pipeline.cancel() }
        }
        // Drop the dead instance so the next turn builds fresh.
        activePipeline = nil
        teardownEngine()

        // TTS side.
        synthesizer.stopSpeaking(at: .immediate)
        // didCancel normally resumes the speech continuation, but if
        // nothing is currently speaking it won't fire. Resume directly so
        // a pending `await speak` doesn't leak.
        resumeSpeechContinuation()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: VoiceSynthesizer

    func speak(_ text: String) async {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(forBaseLanguage: "en")

        resumeSpeechContinuation()
        await withCheckedContinuation { continuation in
            speechContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    // VoiceSynthesizer.cancel — distinct from VoiceCapture.cancel above.
    // Both protocols declare `func cancel()`; the single concrete class
    // satisfies both with one implementation that the controller calls
    // through the appropriate protocol reference.
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

    // MARK: Internals

    private func signalEnd(_ reason: EndReason) {
        guard let continuation = endContinuation else { return }
        endContinuation = nil
        continuation.resume(returning: reason)
    }

    /// Note an audible moment. Fires `speechStarted` the first time
    /// and (re)arms the trailing-silence timer.
    ///
    /// Two callers:
    /// - **Audio tap (`rms` non-nil)** — primary. Fires for every
    ///   buffer with RMS above `audibleThreshold`. This is what
    ///   drives endpointing in the normal case.
    /// - **Transcriber loop (`rms` nil)** — backstop. Only does any
    ///   work if `audibleThreshold` was set too high for this
    ///   speaker / mic distance, so the audio path is silent even
    ///   though the user is talking. In that case, transcriber
    ///   emissions are the only signal we have that speech is
    ///   happening, and without them the turn would only end via
    ///   the 15 s max-duration safety timeout.
    ///
    /// Once the audio path has fired at least once for this turn
    /// (`hasAudibleAudioFired = true`), the transcriber backstop is
    /// disabled. Reason: the analyzer keeps emitting volatile
    /// results for ~1 s after the user actually stops talking (its
    /// internal drain). Without this gate, those drain events would
    /// keep rearming the silence timer and push end-of-utterance
    /// detection well past the real end.
    private func markAudible(rms: Float?, onEvent: @escaping @MainActor (VoiceCaptureEvent) -> Void) {
        if rms != nil {
            hasAudibleAudioFired = true
        } else if hasAudibleAudioFired {
            return
        }
        if !hasFiredSpeechStarted {
            hasFiredSpeechStarted = true
            let detail = rms.map { "rms=\(String(format: "%.4f", $0))" } ?? "transcriber"
            log.event("speech_started", detail: detail)
            onEvent(.speechStarted)
        }
        armSilenceTimer(onEvent: onEvent)
    }

    /// (Re)arm the trailing-silence timer. Called from `markAudible`
    /// on every audible buffer — each call cancels the previous task,
    /// so the timer only fires when no audible buffer has arrived for
    /// `silenceTimeout`. Also fires `speechEnded` so the UI can flip
    /// to "thinking" while the analyzer's final drain completes.
    ///
    /// No-op once we've already signalled end: `pipeline.finalize()`
    /// can flush one last final result through the transcriber loop,
    /// which would otherwise re-arm the timer and leak a stray fire
    /// after the turn is done.
    private func armSilenceTimer(onEvent: @escaping @MainActor (VoiceCaptureEvent) -> Void) {
        guard endContinuation != nil else { return }
        silenceTask?.cancel()
        silenceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.silenceTimeout) } catch { return }
            guard let self else { return }
            log.event("silence_timeout")
            if !hasFiredSpeechEnded {
                hasFiredSpeechEnded = true
                onEvent(.speechEnded)
            }
            signalEnd(.silence)
        }
    }

    private func teardownEngine() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        inputContinuation?.finish()
        inputContinuation = nil
    }

    private func resumeSpeechContinuation() {
        guard let continuation = speechContinuation else { return }
        speechContinuation = nil
        continuation.resume()
    }

    /// Pick a locale SpeechTranscriber actually supports. Tries (1) the
    /// system locale, (2) en-US explicitly, (3) any "en-*" variant the
    /// device exposes. The final hard-coded fallback exists only so the
    /// function returns *something* — if it's reached, downstream
    /// pipeline build will likely fail with `recognizerUnavailable`.
    private func preferredLocale() async -> Locale {
        let candidate = Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
            return match
        }
        if let enUS = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en-US"))
        {
            return enUS
        }
        let supported = await SpeechTranscriber.supportedLocales
        if let anyEn = supported.first(where: { $0.language.languageCode?.identifier == "en" }) {
            return anyEn
        }
        return Locale(identifier: "en-US")
    }

    private func ensureModelInstalled(for locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return
        }
        // Need to construct a transcriber to ask AssetInventory for the
        // installation request. This doesn't start any audio work.
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                log.event("model_download_start")
                try await request.downloadAndInstall()
                log.event("model_downloaded")
            }
        } catch {
            throw VoiceCaptureError.recognition(
                "model download failed: \(error.localizedDescription)")
        }
    }

    /// One active recognition session: the modules feeding it, the
    /// analyzer running it, and the audio format they negotiated. Built
    /// per turn; can't be reused after `finalize()` or `cancel()`.
    private struct RecognitionPipeline: Sendable {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat

        func finalize() async throws {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        func cancel() async {
            await analyzer.cancelAndFinishNow()
        }
    }

    /// Build a fresh SpeechAnalyzer pipeline. Always returns a new
    /// instance because analyzers can't be resumed after `finalize*` or
    /// `cancelAndFinishNow`. Per-turn cost is small: the underlying model
    /// stays loaded via `Options.modelRetention = .processLifetime`, and
    /// `cachedFormat` + `analysisContext` are reused across turns.
    private func buildPipeline(locale: Locale) async throws -> RecognitionPipeline {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription,
        )

        let context: AnalysisContext
        if let existing = analysisContext {
            context = existing
        } else {
            let fresh = AnalysisContext()
            fresh.contextualStrings[.general] = Self.contextualVocabulary
            analysisContext = fresh
            context = fresh
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .processLifetime,
            ),
        )
        try await analyzer.setContext(context)

        let format: AVAudioFormat
        if let cached = cachedFormat, pipelineLocale == locale {
            format = cached
        } else {
            guard
                let resolved = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber],
                )
            else {
                throw VoiceCaptureError.recognizerUnavailable
            }
            format = resolved
        }

        return RecognitionPipeline(
            transcriber: transcriber,
            analyzer: analyzer,
            format: format,
        )
    }

    private func requestAuthorization() async throws {
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

        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation {
            continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw VoiceCaptureError.speechRecognitionDenied
        }
    }

    /// RMS amplitude of a float32 audio buffer in [0, 1]. ~0 for
    /// silence, ~0.05+ for normal speech at typical mic distance.
    /// Returns 0 for non-float buffers — shouldn't occur for
    /// AVAudioEngine input nodes on iOS, which deliver float32.
    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.floatChannelData else {
            return 0
        }
        let samples = channelData[0]
        var sumSquares: Float = 0
        for i in 0 ..< frameLength {
            let sample = samples[i]
            sumSquares += sample * sample
        }
        return (sumSquares / Float(frameLength)).squareRoot()
    }

    /// Convert a buffer between formats using a long-lived AVAudioConverter.
    /// Nil-returns on conversion failure; the buffer is dropped silently.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat,
    ) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 0.5,
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return nil }
        return output
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
}

// MARK: - Preview implementation

#if DEBUG
    /// Fake capture+synth for SwiftUI previews. Returns a canned transcript
    /// after a short delay; both cancels are no-ops.
    @MainActor
    final class PreviewVoice: VoiceCapture, VoiceSynthesizer {
        var transcript: String

        init(transcript: String = "play chainsmoking") {
            self.transcript = transcript
        }

        func prewarm() async {}

        func startRecording(onEvent: @escaping @MainActor (VoiceCaptureEvent) -> Void) async throws
            -> String
        {
            onEvent(.micHot)
            try? await Task.sleep(for: .milliseconds(150))
            onEvent(.speechStarted)
            try? await Task.sleep(for: .milliseconds(300))
            onEvent(.speechEnded)
            return transcript
        }

        func stopRecording() {}

        // Satisfies both VoiceCapture.cancel and VoiceSynthesizer.cancel.
        func cancel() {}

        func speak(_: String) async {
            // No-op in previews.
        }
    }
#endif
