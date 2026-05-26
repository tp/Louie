//
//  HeyLouieFakeState.swift
//  Louie
//
//  iPad-local fake state the Hey-Louie voice agent mutates via tool calls.
//  Standing in for the real Linn/lights/climate subsystems while we wire up
//  the WebSocket-driven backend. Persists across turns for the lifetime of
//  the owning `HeyLouieWebSocketAgent`.
//

import Foundation
import Observation

@MainActor
@Observable
final class HeyLouieFakeState {
    /// Snake-case raw values match the room identifiers in the tool schemas
    /// (see `HeyLouieSchemas.all`) and the backend's reference impl.
    enum Room: String, Codable, CaseIterable, Sendable {
        case livingRoom = "living_room"
        case kitchen
        case bedroom

        var displayName: String {
            switch self {
            case .livingRoom: "Living room"
            case .kitchen: "Kitchen"
            case .bedroom: "Bedroom"
            }
        }
    }

    // Music
    var nowPlayingId: String?
    var nowPlayingTitle: String?
    var isPlaying: Bool = false
    var volume: Int = 50

    // Lights & climate, keyed by Room
    var lightOn: [Room: Bool] = Dictionary(uniqueKeysWithValues: Room.allCases.map { ($0, false) })
    var lightBrightness: [Room: Int] = Dictionary(uniqueKeysWithValues: Room.allCases.map { ($0, 100) })
    var targetC: [Room: Double] = Dictionary(uniqueKeysWithValues: Room.allCases.map { ($0, 20.0) })
}
