import Foundation

/// Invalidates queued work as soon as microphone state changes, including during debounce.
final class MicrophoneOperationGate {
    struct Snapshot {
        let generation: UInt64
        let isActive: Bool
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var isActive = false

    @discardableResult
    func update(_ active: Bool) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        isActive = active
        return Snapshot(generation: generation, isActive: active)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(generation: generation, isActive: isActive)
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == snapshot.generation && isActive == snapshot.isActive
    }
}
