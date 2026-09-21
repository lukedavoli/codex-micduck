import Foundation

@main
struct SpotifyControllerIntegrationRunner {
    static func main() {
        let suiteName = "com.davolisoftware.CodexMicDuck.integration.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("Could not create isolated test preferences\n", stderr)
            exit(1)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = SpotifyController(defaults: defaults)
        controller.onStatusChange = { status in
            print(status.message)
        }

        var outcome: Result<SpotifyTestOutcome, Error>?
        controller.runTest(targetVolume: 30) { result in
            outcome = result
        }

        let deadline = Date().addingTimeInterval(8)
        while outcome == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        guard let outcome else {
            fputs("Spotify integration test timed out\n", stderr)
            exit(1)
        }

        switch outcome {
        case .success:
            print("Spotify integration test passed")
        case let .failure(error):
            fputs("Spotify integration test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
