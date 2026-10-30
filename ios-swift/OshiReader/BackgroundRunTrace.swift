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
    // The phase between `startPhase` and its `record`, so a run iOS expires
    // mid-phase still reports where the time went.
    private static var openPhase: (name: String, since: Date)?

    static func begin() {
        startedAt = Date()
        phases = [:]
        counts = [:]
        openPhase = nil
    }

    /// Marks `phase` as in progress and returns its start, for `record`.
    static func startPhase(_ phase: String) -> Date {
        let now = Date()
        if startedAt != nil { openPhase = (phase, now) }
        return now
    }

    /// Seconds since `since`, recorded under `phase` (summed if repeated).
    static func record(_ phase: String, since: Date) {
        guard startedAt != nil else { return }
        phases[phase, default: 0] += Date().timeIntervalSince(since)
        if openPhase?.name == phase { openPhase = nil }
    }

    static func count(_ name: String, _ value: Int) {
        guard startedAt != nil else { return }
        counts[name] = value
    }

    static func finish(outcome: String) {
        guard let startedAt else { return }
        let total = Date().timeIntervalSince(startedAt)
        var interruptedPhase: String?
        if let openPhase {
            phases[openPhase.name, default: 0] += Date().timeIntervalSince(openPhase.since)
            interruptedPhase = openPhase.name
            self.openPhase = nil
        }
        var report: [String: Any] = [
            "started_at": startedAt.timeIntervalSince1970,
            "total_seconds": total,
            "outcome": outcome,
            "phases": phases,
            "counts": counts,
        ]
        if let interruptedPhase { report["interrupted_phase"] = interruptedPhase }
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
