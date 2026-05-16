import Foundation

/// A two-slot queue that coalesces rapid playlist-selection taps so the gateway
/// only ever has one selection in flight, plus at most one pending follow-up.
/// On rapid forward-then-back taps, the latest target wins; same-target repeats
/// are dropped. See commit 8b955d8 for the original motivation.
struct PlaylistSelectionJob: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case skip
        case queueItem
    }

    var targetIndex: Int
    var kind: Kind
}

struct PlaylistSelectionQueue: Sendable, Equatable {
    var inFlight: PlaylistSelectionJob?
    var pending: PlaylistSelectionJob?

    mutating func enqueue(_ job: PlaylistSelectionJob) -> PlaylistSelectionJob? {
        guard let inFlight else {
            inFlight = job
            return job
        }

        pending = job.targetIndex == inFlight.targetIndex ? nil : job
        return nil
    }

    mutating func confirm(targetIndex: Int) -> (confirmed: Bool, next: PlaylistSelectionJob?) {
        guard inFlight?.targetIndex == targetIndex else {
            return (false, nil)
        }

        inFlight = nil
        return (true, dequeuePending())
    }

    mutating func fail(targetIndex: Int) -> (failed: Bool, next: PlaylistSelectionJob?) {
        guard inFlight?.targetIndex == targetIndex else {
            return (false, nil)
        }

        inFlight = nil
        return (true, dequeuePending())
    }

    private mutating func dequeuePending() -> PlaylistSelectionJob? {
        guard let pending else {
            return nil
        }

        self.pending = nil
        inFlight = pending
        return pending
    }
}
