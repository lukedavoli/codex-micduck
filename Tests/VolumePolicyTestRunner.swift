import Foundation

@main
struct VolumePolicyTestRunner {
    static func main() {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }

        expect(
            VolumePolicy.duckedVolume(original: 0, configuredTarget: 20) == nil,
            "silent Spotify is not raised"
        )
        expect(
            VolumePolicy.duckedVolume(original: 10, configuredTarget: 20) == nil,
            "already-quiet Spotify is not raised"
        )
        expect(
            VolumePolicy.duckedVolume(original: 20, configuredTarget: 20) == nil,
            "equal volume is unchanged"
        )
        expect(
            VolumePolicy.duckedVolume(original: 45, configuredTarget: 20) == 20,
            "loud Spotify is ducked"
        )
        expect(
            VolumePolicy.duckedVolume(original: 45, configuredTarget: -5) == 0,
            "target is bounded below"
        )
        expect(
            VolumePolicy.duckedVolume(original: 45, configuredTarget: 120) == nil,
            "target is bounded above"
        )
        expect(
            VolumePolicy.restoreDecision(original: 45, applied: 20, current: 20, force: false)
                == .restore(45),
            "matching applied volume restores"
        )
        expect(
            VolumePolicy.restoreDecision(original: 45, applied: 20, current: 26, force: false)
                == .preserveManualChange,
            "manual change wins"
        )
        expect(
            VolumePolicy.restoreDecision(original: 45, applied: 20, current: 26, force: true)
                == .restore(45),
            "explicit force restore wins"
        )

        if failures.isEmpty {
            print("Volume policy tests passed (9 checks)")
            return
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        exit(1)
    }
}
