//
//  AppNavigation.swift
//  Louie
//
//  Created by Timm Preetz on 15.05.26.
//

import Foundation
import Linn

enum AppSection: Hashable, Identifiable {
    case home
    case library
    case queue
    #if DEBUG
        case debug
    #endif

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library:
            "Library"
        case .queue:
            "Queue"
        #if DEBUG
            case .debug:
                "Hey-Louie state"
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            "house"
        case .library:
            "music.note.list"
        case .queue:
            "text.line.first.and.arrowtriangle.forward"
        #if DEBUG
            case .debug:
                "ladybug"
        #endif
        }
    }
}

/// Shared route type for the split-view detail stack.
/// Keep section-specific cases nested under this enum so all section paths have
/// the same element type.
enum AppDetailRoute: Hashable {
    case home(HomeRoute)
    case library(LibraryRoute)
    case queue(QueueRoute)
}

enum HomeRoute: Hashable {}

enum LibraryRoute: Hashable {
    case item(LibraryItemRoute)
}

enum QueueRoute: Hashable {}

struct LibraryItemRoute: Hashable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var subtitle: String?
    var artworkURL: URL?

    init(_ item: Linn.LibraryItem) {
        id = item.id
        kind = item.kind
        title = item.title
        subtitle = item.subtitle
        artworkURL = item.artworkURL
    }

    var item: Linn.LibraryItem {
        Linn.LibraryItem(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL,
        )
    }
}
