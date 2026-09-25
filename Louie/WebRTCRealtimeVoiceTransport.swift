//
//  WebRTCRealtimeVoiceTransport.swift
//  Louie
//

@preconcurrency import AVFoundation
import Foundation
import OSLog
@preconcurrency import WebRTC

enum WebRTCRealtimeVoiceTransportError: LocalizedError {
    case peerConnectionUnavailable
    case offerFailed(String)
    case localDescriptionFailed(String)
    case remoteDescriptionFailed(String)
    case dataChannelUnavailable
    case dataChannelSendFailed

    var errorDescription: String? {
        switch self {
        case .peerConnectionUnavailable: "Could not create a WebRTC peer connection."
        case let .offerFailed(message): "WebRTC offer failed: \(message)"
        case let .localDescriptionFailed(message): "WebRTC local description failed: \(message)"
        case let .remoteDescriptionFailed(message): "WebRTC remote description failed: \(message)"
        case .dataChannelUnavailable: "Realtime data channel did not open."
        case .dataChannelSendFailed: "Realtime data channel could not send startup audio."
        }
    }
}

@MainActor
final class WebRTCRealtimeVoiceTransport: NSObject {
    private let factory = RTCPeerConnectionFactory()
    private let startupAudioBackfillEnabled: Bool
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var dataChannel: RTCDataChannel?
    private var startupCapture: RealtimeStartupAudioCapture?
    /// Driven by `output_audio_buffer.started/stopped/cleared` events on the data
    /// channel: whether the model is currently speaking, and whether it ever did
    /// this turn. Used to hold teardown until the reply has actually finished.
    private var isOutputAudioActive = false
    private var didObserveOutputAudio = false
    /// DEBUG: when true, the exact PCM bytes sent as startup backfill are
    /// accumulated and written to a WAV in the app's Documents directory so the
    /// captured audio can be auditioned directly (isolates capture/format issues
    /// from transport/server interpretation). Remove once backfill is trusted.
    private static let debugDumpBackfillWAV = true
    /// DEBUG: when true, the backfill audio is played back through the speaker
    /// right after it's sent, so you can hear exactly what the model received
    /// without extracting the file from the device.
    private static let debugPlayBackfillAfterSending = true
    private var debugBackfillPCM = Data()
    private var debugBackfillPlayer: AVAudioPlayer?
    private nonisolated static let logger = Logger(subsystem: "Louie", category: "WebRTCRealtimeVoiceTransport")
    /// How long after the server's `done` we wait for output audio to *begin*,
    /// in case `done` arrives before the spoken reply starts (or there is no
    /// spoken reply at all, e.g. a tool-only turn).
    private static let doneStartGrace: Duration = .seconds(2)
    /// Flush time after the output-audio buffer stops, to let the last buffered
    /// samples play out before we close the peer connection.
    private static let doneTailDelay: Duration = .milliseconds(400)
    /// Hard safety cap so a missing `stopped` event can't hang teardown forever.
    private static let doneMaximumDrainWait: Duration = .seconds(30)
    private static let dataChannelOpenTimeout: Duration = .seconds(3)
    private static let dataChannelDrainTimeout: Duration = .seconds(2)
    private static let iceConnectTimeout: Duration = .seconds(20)
    /// Set when the peer connection is created; all connectivity-state log lines
    /// report their elapsed time relative to this, so the connection timeline
    /// (ICE gathering → ICE connected → data channel open) is visible.
    private var connectStart: ContinuousClock.Instant?

    init(startupAudioBackfillEnabled: Bool = false) {
        self.startupAudioBackfillEnabled = startupAudioBackfillEnabled
        super.init()
    }

    func startStartupAudioCapture() async throws {
        guard startupAudioBackfillEnabled else { return }
        let capture = RealtimeStartupAudioCapture()
        try await capture.start()
        startupCapture = capture
    }

    func startAndCreateOffer() async throws -> String {
        if startupCapture == nil {
            try configureAudioSession()
        }

        connectStart = ContinuousClock().now

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self,
        ) else {
            throw WebRTCRealtimeVoiceTransportError.peerConnectionUnavailable
        }
        self.peerConnection = peerConnection

        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true
        guard let dataChannel = peerConnection.dataChannel(
            forLabel: "oai-events",
            configuration: dataChannelConfig
        ) else {
            throw WebRTCRealtimeVoiceTransportError.dataChannelUnavailable
        }
        dataChannel.delegate = self
        self.dataChannel = dataChannel

        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "louie-microphone")
        audioTrack.isEnabled = !startupAudioBackfillEnabled
        localAudioTrack = audioTrack

        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendRecv
        transceiverInit.streamIds = ["louie"]
        peerConnection.addTransceiver(with: audioTrack, init: transceiverInit)

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil,
        )
        let sdp = try await createAndSetLocalOffer(on: peerConnection, constraints: offerConstraints)
        await waitForIceGatheringComplete(on: peerConnection)
        return peerConnection.localDescription?.sdp ?? sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let peerConnection else {
            throw WebRTCRealtimeVoiceTransportError.peerConnectionUnavailable
        }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await setRemoteDescription(answer, on: peerConnection)
    }

    func finishStartupAudioBackfillAndEnableLiveMicrophone() async throws {
        guard startupAudioBackfillEnabled else {
            localAudioTrack?.isEnabled = true
            return
        }
        var summary = RealtimeStartupAudioBackfillSummary()
        do {
            try await waitForDataChannelOpen(timeout: Self.dataChannelOpenTimeout)
            // The connect typically outlasts the (one-shot, push-to-talk)
            // utterance, so capture is already complete: stop it, then send the
            // whole buffered utterance — trimmed to speech — in one pass.
            await startupCapture?.finishCapturing()
            summary.merge(try await sendStartupAudioBackfill(logEmptyDrain: false))
            try await waitForDataChannelToDrain(timeout: Self.dataChannelDrainTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.warning("Startup audio backfill skipped: \(error.localizedDescription, privacy: .public)")
        }

        startupCapture?.stop()
        startupCapture = nil
        Self.logger.info(
            "Startup audio backfill complete; sent_batches=\(summary.sentBatches, privacy: .public) sent_bytes=\(summary.sentBytes, privacy: .public) source_chunks=\(summary.sourceChunks, privacy: .public) speech_chunks=\(summary.speechChunks, privacy: .public) source_duration=\(summary.sourceDuration, privacy: .public) sent_duration=\(summary.sentDuration, privacy: .public)"
        )
        if Self.debugDumpBackfillWAV { writeDebugBackfillWAV() }
        try Task.checkCancellation()
        localAudioTrack?.isEnabled = true
    }

    /// DEBUG: builds a 24 kHz mono 16-bit WAV from the accumulated backfill PCM
    /// (exactly what we base64-sent), writes it to Documents, and optionally
    /// plays it through the speaker. If it sounds mangled, the fault is
    /// capture/format; if clean, the fault is transport/server interpretation.
    private func writeDebugBackfillWAV() {
        let pcm = debugBackfillPCM
        debugBackfillPCM = Data()
        guard !pcm.isEmpty else {
            Self.logger.info("Debug backfill WAV skipped: no PCM accumulated")
            return
        }
        let sampleRate: UInt32 = 24000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataLen = UInt32(pcm.count)

        var wav = Data()
        func append(_ string: String) { wav.append(contentsOf: string.utf8) }
        func append(le32 value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append(le16 value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }

        append("RIFF"); append(le32: 36 + dataLen); append("WAVE")
        append("fmt "); append(le32: 16); append(le16: 1); append(le16: channels)
        append(le32: sampleRate); append(le32: byteRate); append(le16: blockAlign); append(le16: bitsPerSample)
        append("data"); append(le32: dataLen)
        wav.append(pcm)

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("backfill-\(Int(Date().timeIntervalSince1970)).wav")
        do {
            try wav.write(to: url)
            Self.logger.info("Debug backfill WAV written: \(url.path, privacy: .public) bytes=\(pcm.count, privacy: .public)")
        } catch {
            Self.logger.warning("Debug backfill WAV write failed: \(error.localizedDescription, privacy: .public)")
        }

        if Self.debugPlayBackfillAfterSending {
            do {
                let player = try AVAudioPlayer(data: wav)
                player.prepareToPlay()
                player.play()
                debugBackfillPlayer = player // retain so it isn't deallocated mid-playback
                Self.logger.info("Debug backfill playback started; duration=\(player.duration, privacy: .public)s")
            } catch {
                Self.logger.warning("Debug backfill playback failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Tracks the model's spoken-output lifecycle from data-channel events so
    /// teardown can wait for the reply to actually finish (see
    /// `waitForRemoteAudioToDrain`).
    private func handleRealtimeEvent(type: String) {
        switch type {
        case "output_audio_buffer.started":
            isOutputAudioActive = true
            didObserveOutputAudio = true
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared":
            isOutputAudioActive = false
        default:
            break
        }
    }

    func finishAfterServerDone() async {
        localAudioTrack?.isEnabled = false
        await waitForRemoteAudioToDrain()
        close()
    }

    func close() {
        startupCapture?.stop()
        startupCapture = nil
        localAudioTrack?.isEnabled = false
        localAudioTrack = nil
        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.receivers.forEach { receiver in
            receiver.track?.isEnabled = false
        }
        peerConnection?.close()
        peerConnection = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker],
        )
        try session.setActive(true)
    }

    private func createAndSetLocalOffer(
        on peerConnection: RTCPeerConnection,
        constraints: RTCMediaConstraints,
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: WebRTCRealtimeVoiceTransportError.offerFailed(error.localizedDescription))
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: WebRTCRealtimeVoiceTransportError.offerFailed("missing SDP"))
                    return
                }
                peerConnection.setLocalDescription(sdp) { error in
                    if let error {
                        continuation.resume(throwing: WebRTCRealtimeVoiceTransportError.localDescriptionFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: sdp.sdp)
                    }
                }
            }
        }
    }

    private func sendStartupAudioBackfill(logEmptyDrain: Bool = true) async throws -> RealtimeStartupAudioBackfillSummary {
        guard let startupCapture else { return RealtimeStartupAudioBackfillSummary() }
        let backfill = await startupCapture.drainBackfill()
        guard !backfill.batches.isEmpty else {
            if logEmptyDrain {
                Self.logger.info(
                    "No startup audio backfill to send; chunks=\(backfill.totalChunks, privacy: .public) speech_chunks=\(backfill.speechChunks, privacy: .public) duration=\(backfill.totalDuration, privacy: .public)"
                )
            }
            return RealtimeStartupAudioBackfillSummary()
        }

        Self.logger.debug(
            "Sending \(backfill.batches.count, privacy: .public) continuous startup audio backfill chunk(s); bytes=\(backfill.byteCount, privacy: .public) chunks=\(backfill.totalChunks, privacy: .public) speech_chunks=\(backfill.speechChunks, privacy: .public) duration=\(backfill.totalDuration, privacy: .public)"
        )
        for batch in backfill.batches {
            try Task.checkCancellation()
            if Self.debugDumpBackfillWAV { debugBackfillPCM.append(batch) }
            try sendRealtimeEvent([
                "type": "input_audio_buffer.append",
                "audio": batch.base64EncodedString(),
            ])
        }
        return RealtimeStartupAudioBackfillSummary(backfill)
    }

    private func sendRealtimeEvent(_ payload: [String: Any]) throws {
        guard let dataChannel, dataChannel.readyState == .open else {
            throw WebRTCRealtimeVoiceTransportError.dataChannelUnavailable
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        guard dataChannel.sendData(buffer) else {
            throw WebRTCRealtimeVoiceTransportError.dataChannelSendFailed
        }
    }

    private func waitForDataChannelOpen(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while dataChannel?.readyState != .open {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw WebRTCRealtimeVoiceTransportError.dataChannelUnavailable
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForDataChannelToDrain(timeout: Duration) async throws {
        guard let dataChannel else {
            throw WebRTCRealtimeVoiceTransportError.dataChannelUnavailable
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while dataChannel.bufferedAmount > 0 {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                Self.logger.info("Proceeding before Realtime data channel fully drained")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func setRemoteDescription(
        _ sdp: RTCSessionDescription,
        on peerConnection: RTCPeerConnection,
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(sdp) { error in
                if let error {
                    continuation.resume(throwing: WebRTCRealtimeVoiceTransportError.remoteDescriptionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Awaits the ICE connection reaching `connected`/`completed` — i.e. the
    /// media path (audio return channel) is actually live, not merely that the
    /// answer was applied. Returns on timeout so a slow/failed connect still
    /// proceeds (and is visible in the enclosing span / logs).
    func waitUntilConnected() async throws {
        guard let peerConnection else {
            throw WebRTCRealtimeVoiceTransportError.peerConnectionUnavailable
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.iceConnectTimeout)
        while true {
            switch peerConnection.iceConnectionState {
            case .connected, .completed:
                return
            default:
                break
            }
            try Task.checkCancellation()
            guard clock.now < deadline else {
                Self.logger.info("Proceeding before ICE connection established; state=\(peerConnection.iceConnectionState.rawValue, privacy: .public)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Logs a connectivity-state transition with its elapsed time since the peer
    /// connection was created, so the connect timeline is reconstructable.
    private func logConnectivity(_ kind: String, rawState: Int, at instant: ContinuousClock.Instant) {
        let elapsed = connectStart.map { String(describing: $0.duration(to: instant)) } ?? "n/a"
        Self.logger.info("WebRTC \(kind, privacy: .public) state=\(rawState, privacy: .public) elapsed=\(elapsed, privacy: .public)")
    }

    private func waitForIceGatheringComplete(on peerConnection: RTCPeerConnection) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while peerConnection.iceGatheringState != .complete, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if peerConnection.iceGatheringState != .complete {
            Self.logger.info("Proceeding with WebRTC offer before ICE gathering reached complete")
        }
    }

    /// Waits until the model's spoken reply has finished playing out before the
    /// caller tears down the peer connection. The server's `done` (a control
    /// signal) can arrive while the reply is still playing — or before it even
    /// starts — so we key off the `output_audio_buffer` events instead of a
    /// fixed timer. Bounded by `doneMaximumDrainWait` so a missing `stopped`
    /// event can't hang teardown.
    private func waitForRemoteAudioToDrain() async {
        let clock = ContinuousClock()
        let overallDeadline = clock.now.advanced(by: Self.doneMaximumDrainWait)
        let startGraceDeadline = clock.now.advanced(by: Self.doneStartGrace)

        while clock.now < overallDeadline {
            if isOutputAudioActive {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if !didObserveOutputAudio {
                // No spoken reply yet. Give it a moment to start (the `done`
                // control signal can precede the audio); if nothing begins
                // within the grace window, assume a silent turn and proceed.
                if clock.now >= startGraceDeadline {
                    Self.logger.info("No output audio after done within start grace; proceeding with teardown")
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            // Audio played and is no longer active. Let a tail flush, then
            // confirm it didn't resume (a brief mid-reply pause) before closing.
            try? await Task.sleep(for: Self.doneTailDelay)
            if !isOutputAudioActive {
                Self.logger.info("Output audio finished; proceeding with teardown")
                return
            }
        }
        Self.logger.info("Reached max drain wait; tearing down with output_audio_active=\(self.isOutputAudioActive, privacy: .public)")
    }
}

extension WebRTCRealtimeVoiceTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let now = ContinuousClock().now
        Task { @MainActor [weak self] in self?.logConnectivity("ice_connection", rawState: newState.rawValue, at: now) }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        let now = ContinuousClock().now
        Task { @MainActor [weak self] in self?.logConnectivity("ice_gathering", rawState: newState.rawValue, at: now) }
    }

    nonisolated func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
}

extension WebRTCRealtimeVoiceTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let now = ContinuousClock().now
        let rawState = dataChannel.readyState.rawValue
        Task { @MainActor [weak self] in self?.logConnectivity("data_channel", rawState: rawState, at: now) }
    }

    nonisolated func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = String(data: buffer.data, encoding: .utf8) else {
            Self.logger.debug("Realtime data channel received \(buffer.data.count, privacy: .public) binary byte(s)")
            return
        }
        Self.logger.debug("Realtime data channel received: \(message, privacy: .public)")
        guard let type = Self.eventType(from: buffer.data) else { return }
        Task { @MainActor [weak self] in self?.handleRealtimeEvent(type: type) }
    }

    private nonisolated static func eventType(from data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data)
        return (object as? [String: Any])?["type"] as? String
    }
}

@MainActor
private final class RealtimeStartupAudioCapture {
    /// Captured PCM16 chunk, carried in order from the audio tap to the store.
    private struct Chunk: Sendable {
        var data: Data
        var duration: TimeInterval
        var rms: Float
    }

    private let store = RealtimeStartupAudioBackfillStore()
    private var audioEngine: AVAudioEngine?
    private var didLogFirstTap = false
    /// The audio tap runs on a realtime thread and yields here synchronously,
    /// so chunks reach `store` in strict capture order; a single consumer task
    /// drains the stream. This replaces per-buffer `Task { await … }` spawning,
    /// whose completion order is not guaranteed and scrambled the audio.
    private var captureContinuation: AsyncStream<Chunk>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private nonisolated static let logger = Logger(subsystem: "Louie", category: "RealtimeStartupAudioCapture")

    private static let sampleRate = 24000.0
    private static let channelCount: AVAudioChannelCount = 1

    func start() async throws {
        stop()

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

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            throw VoiceCaptureError.audioEngine(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        ) else {
            throw VoiceCaptureError.audioEngine("Could not create startup audio format.")
        }
        Self.logger.info(
            "Starting startup capture; native_rate=\(nativeFormat.sampleRate, privacy: .public) native_channels=\(nativeFormat.channelCount, privacy: .public)"
        )

        let converter =
            nativeFormat == targetFormat
                ? nil
                : AVAudioConverter(from: nativeFormat, to: targetFormat)

        // Wire the ordered capture pipeline before installing the tap so no
        // early buffer is dropped: the tap yields chunks in order and a single
        // consumer appends them to the store in that same order.
        let (stream, continuation) = AsyncStream<Chunk>.makeStream()
        captureContinuation = continuation
        let store = store
        consumerTask = Task {
            for await chunk in stream {
                await store.append(data: chunk.data, duration: chunk.duration, rms: chunk.rms)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { buffer, _ in
            let converted: AVAudioPCMBuffer?
            if let converter {
                converted = Self.convert(buffer, with: converter, to: targetFormat)
            } else {
                converted = buffer
            }
            guard let converted,
                  let data = Self.pcm16Data(from: converted),
                  !data.isEmpty
            else {
                Self.logger.warning("Startup capture dropped a buffer during conversion")
                return
            }

            let duration = Double(converted.frameLength) / converted.format.sampleRate
            let rms = Self.computeRMS(buffer)
            continuation.yield(Chunk(data: data, duration: duration, rms: rms))
            Task { @MainActor [weak self] in
                guard let self, !didLogFirstTap else { return }
                didLogFirstTap = true
                Self.logger.info(
                    "Startup capture received first buffer; frames=\(converted.frameLength, privacy: .public) rms=\(rms, privacy: .public)"
                )
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw VoiceCaptureError.audioEngine(error.localizedDescription)
        }
        audioEngine = engine
        Self.logger.info("Startup capture engine started")
    }

    func drainBackfill() async -> RealtimeStartupAudioBackfill {
        await store.drainBackfill()
    }

    /// Stops capture and waits for every already-captured chunk to land in the
    /// store, so a subsequent `drainBackfill()` sees the complete tail. Use
    /// this on the flush path; `stop()` is the synchronous teardown.
    func finishCapturing() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        didLogFirstTap = false
        captureContinuation?.finish()
        captureContinuation = nil
        await consumerTask?.value
        consumerTask = nil
    }

    func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        didLogFirstTap = false
        captureContinuation?.finish()
        captureContinuation = nil
        consumerTask?.cancel()
        consumerTask = nil
    }

    private static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.int16ChannelData else {
            return nil
        }
        return Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
    }

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

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 0.5
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
}

private struct RealtimeStartupAudioBackfill: Sendable {
    var batches: [Data]
    var totalChunks: Int
    var speechChunks: Int
    var totalDuration: TimeInterval
    /// Duration actually sent after trimming surrounding silence.
    var sentDuration: TimeInterval

    var byteCount: Int {
        batches.reduce(0) { $0 + $1.count }
    }
}

private struct RealtimeStartupAudioBackfillSummary: Sendable {
    var sentBatches = 0
    var sentBytes = 0
    var sourceChunks = 0
    var speechChunks = 0
    var sourceDuration: TimeInterval = 0
    var sentDuration: TimeInterval = 0

    init() {}

    init(_ backfill: RealtimeStartupAudioBackfill) {
        sentBatches = backfill.batches.count
        sentBytes = backfill.byteCount
        sourceChunks = backfill.totalChunks
        speechChunks = backfill.speechChunks
        sourceDuration = backfill.totalDuration
        sentDuration = backfill.sentDuration
    }

    mutating func merge(_ other: RealtimeStartupAudioBackfillSummary) {
        sentBatches += other.sentBatches
        sentBytes += other.sentBytes
        sourceChunks += other.sourceChunks
        speechChunks += other.speechChunks
        sourceDuration += other.sourceDuration
        sentDuration += other.sentDuration
    }
}

private actor RealtimeStartupAudioBackfillStore {
    private struct Chunk {
        var data: Data
        var duration: TimeInterval
        var isSpeech: Bool
    }

    private var chunks: [Chunk] = []
    private var totalDuration: TimeInterval = 0

    /// Safety ceiling only — high enough that a slow connect never evicts the
    /// user's opening words (the bug that made backfill replay silence). The
    /// speech-trim on drain is what actually bounds what we send.
    private static let maximumBufferedDuration: TimeInterval = 120
    private static let speechThreshold: Float = 0.0015
    /// Audio kept before the first / after the last speech chunk, so we don't
    /// clip onsets or tails when trimming the surrounding silence.
    private static let preRollDuration: TimeInterval = 0.3
    private static let tailDuration: TimeInterval = 0.4
    private static let maxBatchBytes = 48_000

    func append(data: Data, duration: TimeInterval, rms: Float) {
        chunks.append(Chunk(
            data: data,
            duration: duration,
            isSpeech: rms > Self.speechThreshold
        ))
        totalDuration += duration

        while totalDuration > Self.maximumBufferedDuration, let first = chunks.first {
            totalDuration -= first.duration
            chunks.removeFirst()
        }
    }

    func drainBackfill() -> RealtimeStartupAudioBackfill {
        defer {
            chunks.removeAll()
            totalDuration = 0
        }

        let totalChunks = chunks.count
        let totalDuration = chunks.reduce(0) { $0 + $1.duration }
        let speechChunks = chunks.count { $0.isSpeech }
        let trimmed = trimmedToSpeech(chunks)
        let batches = Self.batches(from: trimmed.map(\.data))
        return RealtimeStartupAudioBackfill(
            batches: batches,
            totalChunks: totalChunks,
            speechChunks: speechChunks,
            totalDuration: totalDuration,
            sentDuration: trimmed.reduce(0) { $0 + $1.duration }
        )
    }

    /// Returns the contiguous run from `preRollDuration` before the first speech
    /// chunk to `tailDuration` after the last, dropping the silence on either
    /// side. The run is contiguous, so inter-word pauses are preserved (no
    /// splicing that would distort timing). Falls back to the whole buffer when
    /// no chunk reads as speech, so a mis-tuned threshold never sends nothing.
    private func trimmedToSpeech(_ chunks: [Chunk]) -> [Chunk] {
        guard let firstSpeech = chunks.firstIndex(where: \.isSpeech),
              let lastSpeech = chunks.lastIndex(where: \.isSpeech)
        else {
            return chunks
        }

        var start = firstSpeech
        var preRoll = 0.0
        while start > 0, preRoll < Self.preRollDuration {
            start -= 1
            preRoll += chunks[start].duration
        }

        var end = lastSpeech
        var tail = 0.0
        while end < chunks.count - 1, tail < Self.tailDuration {
            end += 1
            tail += chunks[end].duration
        }

        return Array(chunks[start ... end])
    }

    private static func batches(from chunks: [Data]) -> [Data] {
        var batches: [Data] = []
        var current = Data()
        for chunk in chunks {
            if current.count + chunk.count > maxBatchBytes, !current.isEmpty {
                batches.append(current)
                current.removeAll(keepingCapacity: true)
            }

            if chunk.count > maxBatchBytes {
                var offset = 0
                while offset < chunk.count {
                    let end = min(offset + maxBatchBytes, chunk.count)
                    batches.append(chunk.subdata(in: offset ..< end))
                    offset = end
                }
            } else {
                current.append(chunk)
            }
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }
}
