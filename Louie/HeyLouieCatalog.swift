//
//  HeyLouieCatalog.swift
//  Louie
//
//  iPad-only music catalog the Hey-Louie agent searches against. The id
//  format `$id:<type>:<slug>` is opaque to the model; play_music validates
//  ids by lookup in `byId`. Tokens drive naive substring matching so the
//  demo behaves identically to the backend reference impl.
//

import Foundation

enum HeyLouieCatalog {
    struct Entry: Sendable {
        let id: String
        let type: String  // "artist" | "album" | "genre" | "playlist" | "track"
        let title: String
        let tokens: [String]
    }

    static let entries: [Entry] = [
        .init(id: "$id:genre:jazz", type: "genre", title: "Jazz", tokens: ["jazz"]),
        .init(id: "$id:genre:classical", type: "genre", title: "Classical", tokens: ["classical"]),
        .init(id: "$id:genre:rock", type: "genre", title: "Rock", tokens: ["rock"]),
        .init(id: "$id:genre:ambient", type: "genre", title: "Ambient", tokens: ["ambient"]),
        .init(id: "$id:song:thriller", type: "track", title: "Thriller", tokens: ["thriller"]),
        .init(id: "$id:album:thriller", type: "album", title: "Thriller", tokens: ["thriller"]),
        .init(id: "$id:artist:queen", type: "artist", title: "Queen", tokens: ["queen"]),
        .init(id: "$id:track:bohemian-rhapsody", type: "track", title: "Bohemian Rhapsody", tokens: ["bohemian"]),
        .init(id: "$id:artist:miles-davis", type: "artist", title: "Miles Davis", tokens: ["miles"]),
    ]

    static let byId: [String: Entry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    /// Lowercase substring match against tokens. Optional type filter.
    static func search(query: String, type: String? = nil) -> [Entry] {
        let q = query.lowercased()
        return entries.filter { entry in
            (type == nil || entry.type == type) && entry.tokens.contains { q.contains($0) }
        }
    }
}
