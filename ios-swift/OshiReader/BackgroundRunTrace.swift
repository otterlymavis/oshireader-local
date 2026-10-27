import Foundation

/// Wall-clock breakdown of the most recent `BGAppRefreshTask` run, persisted
/// so a run that overshoots iOS's ~30s grant can be diagnosed afterwards
/// (copy the app's preferences off a dev device, or read the log line).
/// Only the last run is kept; it is diagnostics, never read by app logic.
@MainActor
enum BackgroundRunTrace {
    static let defaultsKey = "background_refresh.last_run_trace"

    private static var startedAt: Date?
    private static var phases: [String: Double] = [:]
    private static var counts: [String: Int] = [:]

    static func begin() {
        startedAt = Date()
        phases = [:]
        counts = [:]
    }

    /// Seconds since `since`, recorded under `phase` (summed if repeated).
    static func record(_ phase: String, since: Date) {
        guard startedAt != nil else { return }
        phases[phase, default: 0] += Date().timeIntervalSince(since)
    }

    static func count(_ name: String, _ value: Int) {
        guard startedAt != nil else { return }
        counts[name] = value
    }

    static func finish(outcome: String) {
        guard let startedAt else { return }
        let total = Date().timeIntervalSince(startedAt)
        let report: [String: Any] = [
            "started_at": startedAt.timeIntervalSince1970,
            "total_seconds": total,
            "outcome": outcome,
            "phases": phases,
            "counts": counts,
        ]
        UserDefaults.standard.set(report, forKey: defaultsKey)
        let phaseSummary = phases.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.1f", $0.value))s" }
            .joined(separator: " ")
        AppLogger.network.notice(
            "Background run \(outcome, privacy: .public) in \(String(format: "%.1f", total), privacy: .public)s: \(phaseSummary, privacy: .public)"
        )
        self.startedAt = nil
    }
}
