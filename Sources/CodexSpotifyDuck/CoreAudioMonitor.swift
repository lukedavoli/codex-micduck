import CoreAudio
import Foundation
import os

/// Watches Core Audio's public process metadata. It never opens or captures a microphone.
final class CoreAudioMonitor {
    typealias ActivityHandler = (Bool) -> Void

    private let queue = DispatchQueue(label: "com.davolisoftware.CodexMicDuck.core-audio")
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "CoreAudio")
    private let onActivityChange: ActivityHandler
    private let onMonitoringIssue: (String?) -> Void
    private let generationGate = ActivityGenerationGate()

    private var isStarted = false
    private var activeGeneration: UInt64?
    private var lastActivity: Bool?
    private var lastMonitoringIssue: String?
    private var processSnapshotIsReliable = false
    private var targetProcessIDs = Set<AudioObjectID>()
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var fallbackTimer: DispatchSourceTimer?
    private var fallbackTicks = 0

    init(
        onMonitoringIssue: @escaping (String?) -> Void = { _ in },
        onActivityChange: @escaping ActivityHandler
    ) {
        self.onMonitoringIssue = onMonitoringIssue
        self.onActivityChange = onActivityChange
    }

    func start() {
        let generation = generationGate.activate()
        queue.async { [weak self] in
            guard let self,
                  self.generationGate.isCurrent(generation, active: true)
            else { return }

            // Starting an already-running monitor creates a fresh listener generation. This
            // prevents a previously queued callback from being delivered into the new session.
            if self.isStarted {
                self.stopOnQueue()
            }

            self.isStarted = true
            self.activeGeneration = generation
            self.processSnapshotIsReliable = false
            self.installSystemListener(generation: generation)
            self.refreshTargetProcesses(generation: generation)
            self.installFallbackTimer(generation: generation)
            self.evaluateActivity(generation: generation, forceNotification: true)
        }
    }

    func stop() {
        let generation = generationGate.invalidate()
        queue.async { [weak self] in
            guard let self,
                  self.generationGate.isCurrent(generation, active: false)
            else { return }
            self.stopOnQueue()
        }
    }

    func stopSynchronously() {
        let generation = generationGate.invalidate()
        queue.sync {
            guard generationGate.isCurrent(generation, active: false) else { return }
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard isStarted else { return }
        isStarted = false
        activeGeneration = nil

        fallbackTimer?.cancel()
        fallbackTimer = nil

        for (objectID, listener) in processListeners {
            var address = Self.inputActivityAddress
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
        }
        processListeners.removeAll()
        targetProcessIDs.removeAll()
        processSnapshotIsReliable = false

        if let systemListener {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                systemListener
            )
        }
        systemListener = nil
        lastActivity = nil
        lastMonitoringIssue = nil
    }

    private func installSystemListener(generation: UInt64) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isCurrentGeneration(generation) else { return }
            self.refreshTargetProcesses(generation: generation)
            self.evaluateActivity(generation: generation, forceNotification: false)
        }
        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        if status == noErr {
            systemListener = listener
        } else {
            logger.error("Unable to attach process-list listener: \(status)")
        }
    }

    /// A low-frequency poll backs up Core Audio property listeners across OS/audio-server restarts.
    private func installFallbackTimer(generation: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .milliseconds(250),
            leeway: .milliseconds(40)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.isCurrentGeneration(generation) else { return }
            self.fallbackTicks += 1
            if self.fallbackTicks % 4 == 0 {
                self.refreshTargetProcesses(generation: generation)
            }
            self.evaluateActivity(generation: generation, forceNotification: false)
        }
        timer.resume()
        fallbackTimer = timer
    }

    private func refreshTargetProcesses(generation: UInt64) {
        guard isCurrentGeneration(generation) else { return }

        let processObjects: [AudioObjectID]
        do {
            processObjects = try Self.readArray(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList,
                as: AudioObjectID.self
            )
        } catch {
            processSnapshotIsReliable = false
            logger.error("Unable to enumerate audio processes: \(error.localizedDescription)")
            return
        }

        var refreshed = Set<AudioObjectID>()
        var retainedUncertainTarget = false
        var snapshotHadReadFailure = false
        for objectID in processObjects {
            do {
                guard let bundleID = try Self.readString(
                    objectID: objectID,
                    selector: kAudioProcessPropertyBundleID
                ) else {
                    // A process that was previously identified as Codex remains uncertain until
                    // Core Audio can provide a definitive bundle identifier again.
                    if targetProcessIDs.contains(objectID) {
                        refreshed.insert(objectID)
                        retainedUncertainTarget = true
                    }
                    continue
                }

                if bundleID == AppConstants.codexBundlePrefix
                    || bundleID.hasPrefix(AppConstants.codexBundlePrefix + ".")
                {
                    refreshed.insert(objectID)
                }
            } catch {
                // Do not turn a transient property failure into a false microphone-stop event.
                snapshotHadReadFailure = true
                if targetProcessIDs.contains(objectID) {
                    refreshed.insert(objectID)
                    retainedUncertainTarget = true
                }
            }
        }

        let removed = targetProcessIDs.subtracting(refreshed)

        for objectID in removed {
            if let listener = processListeners.removeValue(forKey: objectID) {
                var address = Self.inputActivityAddress
                AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
            }
        }

        targetProcessIDs = refreshed
        processSnapshotIsReliable = !retainedUncertainTarget && !snapshotHadReadFailure

        for objectID in targetProcessIDs where processListeners[objectID] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.isCurrentGeneration(generation) else { return }
                self.evaluateActivity(generation: generation, forceNotification: false)
            }
            var address = Self.inputActivityAddress
            let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener)
            if status == noErr {
                processListeners[objectID] = listener
            } else {
                logger.error("Unable to attach Codex input listener for \(objectID): \(status)")
            }
        }
    }

    private func evaluateActivity(generation: UInt64, forceNotification: Bool) {
        guard isCurrentGeneration(generation) else { return }

        // Aggregate every Codex process. One helper going idle must not restore while another is live.
        var readFailed = false
        for objectID in targetProcessIDs {
            do {
                let value = try Self.readScalar(
                    objectID: objectID,
                    selector: kAudioProcessPropertyIsRunningInput,
                    as: UInt32.self
                )
                if value != 0 {
                    publishMonitoringReliability(processSnapshotIsReliable, generation: generation)
                    publishActivity(true, generation: generation, forceNotification: forceNotification)
                    return
                }
            } catch {
                readFailed = true
            }
        }

        // If no process was definitively active but any read was unavailable, the aggregate state
        // is unknown. Retain the prior state until a complete sample or process-list refresh.
        let reliable = processSnapshotIsReliable && !readFailed
        publishMonitoringReliability(reliable, generation: generation)
        guard reliable else { return }
        publishActivity(false, generation: generation, forceNotification: forceNotification)
    }

    private func publishMonitoringReliability(_ reliable: Bool, generation: UInt64) {
        let issue = reliable ? nil : "Microphone status unavailable — retrying…"
        guard issue != lastMonitoringIssue else { return }
        lastMonitoringIssue = issue
        DispatchQueue.main.async { [generationGate, onMonitoringIssue] in
            generationGate.performIfCurrent(generation) {
                onMonitoringIssue(issue)
            }
        }
    }

    private func publishActivity(
        _ active: Bool,
        generation: UInt64,
        forceNotification: Bool
    ) {
        guard isCurrentGeneration(generation) else { return }
        guard forceNotification || lastActivity != active else { return }
        lastActivity = active
        DispatchQueue.main.async { [generationGate, onActivityChange] in
            generationGate.performIfCurrent(generation) {
                onActivityChange(active)
            }
        }
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        isStarted
            && activeGeneration == generation
            && generationGate.isCurrent(generation, active: true)
    }

    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var inputActivityAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readScalar<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        as type: T.Type
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, value)
        guard status == noErr else { throw CoreAudioError(status: status) }
        guard size == UInt32(MemoryLayout<T>.size) else {
            throw CoreAudioError(status: kAudioHardwareBadPropertySizeError)
        }
        return value.move()
    }

    private static func readArray<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        as type: T.Type
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status) }
        guard size % UInt32(MemoryLayout<T>.stride) == 0 else {
            throw CoreAudioError(status: kAudioHardwareBadPropertySizeError)
        }

        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let values = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { values.deallocate() }

        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, values)
        guard status == noErr else { throw CoreAudioError(status: status) }
        guard size % UInt32(MemoryLayout<T>.stride) == 0,
              Int(size) / MemoryLayout<T>.stride <= count
        else {
            throw CoreAudioError(status: kAudioHardwareBadPropertySizeError)
        }
        let returnedCount = Int(size) / MemoryLayout<T>.stride
        return Array(UnsafeBufferPointer(start: values, count: returnedCount))
    }

    private static func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError(status: status) }
        return value.map { $0.takeRetainedValue() as String }
    }
}

/// Serializes lifecycle transitions with activity delivery across the monitor and main queues.
///
/// The recursive lock makes it safe for the activity handler to synchronously stop the monitor.
/// Holding the lock through delivery gives stop() a clear ordering boundary: after invalidate()
/// returns, no callback from an older generation can begin.
private final class ActivityGenerationGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var isActive = false

    func activate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        isActive = true
        return generation
    }

    @discardableResult
    func invalidate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        isActive = false
        return generation
    }

    func isCurrent(_ expectedGeneration: UInt64, active expectedActivity: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration && isActive == expectedActivity
    }

    func performIfCurrent(_ expectedGeneration: UInt64, _ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expectedGeneration, isActive else { return }
        body()
    }
}

private struct CoreAudioError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Core Audio error \(status)"
    }
}
