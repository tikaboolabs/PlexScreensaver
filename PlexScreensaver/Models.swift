import Foundation

// MARK: - Stream Model
struct SSStream: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let user: String
    let player: String
    let quality: String
    let progress: Double
    let bandwidthMbps: Double
    let isTranscoding: Bool
    let thumbPath: String?
    let mediaType: MediaType
    let address: String?

    enum MediaType { case movie, tv, music }

    var remainingFormatted: String {
        ""
    }
}

// MARK: - Server State
struct SSServerState {
    let name: String
    let version: String
    let streams: [SSStream]
    let totalBandwidthMbps: Double
    let isConnected: Bool

    static let empty = SSServerState(
        name: "Plex Server", version: "",
        streams: [], totalBandwidthMbps: 0, isConnected: false
    )
}

// MARK: - API Response Models
struct SSSessionMetadata: Codable {
    let ratingKey: String?
    let sessionKey: String?
    let type: String?
    let title: String?
    let grandparentTitle: String?
    let parentTitle: String?
    let parentIndex: Int?
    let index: Int?
    let year: Int?
    let studio: String?
    let duration: Int?
    let viewOffset: Int?
    let thumb: String?
    let grandparentThumb: String?
    let parentThumb: String?
    let User: SSPlexUser?
    let Player: SSPlexPlayer?
    let Media: [SSPlexMedia]?
    let Session: SSPlexSession?
    let TranscodeSession: SSPlexTranscode?
    let Director: [SSPlexTag]?
}

struct SSPlexUser: Codable { let title: String? }
struct SSPlexPlayer: Codable { let title: String?; let product: String?; let device: String?; let state: String?; let local: Bool?; let address: String? }
struct SSPlexMedia: Codable { let videoResolution: String?; let videoProfile: String?; let audioCodec: String? }
struct SSPlexSession: Codable { let bandwidth: Int? }
struct SSPlexTranscode: Codable { let key: String? }
struct SSPlexTag: Codable { let tag: String? }
