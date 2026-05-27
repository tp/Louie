//
//  HeyLouieToolDispatcher.swift
//  Louie
//
//  Executes the five tool calls the Hey-Louie agent invokes against the
//  iPad-local fake state. Each handler decodes a typed `Decodable` input
//  struct, mutates `HeyLouieFakeState`, and returns the JSON string the
//  backend sees as `tool_result.content`. Result shapes are the wire
//  contract with the backend's reference handlers in
//  `backend/agent/tools.py` — drift here will make the agent's narration go
//  subtly wrong without obvious tool errors. Validation is conservative:
//  bad input throws and the caller surfaces it as `is_error=true`.
//

import Foundation
import Linn

enum HeyLouieToolError: LocalizedError {
    case unknownTool(String)
    case badArgument(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name): "unknown tool: \(name)"
        case let .badArgument(detail): detail
        }
    }
}

/// Translates between the long opaque media ids Linn/Qobuz use (gzipped,
/// base64-encoded — often 500+ chars) and short tokens the LLM can
/// reproduce verbatim in a tool call. Without this, the model garbles a
/// character in the long id and the gateway rejects with "Failed to
/// decompress media_id". Agent-scoped so a search in one turn can be
/// played in a later turn.
@MainActor
final class HeyLouieMediaIdMap {
    private var realByShort: [String: String] = [:]
    private var shortByReal: [String: String] = [:]
    private var nextSequence = 1

    func register(_ realID: String) -> String {
        if let existing = shortByReal[realID] {
            return existing
        }
        let short = "m\(nextSequence)"
        nextSequence += 1
        realByShort[short] = realID
        shortByReal[realID] = short
        return short
    }

    func realID(for short: String) -> String? {
        realByShort[short]
    }
}

@MainActor
struct HeyLouieToolDispatcher {
    let state: HeyLouieFakeState
    let linn: Linn?
    let mediaIDs: HeyLouieMediaIdMap?

    /// JSON content string for `tool_result`, or throws.
    func call(name: String, inputJSON: Data) async throws -> String {
        switch name {
        case "search_music": try await searchMusic(inputJSON)
        case "play_music": try await playMusic(inputJSON)
        case "control_lights": try controlLights(inputJSON)
        case "set_climate": try setClimate(inputJSON)
        case "query_state": try queryState(inputJSON)
        default: throw HeyLouieToolError.unknownTool(name)
        }
    }

    // MARK: - search_music

    private struct SearchMusicInput: Decodable {
        let query: String
        let type: String?
    }

    private struct SearchHit: Encodable {
        let id: String
        let type: String
        let title: String
    }

    private func searchMusic(_ data: Data) async throws -> String {
        let input = try decode(SearchMusicInput.self, from: data)
        let trimmed = input.query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw HeyLouieToolError.badArgument("`query` is required and must be a non-empty string")
        }
        let allowedTypes: Set<String> = ["artist", "album", "genre", "playlist", "track"]
        if let type = input.type, !allowedTypes.contains(type) {
            throw HeyLouieToolError.badArgument("unknown type: \(type)")
        }
        if let linn {
            return try await searchMusicViaLinn(query: trimmed, agentType: input.type, linn: linn)
        }
        let hits = HeyLouieCatalog.search(query: input.query, type: input.type)
            .map { SearchHit(id: $0.id, type: $0.type, title: $0.title) }
        return try encode(hits)
    }

    /// Maps the agent's type vocabulary (artist/album/genre/playlist/track)
    /// to Linn's SearchType. Linn has no "genre" type — Qobuz returns the
    /// most useful results when "jazz" is searched as albums, so genre and
    /// missing-type both fall through to albums.
    private static func linnSearchType(from agentType: String?) -> Linn.SearchType {
        switch agentType {
        case "artist": .artists
        case "playlist": .playlists
        case "track": .tracks
        default: .albums
        }
    }

    /// Best-effort classification of a Linn library item back into the
    /// agent's type vocabulary. Falls back to whatever type the agent asked
    /// for so the model's filter assumptions hold.
    private static func resultType(for item: Linn.LibraryItem, fallback: String) -> String {
        let lower = item.kind.lowercased()
        if lower.contains("album") { return "album" }
        if lower.contains("artist") { return "artist" }
        if lower.contains("playlist") { return "playlist" }
        if lower.contains("track") || lower.contains("song") { return "track" }
        return fallback
    }

    private func searchMusicViaLinn(
        query: String,
        agentType: String?,
        linn: Linn,
    ) async throws -> String {
        // No type → fan out across the three common kinds and merge so the
        // model can pick the best match (e.g. "Thriller" → song vs. album).
        // Run sequentially: the Linn CI gateway drops concurrent
        // /V2/services/search requests on the same connection (observed:
        // only one of three parallel searches returns, the others time out).
        // "genre" stays on the albums-only path: Qobuz returns useful album
        // matches for genre words like "jazz".
        if agentType == nil {
            var hits: [SearchHit] = []
            for type in [Linn.SearchType.albums, .artists, .tracks] {
                let page = try await linn.searchLibrary(query: query, type: type, count: 4)
                hits.append(contentsOf: page.items.map { searchHit(for: $0, fallback: "album") })
            }
            return try encode(hits)
        }

        let searchType = Self.linnSearchType(from: agentType)
        let page = try await linn.searchLibrary(query: query, type: searchType, count: 10)
        let fallback = agentType ?? "album"
        let hits = page.items.map { searchHit(for: $0, fallback: fallback) }
        return try encode(hits)
    }

    /// Substitute Linn's long opaque id for a short token the LLM can
    /// reproduce verbatim. The map round-trip happens in `play_music`.
    private func searchHit(for item: Linn.LibraryItem, fallback: String) -> SearchHit {
        let title = item.subtitle.map { "\(item.title) — \($0)" } ?? item.title
        let id = mediaIDs?.register(item.id) ?? item.id
        return SearchHit(
            id: id,
            type: Self.resultType(for: item, fallback: fallback),
            title: title,
        )
    }

    // MARK: - play_music

    private struct PlayMusicInput: Decodable {
        let id: String
    }

    private struct PlayMusicResult: Encodable {
        let ok: Bool
        let id: String
        let nowPlaying: String?
    }

    private func playMusic(_ data: Data) async throws -> String {
        let input = try decode(PlayMusicInput.self, from: data)
        if let linn {
            // Resolve the short LLM-friendly token back to the long Qobuz
            // media id that Linn's gateway requires.
            guard let realID = mediaIDs?.realID(for: input.id) else {
                throw HeyLouieToolError.badArgument(
                    "`id` must be a token returned by search_music in this session, got \(input.id)",
                )
            }
            // Linn.play(_:placement:) only reads `item.id`; the other
            // LibraryItem fields are unused on the wire to the gateway.
            let stub = Linn.LibraryItem(id: realID, kind: "", title: "")
            linn.play(stub, placement: .replace)
            state.nowPlayingId = input.id
            state.nowPlayingTitle = nil
            state.isPlaying = true
            return try encode(PlayMusicResult(ok: true, id: input.id, nowPlaying: nil))
        }
        guard let entry = HeyLouieCatalog.byId[input.id] else {
            throw HeyLouieToolError.badArgument(
                "`id` must be a token returned by search_music (e.g. '$id:genre:jazz'), got \(input.id)",
            )
        }
        state.nowPlayingId = input.id
        state.nowPlayingTitle = entry.title
        state.isPlaying = true
        return try encode(PlayMusicResult(ok: true, id: input.id, nowPlaying: entry.title))
    }

    // MARK: - control_lights

    private struct ControlLightsInput: Decodable {
        let room: HeyLouieFakeState.Room
        let on: Bool?
        let brightness: Int?
    }

    private struct OkResult: Encodable {
        let ok: Bool
    }

    private func controlLights(_ data: Data) throws -> String {
        let input = try decode(ControlLightsInput.self, from: data)
        if input.on == nil, input.brightness == nil {
            throw HeyLouieToolError.badArgument("provide at least one of `on` or `brightness`")
        }
        if let brightness = input.brightness, !(0 ... 100).contains(brightness) {
            throw HeyLouieToolError.badArgument("`brightness` must be 0-100, got \(brightness)")
        }
        if let on = input.on {
            state.lightOn[input.room] = on
        }
        if let brightness = input.brightness {
            state.lightBrightness[input.room] = brightness
            // Dimming to >0 without explicit on=false implies turn on.
            if input.on == nil, brightness > 0 {
                state.lightOn[input.room] = true
            }
        }
        return try encode(OkResult(ok: true))
    }

    // MARK: - set_climate

    private struct SetClimateInput: Decodable {
        let room: HeyLouieFakeState.Room
        let targetC: Double
    }

    private struct SetClimateResult: Encodable {
        let ok: Bool
        let room: String
        let targetC: Double
    }

    private func setClimate(_ data: Data) throws -> String {
        let input = try decode(SetClimateInput.self, from: data)
        guard (5.0 ... 35.0).contains(input.targetC) else {
            throw HeyLouieToolError.badArgument("`target_c` must be between 5.0 and 35.0, got \(input.targetC)")
        }
        state.targetC[input.room] = input.targetC
        return try encode(SetClimateResult(ok: true, room: input.room.rawValue, targetC: input.targetC))
    }

    // MARK: - query_state

    private struct QueryStateInput: Decodable {
        let subsystem: String?
    }

    private struct MusicSnapshot: Encodable {
        let id: String?
        let nowPlaying: String?
        let isPlaying: Bool
        let volume: Int
    }

    private struct LightSnapshot: Encodable {
        let on: Bool
        let brightness: Int
    }

    private struct ClimateSnapshot: Encodable {
        let targetC: Double
    }

    private struct AllStateSnapshot: Encodable {
        let music: MusicSnapshot
        let lights: [String: LightSnapshot]
        let climate: [String: ClimateSnapshot]
    }

    private struct MusicEnvelope: Encodable {
        let music: MusicSnapshot
    }

    private struct LightsEnvelope: Encodable {
        let lights: [String: LightSnapshot]
    }

    private struct ClimateEnvelope: Encodable {
        let climate: [String: ClimateSnapshot]
    }

    private func queryState(_ data: Data) throws -> String {
        let input = try decode(QueryStateInput.self, from: data)
        let subsystem = input.subsystem ?? "all"
        switch subsystem {
        case "music":
            return try encode(MusicEnvelope(music: musicSnapshot()))
        case "lights":
            return try encode(LightsEnvelope(lights: lightsSnapshot()))
        case "climate":
            return try encode(ClimateEnvelope(climate: climateSnapshot()))
        case "all":
            return try encode(AllStateSnapshot(
                music: musicSnapshot(),
                lights: lightsSnapshot(),
                climate: climateSnapshot(),
            ))
        default:
            throw HeyLouieToolError.badArgument("unknown subsystem: \(subsystem)")
        }
    }

    private func musicSnapshot() -> MusicSnapshot {
        MusicSnapshot(
            id: state.nowPlayingId,
            nowPlaying: state.nowPlayingTitle,
            isPlaying: state.isPlaying,
            volume: state.volume,
        )
    }

    private func lightsSnapshot() -> [String: LightSnapshot] {
        Dictionary(uniqueKeysWithValues: HeyLouieFakeState.Room.allCases.map { room in
            (room.rawValue, LightSnapshot(
                on: state.lightOn[room] ?? false,
                brightness: state.lightBrightness[room] ?? 100,
            ))
        })
    }

    private func climateSnapshot() -> [String: ClimateSnapshot] {
        Dictionary(uniqueKeysWithValues: HeyLouieFakeState.Room.allCases.map { room in
            (room.rawValue, ClimateSnapshot(targetC: state.targetC[room] ?? 20.0))
        })
    }

    // MARK: - JSON helpers

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw HeyLouieToolError.badArgument("missing required field: \(key.stringValue)")
        } catch let DecodingError.typeMismatch(_, ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw HeyLouieToolError.badArgument(
                "wrong type for field '\(path)': \(ctx.debugDescription)",
            )
        } catch let DecodingError.dataCorrupted(ctx) {
            // Common cause: room raw-value didn't match any enum case.
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw HeyLouieToolError.badArgument(
                "bad value for field '\(path)': \(ctx.debugDescription)",
            )
        }
    }

    private func encode(_ value: some Encodable) throws -> String {
        let data = try Self.encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
