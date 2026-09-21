import Foundation

enum VolumePolicy {
    enum RestoreDecision: Equatable {
        case restore(Int)
        case preserveManualChange
    }

    /// Returns nil when ducking would leave the volume unchanged or raise it.
    static func duckedVolume(original: Int, configuredTarget: Int) -> Int? {
        let safeOriginal = max(0, min(100, original))
        let safeTarget = max(0, min(100, configuredTarget))
        let applied = min(safeOriginal, safeTarget)
        return applied < safeOriginal ? applied : nil
    }

    static func restoreDecision(
        original: Int,
        applied: Int,
        current: Int,
        force: Bool
    ) -> RestoreDecision {
        if force || current == applied {
            return .restore(max(0, min(100, original)))
        }
        return .preserveManualChange
    }
}
