//
//  WebRTCRealtimeVoiceTransport.swift
//  Louie
//

import AVFoundation
import Foundation
import OSLog
@preconcurrency import WebRTC

enum WebRTCRealtimeVoiceTransportError: LocalizedError {
    case peerConnectionUnavailable
    case offerFailed(String)
    case localDescriptionFailed(String)
    case remoteDescriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .peerConnectionUnavailable: "Could not create a WebRTC peer connection."
        case let .offerFailed(message): "WebRTC offer failed: \(message)"
        case let .localDescriptionFailed(message): "WebRTC local description failed: \(message)"
        case let .remoteDescriptionFailed(message): "WebRTC remote description failed: \(message)"
        }
    }
}

@MainActor
final class WebRTCRealtimeVoiceTransport: NSObject {
    private let factory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private static let logger = Logger(subsystem: "Louie", category: "WebRTCRealtimeVoiceTransport")
    private static let doneMinimumDrainDelay: Duration = .milliseconds(1500)
    private static let doneEstimatedDurationTail: Duration = .milliseconds(750)
    private static let doneFallbackDrainDelay: Duration = .seconds(12)
    private static let doneMaximumDrainWait: Duration = .seconds(30)

    func startAndCreateOffer() async throws -> String {
        try configureAudioSession()

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

        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "louie-microphone")
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

    func finishAfterServerDone() async {
        localAudioTrack?.isEnabled = false
        await waitForRemoteAudioToDrain()
        close()
    }

    func close() {
        localAudioTrack?.isEnabled = false
        localAudioTrack = nil
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
        guard let peerConnection else {
            return
        }

        // WebRTC does not expose a playout-drained callback here. Audio level
        // can go quiet once RTP stops arriving, even while the playout buffer
        // still has speech queued, so use received audio duration as the
        // conservative client-side bound before tearing down the connection.
        let drainDelay: Duration
        if let duration = await remoteAudioDuration(on: peerConnection) {
            drainDelay = Self.boundedDrainDelay(forRemoteAudioDuration: duration)
        } else {
            drainDelay = Self.doneFallbackDrainDelay
        }

        Self.logger.info("Waiting \(String(describing: drainDelay), privacy: .public) for remote audio playout after done")
        try? await Task.sleep(for: drainDelay)
    }

    private func remoteAudioDuration(on peerConnection: RTCPeerConnection) async -> Duration? {
        let receivers = peerConnection.receivers.filter { receiver in
            receiver.track?.kind == kRTCMediaStreamTrackKindAudio
        }
        guard !receivers.isEmpty else {
            return nil
        }

        var durations: [Double] = []
        for receiver in receivers {
            if let duration = await receiverAudioDuration(receiver, on: peerConnection) {
                durations.append(duration)
            }
        }

        guard let seconds = durations.max() else {
            return nil
        }
        return .milliseconds(Int64((seconds * 1000).rounded(.up)))
    }

    private func receiverAudioDuration(_ receiver: RTCRtpReceiver, on peerConnection: RTCPeerConnection) async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            peerConnection.statistics(for: receiver) { report in
                var duration: Double?
                for statistics in report.statistics.values {
                    guard statistics.type == "inbound-rtp" || statistics.type == "track" else {
                        continue
                    }
                    if let totalSamplesDuration = statistics.values["totalSamplesDuration"] as? NSNumber {
                        duration = max(duration ?? 0, totalSamplesDuration.doubleValue)
                    }
                    if let totalSamplesReceived = statistics.values["totalSamplesReceived"] as? NSNumber {
                        duration = max(duration ?? 0, totalSamplesReceived.doubleValue / 48_000)
                    }
                }
                continuation.resume(returning: duration)
            }
        }
    }

    private static func boundedDrainDelay(forRemoteAudioDuration duration: Duration) -> Duration {
        min(max(duration + doneEstimatedDurationTail, doneMinimumDrainDelay), doneMaximumDrainWait)
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
