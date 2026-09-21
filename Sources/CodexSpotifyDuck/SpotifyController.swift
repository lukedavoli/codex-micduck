import Foundation
import os

struct DuckStatus {
    let message: String
    let isError: Bool
    let hasPendingRestore: Bool
}

enum SpotifyTestOutcome: Equatable {
    case restored(Int)
    case manualVolumePreserved(Int)
    case alreadySilent
    case microphoneActivityChanged

    var message: String {
        switch self {
        case .restored(let volume):
            return "Spotify control worked and restored the previous volume of \(volume)%."
        case .manualVolumePreserved(let volume):
            return "Spotify control worked. Your volume change was preserved at \(volume)%."
        case .alreadySilent:
            return "Spotify is already silent. Its volume is readable; no volume change was needed."
        case .microphoneActivityChanged:
            return "Spotify control worked. The test handed volume control back to automatic ducking when microphone activity changed."
        }
    }
}

final class SpotifyController {
    typealias StatusHandler = (DuckStatus) -> Void

    private enum Keys {
        static let recoveryRecord = "spotifyRecoveryRecord"
    }

    private enum Phase: String, Codable {
        case microphone
        case test
        case restoration
        case unconfirmed
    }

    private struct RecoveryRecord: Codable {
        let originalVolume: Int
        let appliedVolume: Int
        let createdAt: Date
        let phase: Phase
    }

    /// Identifies a recovery record that this process successfully applied to the current
    /// Spotify process. While this ownership is valid, a different volume is a deliberate
    /// user/Spotify change and must not be fought. Ownership is intentionally in-memory: after
    /// either app relaunches, the persisted record is reconciled against Spotify's live state.
    private struct LiveDuckOwnership {
        let recordCreatedAt: Date
        let spotifyProcessIdentifier: pid_t
    }

    private let queue: DispatchQueue
    private let defaults: UserDefaults
    private let client: SpotifyVolumeClient
    private let testDuration: TimeInterval
    private let activity = MicrophoneOperationGate()
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "Spotify")
    private var liveDuckOwnership: LiveDuckOwnership?
    private var testInProgress = false

    var onStatusChange: StatusHandler?

    init(
        defaults: UserDefaults = .standard,
        client: SpotifyVolumeClient = SpotifyScriptingBridgeClient(),
        testDuration: TimeInterval = 1.5,
        queue: DispatchQueue = DispatchQueue(label: "com.davolisoftware.CodexMicDuck.spotify")
    ) {
        self.defaults = defaults
        self.client = client
        self.testDuration = testDuration
        self.queue = queue
    }

    var hasPendingRestore: Bool {
        loadRecord() != nil
    }

    func setMicrophoneActivity(_ active: Bool) {
        activity.update(active)
    }

    func duckForMicrophone(targetVolume: Int) {
        let request = activity.snapshot()
        queue.async { [weak self] in
            guard let self, request.isActive, self.activity.isCurrent(request) else { return }
            self.duckForMicrophoneOnQueue(targetVolume: targetVolume, request: request)
        }
    }

    func restoreAfterRecording() {
        let request = activity.snapshot()
        queue.async { [weak self] in
            guard let self, !request.isActive, self.activity.isCurrent(request) else { return }
            self.restoreOnQueue(request: request, enforceRecoveryTTL: false)
        }
    }

    func recoverAfterAppOrSpotifyLaunch() {
        let request = activity.snapshot()
        queue.async { [weak self] in
            guard let self, !request.isActive, self.activity.isCurrent(request) else { return }
            self.restoreOnQueue(request: request, enforceRecoveryTTL: true)
        }
    }

    func restoreSavedVolumeForcefully(completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.restoreForcefullyOnQueue()
                DispatchQueue.main.async { completion?(.success(())) }
            } catch {
                self.report(error.localizedDescription, isError: true)
                DispatchQueue.main.async { completion?(.failure(error)) }
            }
        }
    }

    func runTest(targetVolume: Int, completion: @escaping (Result<SpotifyTestOutcome, Error>) -> Void) {
        let request = activity.snapshot()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard !request.isActive, self.activity.isCurrent(request) else {
                    throw SpotifyControlError.microphoneActive
                }
                guard !self.testInProgress else { throw SpotifyControlError.testInProgress }
                guard self.loadRecord() == nil else {
                    throw SpotifyControlError.pendingRestore
                }
                guard self.isSpotifyRunning else {
                    throw SpotifyControlError.notRunning
                }

                let original = try self.readVolume()
                // Make the test audible even when Spotify is already below the configured level.
                let testTarget = min(targetVolume, max(0, original / 2))
                guard testTarget != original else {
                    self.report("Spotify is already silent; control is available")
                    DispatchQueue.main.async { completion(.success(.alreadySilent)) }
                    return
                }

                let record = RecoveryRecord(
                    originalVolume: original,
                    appliedVolume: testTarget,
                    createdAt: Date(),
                    phase: .test
                )
                let confirmedRecord = try self.applyAndConfirm(record, request: request)
                self.report(
                    "Test: Spotify \(original)% → \(confirmedRecord.appliedVolume)%"
                )

                self.testInProgress = true
                self.queue.asyncAfter(deadline: .now() + self.testDuration) { [weak self] in
                    guard let self else { return }
                    self.testInProgress = false
                    do {
                        guard self.activity.isCurrent(request) else {
                            DispatchQueue.main.async { completion(.success(.microphoneActivityChanged)) }
                            return
                        }
                        let outcome: SpotifyTestOutcome
                        if let pending = self.loadRecord(), pending.createdAt == confirmedRecord.createdAt {
                            // An explicit restore during the delay may have updated a partial result.
                            outcome = try self.restoreMatchingRecord(pending, request: request)
                        } else {
                            let current = try self.readVolume()
                            outcome = current == original ? .restored(original) : .manualVolumePreserved(current)
                        }
                        self.report(outcome.message)
                        DispatchQueue.main.async { completion(.success(outcome)) }
                    } catch SpotifyControlError.operationSuperseded {
                        DispatchQueue.main.async { completion(.success(.microphoneActivityChanged)) }
                    } catch {
                        self.report(error.localizedDescription, isError: true)
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
            } catch {
                self.report(error.localizedDescription, isError: true)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func prepareForTermination(timeout: TimeInterval = 2.5) {
        let request = activity.update(false)
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.restoreOnQueue(request: request, enforceRecoveryTTL: false)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func duckForMicrophoneOnQueue(targetVolume: Int, request: MicrophoneOperationGate.Snapshot) {
        guard let processIdentifier = client.runningProcessIdentifier else {
            report("Codex microphone active — Spotify is not running")
            return
        }

        do {
            if let pendingRecord = loadRecord() {
                guard pendingRecord.phase != .unconfirmed else {
                    throw SpotifyControlError.unconfirmedVolumeChange(reason: nil)
                }
                let ownsPendingRecord = liveDuckOwnership?.recordCreatedAt
                    == pendingRecord.createdAt
                    && liveDuckOwnership?.spotifyProcessIdentifier
                    == processIdentifier

                if ownsPendingRecord {
                    // A change made after our successful set in this same Spotify process is a
                    // user/Spotify override. Do not read and re-apply here; manual changes win.
                    report("Codex microphone active — Spotify volume already handled")
                    return
                }

                let current = try readVolume()
                try ensureCurrent(request)
                if current == pendingRecord.appliedVolume {
                    var adoptedVolume = current
                    if pendingRecord.phase == .restoration,
                       let applied = VolumePolicy.duckedVolume(original: current, configuredTarget: targetVolume) {
                        let resumed = RecoveryRecord(
                            originalVolume: pendingRecord.originalVolume,
                            appliedVolume: applied,
                            createdAt: pendingRecord.createdAt,
                            phase: .microphone
                        )
                        adoptedVolume = try applyAndConfirm(resumed, request: request).appliedVolume
                    }
                    // The helper or Spotify relaunched, but the previously applied value survived.
                    // Adopt the record for this process without overwriting its original baseline.
                    liveDuckOwnership = LiveDuckOwnership(
                        recordCreatedAt: pendingRecord.createdAt,
                        spotifyProcessIdentifier: processIdentifier
                    )
                    report("Codex microphone active — Spotify remains ducked at \(adoptedVolume)%")
                    return
                }

                // The persisted record does not describe Spotify's live state. This includes a
                // failed prior set and a Spotify/app relaunch at another volume. Treat the live
                // value as the new baseline: it will be restored after recording, preserving any
                // manual choice while still ducking the active microphone session.
                try applyNewMicrophoneDuck(
                    originalVolume: current,
                    targetVolume: targetVolume,
                    spotifyProcessIdentifier: processIdentifier,
                    replacingPendingRecord: true,
                    request: request
                )
                return
            }

            let original = try readVolume()
            try applyNewMicrophoneDuck(
                originalVolume: original,
                targetVolume: targetVolume,
                spotifyProcessIdentifier: processIdentifier,
                replacingPendingRecord: false,
                request: request
            )
        } catch SpotifyControlError.operationSuperseded {
            return
        } catch {
            // If setting volume failed after the record was saved, keep it. Recovery compares the
            // actual current volume before restoring, so a partial Apple Event remains safe.
            report(error.localizedDescription, isError: true)
        }
    }

    private func applyNewMicrophoneDuck(
        originalVolume: Int,
        targetVolume: Int,
        spotifyProcessIdentifier: pid_t,
        replacingPendingRecord: Bool,
        request: MicrophoneOperationGate.Snapshot
    ) throws {
        // Never create a restore record when entry made no change; that prevents a later raise.
        guard let applied = VolumePolicy.duckedVolume(
            original: originalVolume,
            configuredTarget: targetVolume
        ) else {
            if replacingPendingRecord {
                clearRecord()
            }
            report("Codex microphone active — Spotify already at \(originalVolume)%")
            return
        }

        let record = RecoveryRecord(
            originalVolume: originalVolume,
            appliedVolume: applied,
            createdAt: Date(),
            phase: .microphone
        )
        let confirmedRecord = try applyAndConfirm(record, request: request)
        liveDuckOwnership = LiveDuckOwnership(
            recordCreatedAt: confirmedRecord.createdAt,
            spotifyProcessIdentifier: spotifyProcessIdentifier
        )
        report(
            "Codex microphone active — Spotify \(originalVolume)% → "
                + "\(confirmedRecord.appliedVolume)%"
        )
    }

    /// Persists the baseline before changing Spotify, then replaces the requested applied value
    /// with Spotify's actual post-set value. Spotify can quantize a requested integer by a point;
    /// recovery must compare against what Spotify retained, not what we asked it to retain.
    private func applyAndConfirm(_ record: RecoveryRecord, request: MicrophoneOperationGate.Snapshot) throws -> RecoveryRecord {
        try ensureCurrent(request)
        save(RecoveryRecord(
            originalVolume: record.originalVolume,
            appliedVolume: record.appliedVolume,
            createdAt: record.createdAt,
            phase: .unconfirmed
        ))
        let actualAppliedVolume: Int
        do {
            try setVolume(record.appliedVolume)
            actualAppliedVolume = try readVolume()
        } catch {
            throw SpotifyControlError.unconfirmedVolumeChange(reason: error.localizedDescription)
        }
        try validatePostWriteVolume(actualAppliedVolume, requested: record.appliedVolume)

        let confirmedRecord = RecoveryRecord(
            originalVolume: record.originalVolume,
            appliedVolume: actualAppliedVolume,
            createdAt: record.createdAt,
            phase: record.phase
        )
        save(confirmedRecord)
        return confirmedRecord
    }

    private func restoreOnQueue(request: MicrophoneOperationGate.Snapshot, enforceRecoveryTTL: Bool) {
        guard let record = loadRecord() else {
            report("Watching Codex microphone")
            return
        }
        // A matching saved volume remains recoverable even after a long Spotify absence.
        guard isSpotifyRunning else {
            report("Spotify closed — saved volume will be checked when it returns")
            return
        }
        do {
            let outcome = try restoreMatchingRecord(record, request: request)
            switch outcome {
            case .restored:
                let expired = enforceRecoveryTTL
                    && Date().timeIntervalSince(record.createdAt) > AppConstants.recoveryTimeToLive
                report(expired ? "Spotify recovered to \(record.originalVolume)%" : "Watching Codex microphone")
            case .manualVolumePreserved(let volume):
                report("Spotify volume changed manually — left at \(volume)%")
            default:
                break
            }
        } catch SpotifyControlError.operationSuperseded {
            return
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    private func restoreForcefullyOnQueue() throws {
        guard let record = loadRecord() else { throw SpotifyControlError.noSavedVolume }
        guard isSpotifyRunning else { throw SpotifyControlError.notRunning }
        try restorePrecisely(record, request: nil)
        clearRecord()
        report("Spotify restored to \(record.originalVolume)%")
    }

    /// A manual change wins. Return what actually happened so a test never claims an unperformed restore.
    private func restoreMatchingRecord(
        _ record: RecoveryRecord,
        request: MicrophoneOperationGate.Snapshot
    ) throws -> SpotifyTestOutcome {
        try ensureCurrent(request)
        guard record.phase != .unconfirmed else {
            throw SpotifyControlError.unconfirmedVolumeChange(reason: nil)
        }
        guard isSpotifyRunning else { throw SpotifyControlError.notRunning }
        let current = try readVolume()
        try ensureCurrent(request)
        switch VolumePolicy.restoreDecision(
            original: record.originalVolume,
            applied: record.appliedVolume,
            current: current,
            force: false
        ) {
        case .preserveManualChange:
            clearRecord()
            return .manualVolumePreserved(current)
        case .restore:
            let outcome: SpotifyTestOutcome
            if current != record.originalVolume {
                outcome = try restorePrecisely(record, request: request)
            } else {
                outcome = .restored(record.originalVolume)
            }
            clearRecord()
            return outcome
        }
    }

    /// Persist each confirmed intermediate volume, so an unsuccessful correction remains recoverable.
    @discardableResult
    private func restorePrecisely(
        _ record: RecoveryRecord,
        request: MicrophoneOperationGate.Snapshot?
    ) throws -> SpotifyTestOutcome {
        let desired = max(0, min(100, record.originalVolume))
        var requested = desired
        var actual = try readVolume()
        if let request {
            try ensureCurrent(request)
            // The second Apple Event read can observe a user change made after the initial
            // match. Only an explicit force restore may override that new value.
            if actual != record.appliedVolume, actual != desired {
                return .manualVolumePreserved(actual)
            }
        }
        if actual == desired { return .restored(desired) }

        for _ in 0..<4 {
            if let request { try ensureCurrent(request) }
            // A write can take effect even if its Apple Event or the confirming read fails.
            // Persist that uncertainty first; a later mismatch is not proof of a manual change.
            save(RecoveryRecord(
                originalVolume: record.originalVolume,
                appliedVolume: actual,
                createdAt: record.createdAt,
                phase: .unconfirmed
            ))
            do {
                try setVolume(requested)
                actual = try readVolume()
            } catch {
                throw SpotifyControlError.unconfirmedVolumeChange(reason: error.localizedDescription)
            }
            if actual == desired { return .restored(desired) }
            try validatePostWriteVolume(actual, requested: requested)
            save(RecoveryRecord(
                originalVolume: record.originalVolume,
                appliedVolume: actual,
                createdAt: record.createdAt,
                phase: .restoration
            ))
            let corrected = max(0, min(100, requested + (desired - actual)))
            guard corrected != requested else { break }
            requested = corrected
        }
        throw SpotifyControlError.restoreMismatch(expected: desired, actual: actual)
    }

    private func validatePostWriteVolume(_ actual: Int, requested: Int) throws {
        // Spotify can quantize by one point. A larger difference may be a new manual or
        // remote change: retain the unconfirmed record instead of claiming or correcting it.
        guard abs(actual - requested) <= 1 else {
            throw SpotifyControlError.unconfirmedVolumeChange(
                reason: "Spotify reported an unexpected volume after the change."
            )
        }
    }

    private func ensureCurrent(_ request: MicrophoneOperationGate.Snapshot) throws {
        guard activity.isCurrent(request) else { throw SpotifyControlError.operationSuperseded }
    }

    private var isSpotifyRunning: Bool { client.runningProcessIdentifier != nil }

    private func readVolume() throws -> Int { try client.readVolume() }
    private func setVolume(_ volume: Int) throws { try client.setVolume(volume) }

    private func save(_ record: RecoveryRecord) {
        liveDuckOwnership = nil
        do {
            let data = try JSONEncoder().encode(record)
            defaults.set(data, forKey: Keys.recoveryRecord)
            defaults.synchronize()
            notifyPendingStateChanged()
        } catch {
            logger.error("Unable to persist recovery record: \(error.localizedDescription)")
        }
    }

    private func loadRecord() -> RecoveryRecord? {
        guard let data = defaults.data(forKey: Keys.recoveryRecord) else { return nil }
        return try? JSONDecoder().decode(RecoveryRecord.self, from: data)
    }

    private func clearRecord() {
        liveDuckOwnership = nil
        defaults.removeObject(forKey: Keys.recoveryRecord)
        defaults.synchronize()
        notifyPendingStateChanged()
    }

    private func report(_ message: String, isError: Bool = false) {
        if isError {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.info("\(message, privacy: .public)")
        }
        let status = DuckStatus(
            message: message,
            isError: isError,
            hasPendingRestore: loadRecord() != nil
        )
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(status)
        }
    }

    private func notifyPendingStateChanged() {
        let pending = loadRecord() != nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStatusChange?(
                DuckStatus(
                    message: pending ? "Spotify restore is saved" : "Watching Codex microphone",
                    isError: false,
                    hasPendingRestore: pending
                )
            )
        }
    }
}

enum SpotifyControlError: LocalizedError {
    case notRunning
    case invalidVolume(Int)
    case invalidVolumeResponse
    case automation(code: Int, message: String)
    case pendingRestore
    case noSavedVolume
    case restoreMismatch(expected: Int, actual: Int)
    case operationSuperseded
    case microphoneActive
    case testInProgress
    case unconfirmedVolumeChange(reason: String?)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Spotify is not running"
        case let .invalidVolume(value):
            return "Spotify returned an invalid volume: \(value)"
        case .invalidVolumeResponse:
            return "Spotify did not return a readable volume"
        case let .automation(code, message):
            if code == -1743 {
                return "Spotify control was denied. Allow Codex MicDuck in System Settings → Privacy & Security → Automation."
            }
            return "Spotify control failed (\(code)): \(message)"
        case .pendingRestore:
            return "Restore the saved Spotify volume before running a test"
        case .restoreMismatch(let expected, let actual):
            return "Spotify stayed at \(actual)% instead of \(expected)%. The saved volume is still available to restore."
        case .unconfirmedVolumeChange(let reason):
            let detail = reason.map { "\($0) " } ?? ""
            return detail + "Spotify's last volume change could not be confirmed. The saved volume is still available through Restore Saved Spotify Volume."
        case .operationSuperseded:
            return "Microphone activity changed before Spotify control completed."
        case .microphoneActive:
            return "Finish the current microphone session before testing Spotify control."
        case .testInProgress:
            return "A Spotify control test is already running."
        case .noSavedVolume:
            return "There is no saved Spotify volume to restore"
        }
    }
}
