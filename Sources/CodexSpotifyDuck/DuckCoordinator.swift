import Foundation

final class DuckCoordinator {
    private let spotify: SpotifyController
    private let targetVolume: () -> Int

    private var hasReceivedInitialState = false
    private var restoreWorkItem: DispatchWorkItem?

    private(set) var isMicrophoneActive = false
    var onImmediateStatus: ((String) -> Void)?

    init(spotify: SpotifyController, targetVolume: @escaping () -> Int) {
        self.spotify = spotify
        self.targetVolume = targetVolume
    }

    func updateMicrophoneActivity(_ active: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))

        let wasInitial = !hasReceivedInitialState
        if hasReceivedInitialState, active == isMicrophoneActive { return }

        hasReceivedInitialState = true
        isMicrophoneActive = active
        spotify.setMicrophoneActivity(active)

        if active {
            restoreWorkItem?.cancel()
            restoreWorkItem = nil
            onImmediateStatus?("Codex microphone active — checking Spotify…")
            spotify.duckForMicrophone(targetVolume: targetVolume())
        } else if wasInitial {
            onImmediateStatus?("Watching Codex microphone")
            spotify.recoverAfterAppOrSpotifyLaunch()
        } else {
            scheduleRestore()
        }
    }

    func spotifyDidLaunch() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isMicrophoneActive {
            spotify.duckForMicrophone(targetVolume: targetVolume())
        } else {
            spotify.recoverAfterAppOrSpotifyLaunch()
        }
    }

    func stopAndRestore() {
        dispatchPrecondition(condition: .onQueue(.main))
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        hasReceivedInitialState = false
        isMicrophoneActive = false
        spotify.setMicrophoneActivity(false)
        spotify.restoreAfterRecording()
    }

    func cancelPendingRestore() {
        dispatchPrecondition(condition: .onQueue(.main))
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
    }

    private func scheduleRestore() {
        restoreWorkItem?.cancel()
        onImmediateStatus?("Codex microphone stopped — restoring Spotify…")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isMicrophoneActive else { return }
            self.spotify.restoreAfterRecording()
        }
        restoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppConstants.restoreDebounce,
            execute: workItem
        )
    }
}
