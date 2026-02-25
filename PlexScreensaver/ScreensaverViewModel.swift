import Foundation
import AppKit

@MainActor
final class ScreensaverViewModel {
    var state: SSServerState = .empty
    var posterImages: [String: NSImage] = [:]
    var geoLocations: [String: String] = [:]  // IP → "City, State"

    private let fetcher = PlexFetcher()
    private var pollTimer: Timer?
    private var loadedPaths: Set<String> = []
    private var lookedUpIPs: Set<String> = []

    // Poster display size — no need to cache full 600x900 images
    private let posterDisplayWidth: CGFloat = 160
    private let posterDisplayHeight: CGFloat = 240

    // Max cached posters to prevent unbounded memory growth
    private let maxCachedPosters = 24

    func startPolling() {
        fetchNow()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchNow() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func fetchNow() {
        let serverUrl = PlexScreensaverView.serverUrl
        let token = PlexScreensaverView.token

        Task {
            let newState = await fetcher.fetchState(serverUrl: serverUrl, token: token)
            self.state = newState

            // Evict poster images no longer in active streams (keep cache bounded)
            let activePaths = Set(newState.streams.compactMap(\.thumbPath))
            if posterImages.count > maxCachedPosters {
                let stale = Set(posterImages.keys).subtracting(activePaths)
                for key in stale {
                    posterImages.removeValue(forKey: key)
                    loadedPaths.remove(key)
                }
            }

            for stream in newState.streams {
                if let path = stream.thumbPath, !loadedPaths.contains(path) {
                    loadedPaths.insert(path)
                    Task {
                        if let data = await fetcher.fetchPoster(serverUrl: serverUrl, token: token, thumbPath: path),
                           let image = NSImage(data: data) {
                            // Downsample to display size — saves ~85% RAM per poster
                            self.posterImages[path] = self.downsample(image)
                        }
                    }
                }

                // GeoIP lookup for each unique IP
                if let ip = stream.address, !ip.isEmpty, !lookedUpIPs.contains(ip) {
                    lookedUpIPs.insert(ip)
                    Task {
                        if let location = await fetcher.lookupGeo(ip: ip) {
                            self.geoLocations[ip] = location
                        }
                    }
                }
            }
        }
    }

    /// Downsample a poster image to display size (160x240 @ 2x = 320x480 pixels)
    private func downsample(_ image: NSImage) -> NSImage {
        let targetW = posterDisplayWidth * 2  // 2x for retina
        let targetH = posterDisplayHeight * 2
        let newImage = NSImage(size: NSSize(width: targetW, height: targetH))
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
                   from: .zero, operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
