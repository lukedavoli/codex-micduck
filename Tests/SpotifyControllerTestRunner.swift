import Foundation

/// No live applications or Apple Events: every Spotify operation stays in this fake.
private final class FakeSpotifyClient: SpotifyVolumeClient {
    private let lock = NSLock()
    private var storedVolume: Int
    private var storedWrites: [Int] = []
    private var readBlock: (DispatchSemaphore, DispatchSemaphore)?
    var writtenVolumeOverride: Int?
    var readError: Error?
    var afterNextWrite: (() -> Void)?
    var afterNextRead: (() -> Void)?
    var runningProcessIdentifier: pid_t? = 42

    init(volume: Int = 80) { storedVolume = volume }
    var volume: Int {
        get { lock.lock(); defer { lock.unlock() }; return storedVolume }
        set { lock.lock(); storedVolume = newValue; lock.unlock() }
    }
    var writes: [Int] {
        lock.lock(); defer { lock.unlock() }; return storedWrites
    }
    func blockNextRead() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let pair = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        lock.lock(); readBlock = pair; lock.unlock()
        return pair
    }
    func readVolume() throws -> Int {
        lock.lock(); let block = readBlock; readBlock = nil; lock.unlock()
        if let block {
            block.0.signal()
            precondition(block.1.wait(timeout: .now() + 3) == .success, "Blocked test read timed out")
        }
        if let readError { throw readError }
        lock.lock()
        let sampledVolume = storedVolume
        let callback = afterNextRead
        afterNextRead = nil
        lock.unlock()
        callback?()
        return sampledVolume
    }
    func setVolume(_ volume: Int) throws {
        lock.lock()
        storedWrites.append(volume)
        storedVolume = writtenVolumeOverride ?? volume
        let callback = afterNextWrite
        afterNextWrite = nil
        lock.unlock()
        callback?()
    }
}

private final class Fixture {
    let suite = "com.davolisoftware.CodexMicDuck.offline.\(UUID().uuidString)"
    let defaults: UserDefaults
    let client: FakeSpotifyClient
    let queue = DispatchQueue(label: "CodexMicDuck.offline-tests")
    let controller: SpotifyController
    var statuses: [DuckStatus] = []

    init(volume: Int = 80, testDuration: TimeInterval = 0.06) {
        defaults = UserDefaults(suiteName: suite)!
        client = FakeSpotifyClient(volume: volume)
        controller = SpotifyController(defaults: defaults, client: client, testDuration: testDuration, queue: queue)
        controller.onStatusChange = { [weak self] in self?.statuses.append($0) }
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
    func flush() {
        queue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    func duck() {
        controller.setMicrophoneActivity(true)
        controller.duckForMicrophone(targetVolume: 20)
        flush()
    }
    func restore() {
        controller.setMicrophoneActivity(false)
        controller.restoreAfterRecording()
        flush()
    }
}

@main
private enum SpotifyControllerTests {
    static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(condition(), "Timed out waiting for isolated test")
    }

    static func main() throws {
        do {
            let f = Fixture()
            f.duck()
            precondition(f.client.volume == 20 && f.controller.hasPendingRestore)
            f.restore()
            precondition(f.client.volume == 80 && !f.controller.hasPendingRestore)
        }
        do {
            let f = Fixture()
            f.duck()
            f.client.writtenVolumeOverride = 73
            f.restore()
            precondition(f.client.volume == 73 && f.controller.hasPendingRestore)
            precondition(f.statuses.contains { $0.isError && $0.message.contains("saved volume") })
            // Retry must match the last applied 73, not discard the original 80 as a manual override.
            f.client.writtenVolumeOverride = nil
            f.controller.restoreAfterRecording()
            f.flush()
            precondition(f.client.volume == 80 && !f.controller.hasPendingRestore)
        }
        do {
            let f = Fixture()
            var outcome: Result<SpotifyTestOutcome, Error>?
            f.controller.runTest(targetVolume: 20) { outcome = $0 }
            f.flush()
            f.client.volume = 31
            waitUntil { outcome != nil }
            let result = try outcome!.get()
            precondition(result == .manualVolumePreserved(31))
            precondition(f.client.volume == 31 && !f.controller.hasPendingRestore)
        }
        do {
            let f = Fixture(volume: 0)
            var outcome: Result<SpotifyTestOutcome, Error>?
            f.controller.runTest(targetVolume: 20) { outcome = $0 }
            waitUntil { outcome != nil }
            let result = try outcome!.get()
            precondition(result == .alreadySilent)
            precondition(f.client.writes.isEmpty)
        }
        do {
            let f = Fixture()
            f.duck()
            let block = f.client.blockNextRead()
            f.controller.setMicrophoneActivity(false)
            f.controller.restoreAfterRecording()
            precondition(block.entered.wait(timeout: .now() + 3) == .success)
            f.controller.setMicrophoneActivity(true)
            f.controller.duckForMicrophone(targetVolume: 20)
            block.release.signal()
            f.flush()
            precondition(f.client.writes == [20], "Superseded restore raised Spotify")
            f.restore()
            precondition(f.client.volume == 80)
        }
        do {
            let f = Fixture()
            let block = f.client.blockNextRead()
            f.controller.setMicrophoneActivity(true)
            f.controller.duckForMicrophone(targetVolume: 20)
            precondition(block.entered.wait(timeout: .now() + 3) == .success)
            f.controller.setMicrophoneActivity(false)
            f.controller.restoreAfterRecording()
            block.release.signal()
            f.flush()
            precondition(f.client.writes.isEmpty && !f.controller.hasPendingRestore,
                         "Superseded duck modified Spotify after microphone stopped")
        }
        do {
            let f = Fixture()
            var outcome: Result<SpotifyTestOutcome, Error>?
            f.controller.runTest(targetVolume: 20) { outcome = $0 }
            f.flush()
            f.duck()
            waitUntil { outcome != nil }
            let result = try outcome!.get()
            precondition(result == .microphoneActivityChanged)
            precondition(f.client.volume == 20 && f.client.writes == [20],
                         "Test restored while the microphone was active")
            f.restore()
            precondition(f.client.volume == 80 && !f.controller.hasPendingRestore)
        }
        do {
            let f = Fixture()
            f.client.readError = SpotifyControlError.automation(code: -1743, message: "Denied")
            f.duck()
            precondition(f.client.writes.isEmpty && !f.controller.hasPendingRestore)
            precondition(f.statuses.contains { $0.isError && $0.message.contains("denied") })
        }
        do {
            let f = Fixture()
            f.duck()
            f.client.writtenVolumeOverride = 79
            f.client.afterNextWrite = {
                f.client.writtenVolumeOverride = nil
                f.controller.setMicrophoneActivity(true)
                f.controller.duckForMicrophone(targetVolume: 20)
            }
            f.restore()
            waitUntil { f.client.volume == 20 }
            f.flush()
            precondition(f.client.writes == [20, 80, 20], "Partial restore was not ducked again")
            f.restore()
            precondition(f.client.volume == 80 && !f.controller.hasPendingRestore,
                         "Interrupted partial restore lost the original volume")
        }
        do {
            let f = Fixture(testDuration: 0.15)
            var outcome: Result<SpotifyTestOutcome, Error>?
            f.controller.runTest(targetVolume: 20) { outcome = $0 }
            f.flush()
            f.client.writtenVolumeOverride = 73
            f.controller.restoreSavedVolumeForcefully()
            f.flush()
            precondition(f.controller.hasPendingRestore && f.client.volume == 73)
            f.client.writtenVolumeOverride = nil
            waitUntil { outcome != nil }
            let result = try outcome!.get()
            precondition(result == .restored(80))
            precondition(f.client.volume == 80 && !f.controller.hasPendingRestore,
                         "Test used its stale recovery record after an explicit restore attempt")
        }
        do {
            let f = Fixture()
            f.duck()
            f.client.afterNextRead = { f.client.volume = 31 }
            f.restore()
            precondition(f.client.volume == 31 && f.client.writes == [20],
                         "Automatic restore overwrote a manual change between its two reads")
            precondition(!f.controller.hasPendingRestore)
            precondition(f.statuses.contains { $0.message.contains("left at 31%") })
        }
        do {
            let f = Fixture()
            f.duck()
            f.client.volume = 31
            f.controller.restoreSavedVolumeForcefully()
            f.flush()
            precondition(f.client.volume == 80 && f.client.writes == [20, 80],
                         "Explicit force restore stopped overriding the current volume")
            precondition(!f.controller.hasPendingRestore)
        }
        do {
            let f = Fixture()
            f.duck()
            f.client.writtenVolumeOverride = 79
            f.client.afterNextWrite = { f.client.readError = SpotifyControlError.invalidVolumeResponse }
            f.restore()
            precondition(f.client.volume == 79 && f.controller.hasPendingRestore)
            f.client.readError = nil
            f.client.writtenVolumeOverride = nil
            f.controller.restoreAfterRecording()
            f.flush()
            precondition(f.client.volume == 79 && f.controller.hasPendingRestore,
                         "Unconfirmed partial restore was incorrectly discarded as a manual change")
            f.client.volume = 31
            f.controller.restoreAfterRecording()
            f.flush()
            precondition(f.client.volume == 31 && f.client.writes == [20, 80],
                         "Unconfirmed recovery automatically overwrote a possible manual change")
            precondition(f.statuses.contains { $0.isError && $0.message.contains("Restore Saved Spotify Volume") })
            f.controller.restoreSavedVolumeForcefully()
            f.flush()
            precondition(f.client.volume == 80 && !f.controller.hasPendingRestore,
                         "Explicit restore lost the original volume after an unconfirmed write")
        }
        do {
            let f = Fixture()
            f.client.writtenVolumeOverride = 19
            f.client.afterNextWrite = { f.client.readError = SpotifyControlError.invalidVolumeResponse }
            f.duck()
            precondition(f.client.volume == 19 && f.controller.hasPendingRestore)
            f.client.readError = nil
            f.client.writtenVolumeOverride = nil
            f.restore()
            precondition(f.client.volume == 19 && f.controller.hasPendingRestore,
                         "Unconfirmed initial duck lost its recovery record")
            f.controller.restoreSavedVolumeForcefully()
            f.flush()
            precondition(f.client.volume == 80 && !f.controller.hasPendingRestore)
        }
        print("PASS: 14 isolated Spotify recovery and transition scenarios (no Apple Events)")
    }
}
