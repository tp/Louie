//
//  PlayerState.swift
//  Louie
//
//  Created by Timm Preetz on 12.05.26.
//

import SwiftUI

@Observable
class PlayerState {
    static let songs = [
        "Chainsmoking",
        "Love Ain’t Enough",
        "Mexico",
        "Prosecco",
        "Kumbaya feat. Bibi Bourelly",
    ]

    var currentSong: Song?

    var playState: PlayState?

    var hasPrevious: Bool = false
    var hasNext: Bool = false

    func previous() {
        if let song = currentSong {
            if let index = PlayerState.songs.firstIndex(of: song.title), index - 1 > 0 {
                currentSong = Song(title: PlayerState.songs[index - 1], artist: "Jacob Banks", artwork: song.artwork)
                hasNext = true
                hasPrevious = index > 2
            }
        }
    }

    func next() {
        if let song = currentSong {
            if let index = PlayerState.songs.firstIndex(of: song.title), PlayerState.songs.count > index + 1 {
                currentSong = Song(title: PlayerState.songs[index + 1], artist: index == 3 ? "\(song.artist) feat. Bibi Bourelly" : song.artist, artwork: song.artwork)
                hasNext = PlayerState.songs.count > index + 2
                hasPrevious = true
            }
        }
    }

    func playPause() {
        if playState == .playing {
            playState = .paused
        } else if playState == .paused {
            playState = .playing
        }
    }
}

struct Song {
    let title: String
    let artist: String
    let artwork: URL?
}

enum PlayState {
    case playing
    case paused
    case loading
}
