import Foundation

final class PlexFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        self.session = URLSession(configuration: config, delegate: SSLDelegate.shared, delegateQueue: nil)
    }

    func fetchState(serverUrl: String, token: String) async -> SSServerState {
        guard !token.isEmpty, !serverUrl.isEmpty else { return .empty }
        let url = normalizeUrl(serverUrl)

        async let sessions = fetchSessions(url: url, token: token)
        async let identity = fetchIdentity(url: url, token: token)

        let streams = await sessions
        let (name, version) = await identity
        let totalBw = streams.reduce(0.0) { $0 + $1.bandwidthMbps }

        return SSServerState(
            name: name,
            version: version,
            streams: streams,
            totalBandwidthMbps: totalBw,
            isConnected: name != "Plex Server" || !streams.isEmpty
        )
    }

    // MARK: - Poster Image
    func fetchPoster(serverUrl: String, token: String, thumbPath: String) async -> Data? {
        let url = normalizeUrl(serverUrl)
        let posterUrl = "\(url)/photo/:/transcode?width=600&height=900&minSize=1&upscale=1&url=\(thumbPath)&X-Plex-Token=\(token)"
        guard let requestUrl = URL(string: posterUrl) else { return nil }
        do {
            let (data, _) = try await session.data(from: requestUrl)
            return data
        } catch { return nil }
    }

    // MARK: - Sessions
    private func fetchSessions(url: String, token: String) async -> [SSStream] {
        guard let data = await fetch(url: url, path: "/status/sessions", token: token) else { return [] }
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let mc = json?["MediaContainer"] as? [String: Any]
            let arr = mc?["Metadata"] as? [[String: Any]] ?? []
            let reencoded = try JSONSerialization.data(withJSONObject: arr)
            let metadata = try JSONDecoder().decode([SSSessionMetadata].self, from: reencoded)

            return metadata.map { m in
                let quality = formatQuality(m)
                let bwKbps = m.Session?.bandwidth ?? 0

                let mediaType: SSStream.MediaType
                switch m.type {
                case "episode": mediaType = .tv
                case "track":   mediaType = .music
                default:        mediaType = .movie
                }

                let subtitle: String
                if m.grandparentTitle != nil {
                    let s = m.parentIndex.map { "S\($0)" } ?? ""
                    let e = m.index.map { "E\($0)" } ?? ""
                    subtitle = "\(s)\(e) - \(m.title ?? "")"
                } else if let year = m.year {
                    subtitle = "\(year)"
                } else {
                    subtitle = m.parentTitle ?? ""
                }

                let thumbPath: String?
                switch m.type {
                case "episode": thumbPath = m.grandparentThumb ?? m.parentThumb ?? m.thumb
                case "track":   thumbPath = m.parentThumb ?? m.thumb
                default:        thumbPath = m.thumb
                }

                let progress: Double
                if let vo = m.viewOffset, let dur = m.duration, dur > 0 {
                    progress = Double(vo) / Double(dur)
                } else { progress = 0 }

                return SSStream(
                    id: m.sessionKey ?? m.ratingKey ?? UUID().uuidString,
                    title: m.grandparentTitle ?? m.title ?? "Unknown",
                    subtitle: subtitle,
                    user: m.User?.title ?? "Unknown",
                    player: m.Player?.product ?? m.Player?.title ?? "",
                    quality: quality,
                    progress: progress,
                    bandwidthMbps: Double(bwKbps) / 1000.0,
                    isTranscoding: m.TranscodeSession != nil,
                    thumbPath: thumbPath,
                    mediaType: mediaType,
                    address: m.Player?.address
                )
            }
        } catch { return [] }
    }

    // MARK: - Identity
    private func fetchIdentity(url: String, token: String) async -> (String, String) {
        guard let data = await fetch(url: url, path: "/", token: token) else { return ("Plex Server", "") }
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let mc = json?["MediaContainer"] as? [String: Any]
            return (mc?["friendlyName"] as? String ?? "Plex Server", mc?["version"] as? String ?? "")
        } catch { return ("Plex Server", "") }
    }

    // MARK: - HTTP
    private func fetch(url: String, path: String, token: String) async -> Data? {
        guard var components = URLComponents(string: url + path) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "X-Plex-Token", value: token))
        components.queryItems = items
        guard let reqUrl = components.url else { return nil }

        var req = URLRequest(url: reqUrl)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await session.data(for: req)
            return data
        } catch { return nil }
    }

    private func formatQuality(_ m: SSSessionMetadata) -> String {
        guard let media = m.Media?.first else { return "Direct" }
        var parts: [String] = []
        if let res = media.videoResolution {
            parts.append(res == "4k" || res == "2160" ? "4K" : "\(res)p")
        }
        if let p = media.videoProfile, p.lowercased().contains("hdr") { parts.append("HDR") }
        return parts.isEmpty ? "Direct" : parts.joined(separator: " / ")
    }

    // MARK: - GeoIP Lookup (ipwho.is - free, HTTPS, no key)
    func lookupGeo(ip: String) async -> String? {
        // Skip private/local IPs
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") ||
           ip == "127.0.0.1" || ip == "::1" {
            return "Local Network"
        }
        guard let url = URL(string: "https://ipwho.is/\(ip)?fields=success,city,region") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard json?["success"] as? Bool == true else { return nil }
            let city = json?["city"] as? String
            let region = json?["region"] as? String
            if let city, let region { return "\(city), \(region)" }
            return city ?? region
        } catch {
            return nil
        }
    }

    private func normalizeUrl(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}

// MARK: - SSL Delegate
private class SSLDelegate: NSObject, URLSessionDelegate {
    static let shared = SSLDelegate()
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
