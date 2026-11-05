import Foundation

public extension Linn {
    struct Configuration: Sendable {
        public var serverURL: URL

        public init(serverURL: URL) {
            self.serverURL = serverURL
        }

        public static func local(
            fileURL: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ) throws -> Self {
            let values = try DotEnv.load(fileURL: fileURL, currentDirectoryURL: currentDirectoryURL)
            let urlString = environment["LOUIE_SERVER_URL"] ?? values["LOUIE_SERVER_URL"]
                ?? "http://louie-pi.local:50051"
            guard let url = URL(string: urlString), url.scheme == "http",
                  let host = url.host(), !host.isEmpty,
                  let port = url.port, (1 ... 65_535).contains(port) else {
                throw ConfigurationError.invalidURL(urlString)
            }

            return Self(serverURL: url)
        }
    }

    enum ConfigurationError: Error, Sendable {
        case missingValue(String)
        case invalidURL(String)
    }
}

private enum DotEnv {
    static func load(fileURL: URL?, currentDirectoryURL: URL) throws -> [String: String] {
        let url = try fileURL ?? discover(from: currentDirectoryURL)
        guard let url else {
            return [:]
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents)
    }

    private static func discover(from currentDirectoryURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.url(forResource: ".env", withExtension: nil),
            Bundle.main.bundleURL.appendingPathComponent(".env"),
            currentDirectoryURL.appendingPathComponent(".env"),
            currentDirectoryURL.appendingPathComponent("Louie/.env"),
            currentDirectoryURL.appendingPathComponent("Packages/Linn/.env"),
        ].compactMap(\.self)

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func parse(_ contents: String) -> [String: String] {
        contents
            .split(whereSeparator: \.isNewline)
            .reduce(into: [:]) { values, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    return
                }
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return
                }

                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                values[key] = unquote(value)
            }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
