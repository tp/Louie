//
//  HeyLouieVoiceMode.swift
//  Louie
//

enum HeyLouieVoiceMode {
    /// Apple STT → backend WebSocket agent loop (multiple server-side model
    /// invocations) → Apple TTS. `VoiceAgentController` + `HeyLouieWebSocketAgent`.
    case legacyPushToTalk
    /// OpenAI realtime speech-to-speech over WebRTC. `RealtimeVoiceController`.
    /// iOS-only — WebRTC + AVAudioSession aren't available on native macOS.
    #if os(iOS)
    case realtimeWebRTC
    #endif
    /// On-device Apple Intelligence ("siri mode"). Apple STT → local
    /// `FoundationModels` `LanguageModelSession` with Swift tools → Apple TTS.
    /// `VoiceAgentController` + `AppleIntelligenceVoiceAgent`.
    case onDeviceFoundationModels

    /// Compile-time mode selector — flip the value and rebuild to benchmark a
    /// different backend. No runtime UI picker by design.
    static let current: Self = .onDeviceFoundationModels
}
