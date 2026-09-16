import Foundation

enum ResourcePlaybackVerification: Equatable {
    case notChecked
    case verified(flag: String, episode: String)
    case needsPlayback(String)
    case failed(String)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    var wasChecked: Bool { self != .notChecked }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
