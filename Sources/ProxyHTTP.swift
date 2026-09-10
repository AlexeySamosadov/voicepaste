import Foundation

/// HTTP client with proxy fallback for geo-blocked APIs (OpenAI 403).
///
/// Priority (auto mode):
/// 1. VK TURN proxy tunnel (`utun8` from `vk-turn-vpn`) — system routing, no explicit proxy
/// 2. Local SOCKS/HTTP proxies (V2BOX, VLESS/xray on 127.0.0.1)
/// 3. Direct (last resort)
enum ProxyHTTP {
    static let vkTurnInterface = "utun8"

    /// Default local proxy ports (V2BOX / xray / v2rayN-style).
    static let defaultProxyURLs: [URL] = [
        "socks5://127.0.0.1:10808",
        "http://127.0.0.1:10808",
        "socks5://127.0.0.1:7890",
        "http://127.0.0.1:7890",
        "socks5://127.0.0.1:1080",
        "http://127.0.0.1:10809",
    ].compactMap { URL(string: $0) }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let mode = Config.load().proxyMode
        if mode == "off" {
            return try await URLSession.shared.data(for: request)
        }

        var errors: [String] = []

        if mode == "auto", isVkTurnTunnelUp() {
            do {
                let (data, resp) = try await URLSession.shared.data(for: request)
                if let http = resp as? HTTPURLResponse, http.statusCode != 403 {
                    return (data, resp)
                }
                if let http = resp as? HTTPURLResponse, http.statusCode == 403 {
                    errors.append("vk-turn: HTTP 403")
                } else {
                    return (data, resp)
                }
            } catch {
                errors.append("vk-turn: \(error.localizedDescription)")
            }
        }

        for proxy in proxyCandidates() {
            do {
                let session = session(via: proxy)
                let (data, resp) = try await session.data(for: request)
                if let http = resp as? HTTPURLResponse, http.statusCode == 403 {
                    errors.append("\(proxy.host ?? "?"):\(proxy.port ?? 0) HTTP 403")
                    continue
                }
                print("[VoicePaste] API via proxy \(proxy.scheme ?? "")://\(proxy.host ?? ""):\(proxy.port ?? 0)")
                return (data, resp)
            } catch {
                errors.append("\(proxy.host ?? "?"):\(proxy.port ?? 0) \(error.localizedDescription)")
            }
        }

        if mode == "auto" {
            return try await URLSession.shared.data(for: request)
        }

        throw ProviderError.http(
            status: 0,
            body: "All proxies failed: \(errors.joined(separator: "; "))"
        )
    }

    private static func proxyCandidates() -> [URL] {
        let cfg = Config.load()
        if cfg.proxyMode == "manual", !cfg.proxyURLs.isEmpty {
            return cfg.proxyURLs.compactMap { URL(string: $0) }
        }
        return defaultProxyURLs
    }

    static func isVkTurnTunnelUp() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr?.pointee {
            let name = String(cString: ifa.ifa_name)
            if name == vkTurnInterface,
               let addr = ifa.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                return true
            }
            ptr = ifa.ifa_next
        }
        return false
    }

    private static func session(via proxy: URL) -> URLSession {
        let host = proxy.host ?? "127.0.0.1"
        let port = proxy.port ?? (proxy.scheme?.hasPrefix("http") == true ? 8080 : 1080)
        var dict: [AnyHashable: Any] = [:]

        switch proxy.scheme?.lowercased() {
        case "socks", "socks5", "socks5h":
            dict[kCFNetworkProxiesSOCKSEnable as String] = true
            dict[kCFNetworkProxiesSOCKSProxy as String] = host
            dict[kCFNetworkProxiesSOCKSPort as String] = port
        default:
            dict[kCFNetworkProxiesHTTPEnable as String] = true
            dict[kCFNetworkProxiesHTTPProxy as String] = host
            dict[kCFNetworkProxiesHTTPPort as String] = port
            dict[kCFNetworkProxiesHTTPSEnable as String] = true
            dict[kCFNetworkProxiesHTTPSProxy as String] = host
            dict[kCFNetworkProxiesHTTPSPort as String] = port
        }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = dict
        config.timeoutIntervalForRequest = 90
        return URLSession(configuration: config)
    }
}
