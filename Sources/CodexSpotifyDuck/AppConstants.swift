import Foundation

enum AppConstants {
    static let bundleIdentifier = "com.davolisoftware.CodexMicDuck"
    static let spotifyBundleIdentifier = "com.spotify.client"
    static let codexBundlePrefix = "com.openai.codex"

    static let duckVolumeOptions = [10, 20, 30, 40, 50]
    static let defaultDuckVolume = 20
    static let restoreDebounce: TimeInterval = 0.35
    static let recoveryTimeToLive: TimeInterval = 12 * 60 * 60
}
