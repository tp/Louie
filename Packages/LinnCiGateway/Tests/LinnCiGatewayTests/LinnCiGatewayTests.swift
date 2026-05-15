import Foundation
@testable import LinnCiGateway
import Testing

@Test
func decodesServicesStatusWithQobuzService() throws {
    let json = """
    {
      "requestPath": "/V2/services/status",
      "session": "s.01",
      "tag": "services-1",
      "room": "Main Room",
      "data": {
        "id": "Main Room",
        "content_revision": 7,
        "index": 0,
        "count": 2,
        "total": 2,
        "children": [
          { "id": "service-radio", "name": "Radio", "class": "md.service" },
          { "id": "service-qobuz", "name": "Qobuz", "class": "md.service" }
        ]
      }
    }
    """

    let response = try JSONDecoder().decode(V2ServicesStatusResponse.self, from: Data(json.utf8))

    #expect(response.room == "Main Room")
    #expect(response.data?.contentRevision == 7)
    #expect(response.data?.children?.last?.id == "service-qobuz")
    #expect(response.data?.children?.last?.name == "Qobuz")
}

@Test
func decodesMediaBrowseItemsWithFlexibleArtistAndFavouriteState() throws {
    let json = """
    {
      "requestPath": "/V2/media/browse",
      "session": "s.01",
      "tag": "browse-1",
      "data": {
        "id": "service-qobuz",
        "content_revision": 8,
        "index": 0,
        "count": 2,
        "total": 2,
        "children": [
          {
            "id": "album-1",
            "class": "md.album.qobuz",
            "name": "Space 1.8",
            "album": "Space 1.8",
            "artist": "Nala Sinephro",
            "art_uri": "https://static.qobuz.com/cover.jpg",
            "contained_classes": ["md.track.qobuz"],
            "count": 8,
            "isFavourite": false
          },
          {
            "id": "track-1",
            "class": "md.track.qobuz",
            "title": "Track One",
            "artist": ["Artist One", "Artist Two"],
            "duration": 180,
            "disabledActions": ["favourite"],
            "isFavourite": true
          }
        ]
      }
    }
    """

    let response = try JSONDecoder().decode(MediaBrowseResponse.self, from: Data(json.utf8))
    let children = try #require(response.data?.children)

    #expect(response.data?.contentRevision == 8)
    #expect(children[0].artist == ["Nala Sinephro"])
    #expect(children[0].containedClasses == ["md.track.qobuz"])
    #expect(children[0].isFavourite == false)
    #expect(children[1].artist == ["Artist One", "Artist Two"])
    #expect(children[1].disabledActions == ["favourite"])
}

@Test
func encodesMediaSelectAndFavouriteRequests() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let select = V2MediaSelectPostRequest(
        tag: "command-1",
        session: "s.01",
        room: "Main Room",
        mediaId: "album-1",
        queue: "replace"
    )
    let favourite = V2MediaFavouritePostRequest(
        tag: "command-2",
        session: "s.01",
        mediaId: "album-1",
        favourite: true
    )

    let selectJSON = try String(decoding: encoder.encode(select), as: UTF8.self)
    let favouriteJSON = try String(decoding: encoder.encode(favourite), as: UTF8.self)

    #expect(selectJSON.contains("\"media_id\":\"album-1\""))
    #expect(selectJSON.contains("\"queue\":\"replace\""))
    #expect(selectJSON.contains("\"room\":\"Main Room\""))
    #expect(favouriteJSON.contains("\"favourite\":true"))
    #expect(favouriteJSON.contains("\"media_id\":\"album-1\""))
}
