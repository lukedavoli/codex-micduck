import AppKit
import Foundation
import ScriptingBridge

/// Only this adapter sends Apple Events. Tests inject an in-memory client.
protocol SpotifyVolumeClient {
    var runningProcessIdentifier: pid_t? { get }
    func readVolume() throws -> Int
    func setVolume(_ volume: Int) throws
}

final class SpotifyScriptingBridgeClient: SpotifyVolumeClient {
    private static let soundVolumePropertyCode: AEKeyword = 0x70566F6C

    private var runningSpotifyApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: AppConstants.spotifyBundleIdentifier
        ).first { !$0.isTerminated }
    }

    var runningProcessIdentifier: pid_t? {
        runningSpotifyApplication?.processIdentifier
    }

    func readVolume() throws -> Int {
        let (application, errorCapture) = try runningSpotifyBridge()
        let value = application.property(withCode: Self.soundVolumePropertyCode).get()
        try throwIfAutomationFailed(application, errorCapture: errorCapture)
        guard let number = value as? NSNumber else {
            throw SpotifyControlError.invalidVolumeResponse
        }
        let volume = number.intValue
        guard (0...100).contains(volume) else {
            throw SpotifyControlError.invalidVolume(volume)
        }
        return volume
    }

    func setVolume(_ volume: Int) throws {
        guard (0...100).contains(volume) else {
            throw SpotifyControlError.invalidVolume(volume)
        }
        let (application, errorCapture) = try runningSpotifyBridge()
        application.property(withCode: Self.soundVolumePropertyCode).setTo(NSNumber(value: volume))
        try throwIfAutomationFailed(application, errorCapture: errorCapture)
    }

    /// Binds Apple events to Spotify's current PID. Unlike a bundle-ID application target, this
    /// cannot launch Spotify if it quits between our running-app check and the event send.
    private func runningSpotifyBridge() throws -> (SBApplication, ScriptingBridgeErrorCapture) {
        guard let runningApplication = runningSpotifyApplication,
              let application = SBApplication(
                  processIdentifier: runningApplication.processIdentifier
              ),
              application.isRunning
        else {
            throw SpotifyControlError.notRunning
        }

        let errorCapture = ScriptingBridgeErrorCapture()
        application.delegate = errorCapture
        return (application, errorCapture)
    }

    private func throwIfAutomationFailed(
        _ application: SBApplication,
        errorCapture: ScriptingBridgeErrorCapture
    ) throws {
        guard let error = errorCapture.error ?? application.lastError() else { return }
        let nsError = error as NSError
        if nsError.code == -600 {
            throw SpotifyControlError.notRunning
        }
        throw SpotifyControlError.automation(
            code: nsError.code,
            message: nsError.localizedDescription
        )
    }

}

private final class ScriptingBridgeErrorCapture: NSObject, SBApplicationDelegate {
    private(set) var error: Error?

    func eventDidFail(
        _ event: UnsafePointer<AppleEvent>,
        withError error: any Error
    ) -> Any? {
        self.error = error
        return nil
    }
}
