import CoreMedia

struct PauseTimeline {
    private(set) var isPaused = false
    private(set) var pausedTotal = CMTime.zero
    private var pauseStartedAt: CMTime?
    private var resumedAt = CMTime.zero

    mutating func pause(at time: CMTime) {
        guard !isPaused else { return }
        isPaused = true
        pauseStartedAt = time
    }

    mutating func resume(at time: CMTime) {
        guard isPaused else { return }
        if let pauseStartedAt {
            pausedTotal = pausedTotal + (time - pauseStartedAt)
        }
        pauseStartedAt = nil
        resumedAt = time
        isPaused = false
    }

    func outputTime(for hostTime: CMTime) -> CMTime? {
        guard !isPaused, hostTime >= resumedAt else { return nil }
        return hostTime - pausedTotal
    }

    func stopTime(now: CMTime) -> CMTime {
        (pauseStartedAt ?? now) - pausedTotal
    }
}
