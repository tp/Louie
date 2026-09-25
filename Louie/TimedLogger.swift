//
//  TimedLogger.swift
//  Louie
//
//  Logs a sequence of named events with absolute wall-clock timestamp,
//  delta since the previous event, and total elapsed since the first
//  event. Used to measure user-perceived latency through multi-step flows
//  (e.g. PTT: touch-down → mic-hot → touch-up → transcript). Reset
//  between sessions. Not thread-safe.
//

import Foundation
import OSLog

@MainActor
final class TimedLogger {
    private let logger: Logger
    private let label: String
    private var firstEventAt: Date?
    private var lastEventAt: Date?

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(label: String, category: String) {
        self.label = label
        logger = Logger(subsystem: "Louie", category: category)
    }

    /// Drop any prior session timing so the next `event(_:)` starts a new
    /// "0ms" baseline.
    func reset() {
        firstEventAt = nil
        lastEventAt = nil
    }

    /// Log `name` with an absolute timestamp and the elapsed time since the
    /// previous event in this session. The first event after `reset()` (or
    /// after init) sets the baseline and prints `(start)`.
    func event(_ name: String, detail: String? = nil) {
        let now = Date()
        let timestamp = Self.formatter.string(from: now)
        let detailSuffix = detail.map { " — \($0)" } ?? ""
        if let first = firstEventAt, let last = lastEventAt {
            let sincePrev = Int((now.timeIntervalSince(last) * 1000).rounded())
            let sinceStart = Int((now.timeIntervalSince(first) * 1000).rounded())
            logger.info(
                "[\(self.label, privacy: .public)] \(name, privacy: .public) @ \(timestamp, privacy: .public) (+\(sincePrev)ms, total \(sinceStart)ms)\(detailSuffix, privacy: .public)",
            )
        } else {
            firstEventAt = now
            lastEventAt = now
            logger.info(
                "[\(self.label, privacy: .public)] \(name, privacy: .public) @ \(timestamp, privacy: .public) (start)\(detailSuffix, privacy: .public)",
            )
            return
        }
        lastEventAt = now
    }
}
