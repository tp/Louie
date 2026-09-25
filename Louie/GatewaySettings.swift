//
//  GatewaySettings.swift
//  Louie
//
//  Where the CI gateway lives on the home network. The address is stored
//  locally in UserDefaults — nothing leaves the device. The gateway machine
//  should keep a fixed IP (static lease / DHCP reservation in the router),
//  since the app reconnects to the stored address.
//

import Foundation
import Linn
import Observation

@MainActor
@Observable
final class GatewaySettings {
    private static let hostKey = "gateway.host"
    private static let portKey = "gateway.port"

    var host: String {
        didSet {
            UserDefaults.standard.set(host, forKey: Self.hostKey)
        }
    }

    var port: Int {
        didSet {
            UserDefaults.standard.set(port, forKey: Self.portKey)
        }
    }

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
        let storedPort = UserDefaults.standard.integer(forKey: Self.portKey)
        port = storedPort == 0 ? 8088 : storedPort
    }

    /// The stored address wins; the developer `.env` fallback
    /// (`LINN_CI_GATEWAY_WS_URL`) keeps working when nothing is stored.
    var configuration: Linn.Configuration? {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if !trimmedHost.isEmpty,
           let url = URL(string: "ws://\(trimmedHost):\(port)/ws"),
           url.host() != nil {
            return Linn.Configuration(ciGatewayWebSocketURL: url)
        }
        return try? Linn.Configuration.local()
    }
}
