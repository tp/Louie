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
    private nonisolated static let logger = Logger(subsystem: "Louie", category: "WebRTCRealtimeVoiceTransport")
    private static let doneDrainDelay: Duration = .milliseconds(1500)
    private static let dataChannelOpenTimeout: Duration = .seconds(3)
    private static let dataChannelDrainTimeout: Duration = .seconds(2)
    private static let startupBackfillCatchUpTimeout: Duration = .seconds(2)

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
            summary.merge(try await sendStartupAudioBackfillUntilCaughtUp())
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
            "Startup audio backfill complete; sent_batches=\(summary.sentBatches, privacy: .public) sent_bytes=\(summary.sentBytes, privacy: .public) source_chunks=\(summary.sourceChunks, privacy: .public) speech_chunks=\(summary.speechChunks, privacy: .public) source_duration=\(summary.sourceDuration, privacy: .public)"
        )
        try Task.checkCancellation()
        localAudioTrack?.isEnabled = true
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
            try sendRealtimeEvent([
                "type": "input_audio_buffer.append",
                "audio": batch.base64EncodedString(),
            ])
        }
        return RealtimeStartupAudioBackfillSummary(backfill)
    }

    private func sendStartupAudioBackfillUntilCaughtUp() async throws -> RealtimeStartupAudioBackfillSummary {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.startupBackfillCatchUpTimeout)
        var summary = RealtimeStartupAudioBackfillSummary()
        while true {
            summary.merge(try await sendStartupAudioBackfill())
            try Task.checkCancellation()
            guard clock.now < deadline else {
                Self.logger.info("Startup audio backfill catch-up timeout reached")
                return summary
            }
            try await Task.sleep(for: .milliseconds(20))
            guard let startupCapture, await startupCapture.hasBufferedAudio else {
                return summary
            }
        }
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

    private func waitForRemoteAudioToDrain() async {
        Self.logger.info("Waiting \(String(describing: Self.doneDrainDelay), privacy: .public) for remote audio playout after done")
        try? await Task.sleep(for: Self.doneDrainDelay)
    }
}

extension WebRTCRealtimeVoiceTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
}

extension WebRTCRealtimeVoiceTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Self.logger.debug("Realtime data channel state changed: \(dataChannel.readyState.rawValue, privacy: .public)")
    }

    nonisolated func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let message = String(data: buffer.data, encoding: .utf8) else {
            Self.logger.debug("Realtime data channel received \(buffer.data.count, privacy: .public) binary byte(s)")
            return
        }
        Self.logger.debug("Realtime data channel received: \(message, privacy: .public)")
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

    var hasBufferedAudio: Bool {
        get async {
            await store.hasBufferedAudio
        }
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

    init() {}

    init(_ backfill: RealtimeStartupAudioBackfill) {
        sentBatches = backfill.batches.count
        sentBytes = backfill.byteCount
        sourceChunks = backfill.totalChunks
        speechChunks = backfill.speechChunks
        sourceDuration = backfill.totalDuration
    }

    mutating func merge(_ other: RealtimeStartupAudioBackfillSummary) {
        sentBatches += other.sentBatches
        sentBytes += other.sentBytes
        sourceChunks += other.sourceChunks
        speechChunks += other.speechChunks
        sourceDuration += other.sourceDuration
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

    private static let maximumBufferedDuration: TimeInterval = 8
    private static let speechThreshold: Float = 0.0015
    private static let maxBatchBytes = 48_000

    var hasBufferedAudio: Bool {
        !chunks.isEmpty
    }

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
        let batches = Self.batches(from: chunks.map(\.data))
        return RealtimeStartupAudioBackfill(
            batches: batches,
            totalChunks: totalChunks,
            speechChunks: speechChunks,
            totalDuration: totalDuration
        )
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
