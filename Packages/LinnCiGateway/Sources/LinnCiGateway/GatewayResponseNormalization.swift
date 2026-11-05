import Foundation

/// The gateway sometimes sends a single artist as a string. Its generated
/// OpenAPI model correctly represents the normalized array shape.
enum GatewayResponseNormalization {
    static func mediaBrowse(_ data: Data) throws -> Data {
        guard var response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var payload = response["data"] as? [String: Any],
              var children = payload["children"] as? [[String: Any]]
        else {
            return data
        }

        for index in children.indices {
            if let artist = children[index]["artist"] as? String {
                children[index]["artist"] = [artist]
            }
        }
        payload["children"] = children
        response["data"] = payload
        return try JSONSerialization.data(withJSONObject: response)
    }
}
