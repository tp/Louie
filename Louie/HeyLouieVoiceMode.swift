//
//  HeyLouieVoiceMode.swift
//  Louie
//

enum HeyLouieVoiceMode {
    case legacyPushToTalk
    case realtimeWebRTC

    static let current: Self = .realtimeWebRTC
}
