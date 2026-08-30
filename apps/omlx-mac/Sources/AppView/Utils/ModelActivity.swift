// Live per-request activity for the model rows on the Models and Status
// screens: one row per in-flight request, polled from /admin/api/activity.

import SwiftUI

// MARK: - Rows

struct ModelRequestActivity: Equatable, Sendable, Identifiable {
    enum Phase: Equatable, Sendable {
        case prefill, generating, working
        /// Gone from the payload, still shown briefly. See `ActivityLinger`.
        case finished
    }

    let id: String
    let phase: Phase
    /// 0…1 for `.prefill` only — decode has no bounded total.
    let fraction: Double?
    let percentText: String?
    let detail: String

    var isLive: Bool { phase != .finished }
    /// Every OpenAI-style id shares the "chatcmpl-" head; the tail differs.
    var shortID: String { String(id.suffix(8)) }

    var finished: ModelRequestActivity {
        ModelRequestActivity(id: id, phase: .finished, fraction: fraction,
                             percentText: percentText, detail: detail)
    }
}

struct ModelActivitySnapshot: Equatable, Sendable {
    enum BadgePhase: Equatable, Sendable {
        case prefill, generating, working, queued
    }

    let requests: [ModelRequestActivity]
    let queued: Int
    let badge: String
    let badgePhase: BadgePhase

    /// Lingering rows are not activity — a model with none live is idle.
    var isBusy: Bool { requests.contains(where: \.isLive) || queued > 0 }

    init?(requests: [ModelRequestActivity], queued: Int) {
        guard !requests.isEmpty || queued > 0 else { return nil }
        self.requests = requests
        self.queued = max(0, queued)
        switch requests.first(where: \.isLive)?.phase {
        case .prefill:    badgePhase = .prefill
        case .generating: badgePhase = .generating
        case .working:    badgePhase = .working
        default:          badgePhase = .queued
        }
        badge = ActivityFormat.badge(for: badgePhase)
    }

    init?(model: StatsDTO.ActiveModelDTO) {
        self.init(requests: Self.rows(for: model), queued: model.waitingRequests ?? 0)
    }

    static func rows(for model: StatsDTO.ActiveModelDTO) -> [ModelRequestActivity] {
        rows(prefilling: model.prefilling ?? [],
             generating: model.generating ?? [],
             activities: model.activities ?? [])
    }

    /// Prefill first: it is the bounded phase, and a fixed order keeps rows
    /// from reshuffling between polls.
    static func rows(
        prefilling: [StatsDTO.PrefillProgressDTO],
        generating: [StatsDTO.GenerationProgressDTO],
        activities: [StatsDTO.NonStreamingActivityDTO]
    ) -> [ModelRequestActivity] {
        prefilling.map(row(prefill:))
            + generating.map(row(generating:))
            + activities.map(row(working:))
    }

    private static func row(prefill p: StatsDTO.PrefillProgressDTO) -> ModelRequestActivity {
        let processed = max(0, p.processed ?? 0)
        let total = max(0, p.total ?? 0)
        let fraction = total > 0 ? min(1, Double(processed) / Double(total)) : nil

        var parts = ["\(ActivityFormat.tokens(processed)) / \(ActivityFormat.tokens(total)) tok"]
        if let speed = p.speed, speed > 0 { parts.append("\(ActivityFormat.rate(speed)) tok/s") }
        if let eta = p.eta, eta >= 0 { parts.append(ActivityFormat.left(eta)) }
        if let detail = p.detail, !detail.isEmpty { parts.append(detail) }

        return ModelRequestActivity(
            id: p.requestId ?? "",
            phase: .prefill,
            fraction: fraction,
            percentText: fraction.map { "\(Int(($0 * 100).rounded()))%" },
            detail: parts.joined(separator: " · ")
        )
    }

    private static func row(generating g: StatsDTO.GenerationProgressDTO) -> ModelRequestActivity {
        var parts = ["\(ActivityFormat.tokens(max(0, g.generatedTokens ?? 0))) tok"]
        if let speed = g.tokensPerSecond, speed > 0 {
            parts.append("\(ActivityFormat.rate(speed)) tok/s")
        }
        if let elapsed = g.elapsedSeconds { parts.append(ActivityFormat.duration(elapsed)) }

        return ModelRequestActivity(id: g.requestId ?? "", phase: .generating,
                                    fraction: nil, percentText: nil,
                                    detail: parts.joined(separator: " · "))
    }

    private static func row(working a: StatsDTO.NonStreamingActivityDTO) -> ModelRequestActivity {
        var parts: [String] = []
        if let label = a.detail ?? a.kind, !label.isEmpty { parts.append(label) }
        if let elapsed = a.elapsedSeconds { parts.append(ActivityFormat.duration(elapsed)) }

        return ModelRequestActivity(id: a.requestId ?? "", phase: .working,
                                    fraction: nil, percentText: nil,
                                    detail: parts.joined(separator: " · "))
    }
}

// MARK: - Formatting

enum ActivityFormat {
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return String(format: millions >= 10 ? "%.0fM" : "%.1fM", millions)
        }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))k" }
        return "\(count)"
    }

    /// Decode rates sit in the tens, prefill rates in the thousands.
    static func rate(_ tokensPerSecond: Double) -> String {
        if tokensPerSecond >= 1_000 { return String(format: "%.1fk", tokensPerSecond / 1_000) }
        if tokensPerSecond >= 100 { return String(format: "%.0f", tokensPerSecond) }
        return String(format: "%.1f", tokensPerSecond)
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total)s" }
        let (minutes, rest) = (total / 60, total % 60)
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }

    static func left(_ seconds: Double) -> String {
        String(localized: "activity.eta",
               defaultValue: "\(duration(seconds)) left",
               comment: "Time remaining on a running prefill; placeholder is a duration")
    }

    static func queuedDetail(count: Int) -> String {
        String(localized: "activity.queued_detail",
               defaultValue: "\(count) waiting",
               comment: "Row for requests queued but not started; placeholder is the queue depth")
    }

    static func badge(for phase: ModelActivitySnapshot.BadgePhase) -> String {
        switch phase {
        case .prefill:
            return String(localized: "activity.badge.prefill", defaultValue: "Prefill",
                          comment: "Pill on a model row processing a prompt")
        case .generating:
            return String(localized: "activity.badge.generating", defaultValue: "Generating",
                          comment: "Pill on a model row emitting tokens")
        case .working:
            return String(localized: "activity.badge.working", defaultValue: "Working",
                          comment: "Pill on a model row running a non-streaming request")
        case .queued:
            return String(localized: "activity.badge.queued", defaultValue: "Queued",
                          comment: "Pill on a model row whose requests are all still queued")
        }
    }

    static var doneBadge: String {
        String(localized: "activity.badge.done", defaultValue: "Done",
               comment: "Label on a request row that finished and is leaving the list")
    }
}

// MARK: - Linger

/// Requests leave the payload the instant they finish, so a short one showed
/// for a single poll and blinked out. Hold each row briefly after it goes.
///
/// Keyed on request id, so the prefill-to-decode handover — same id, new
/// phase — never produces a ghost row next to the live one.
struct ActivityLinger {
    static let duration: TimeInterval = 2.5

    private typealias Held = (row: ModelRequestActivity, expiresAt: TimeInterval)

    private var held: [String: [Held]] = [:]
    private var lastLive: [String: [ModelRequestActivity]] = [:]
    private let duration: TimeInterval

    init(duration: TimeInterval = ActivityLinger.duration) {
        self.duration = duration
    }

    /// `now` is injected so retirement is testable without a real clock.
    mutating func merge(
        live: [ModelRequestActivity],
        for modelID: String,
        now: TimeInterval
    ) -> [ModelRequestActivity] {
        let liveIDs = Set(live.map(\.id))
        var current = (held[modelID] ?? []).filter {
            !liveIDs.contains($0.row.id) && $0.expiresAt > now
        }
        let alreadyHeld = Set(current.map(\.row.id))
        for row in lastLive[modelID] ?? []
        where !liveIDs.contains(row.id) && !alreadyHeld.contains(row.id) {
            current.append((row.finished, now + duration))
        }

        held[modelID] = current.isEmpty ? nil : current
        lastLive[modelID] = live
        // Live rows lead, so a finishing row sinks below still-running ones.
        return live + current.map(\.row)
    }

    mutating func retain(models: Set<String>) {
        held = held.filter { models.contains($0.key) }
        lastLive = lastLive.filter { models.contains($0.key) }
    }

    mutating func reset() {
        held.removeAll()
        lastLive.removeAll()
    }
}

// MARK: - Speed smoothing

/// The prefill tracker reports the last chunk's rate, which swings hard
/// between polls and drags `eta` with it. Average the rate and re-derive the
/// ETA from it so the two agree on screen.
struct PrefillSpeedSmoother {
    private var speeds: [String: Double] = [:]
    private let alpha: Double

    init(alpha: Double = 0.35) {
        self.alpha = alpha
    }

    mutating func smoothed(
        _ entries: [StatsDTO.PrefillProgressDTO]
    ) -> [StatsDTO.PrefillProgressDTO] {
        entries.map { entry in
            guard let id = entry.requestId, let raw = entry.speed, raw > 0 else { return entry }
            let averaged = speeds[id].map { $0 + alpha * (raw - $0) } ?? raw
            speeds[id] = averaged
            let remaining = max(0, (entry.total ?? 0) - (entry.processed ?? 0))
            return StatsDTO.PrefillProgressDTO(
                requestId: id, processed: entry.processed, total: entry.total,
                speed: averaged, eta: Double(remaining) / averaged,
                elapsed: entry.elapsed, detail: entry.detail
            )
        }
    }

    /// One smoother serves every model, so pruning happens once per poll
    /// against the union — per model it would evict the others.
    mutating func retain(ids: Set<String>) {
        speeds = speeds.filter { ids.contains($0.key) }
    }

    mutating func reset() {
        speeds.removeAll()
    }
}

// MARK: - Poller

@MainActor
@Observable
final class ModelActivityPoller {
    private(set) var snapshots: [String: ModelActivitySnapshot] = [:]

    @ObservationIgnored private weak var client: OMLXClient?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var smoother = PrefillSpeedSmoother()
    @ObservationIgnored private var linger = ActivityLinger()
    @ObservationIgnored private var failures = 0

    /// A bar that moves once every few seconds reads as broken, but an idle
    /// server does not deserve a request per second.
    private let activeInterval: TimeInterval = 1.0
    private let idleInterval: TimeInterval = 3.0
    /// One timed-out read is not evidence that nothing is running.
    private let failuresBeforeClearing = 3

    func start(client: OMLXClient) {
        self.client = client
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = self.snapshots.isEmpty ? self.idleInterval : self.activeInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        snapshots = [:]
        smoother.reset()
        linger.reset()
        failures = 0
    }

    func snapshot(for modelID: String) -> ModelActivitySnapshot? { snapshots[modelID] }

    private func tick() async {
        guard let client else { return }
        guard let activity = try? await client.getActivity() else {
            failures += 1
            if failures >= failuresBeforeClearing, !snapshots.isEmpty {
                snapshots = [:]
                smoother.reset()
                linger.reset()
            }
            return
        }
        failures = 0

        let models = activity.activeModels.models
        smoother.retain(ids: Set(
            models.flatMap { ($0.prefilling ?? []).compactMap(\.requestId) }
        ))
        linger.retain(models: Set(models.map(\.id)))

        // Monotonic, so a wall-clock jump cannot retire rows early.
        let now = ProcessInfo.processInfo.systemUptime
        var next: [String: ModelActivitySnapshot] = [:]
        for model in models {
            let rows = ModelActivitySnapshot.rows(
                prefilling: smoother.smoothed(model.prefilling ?? []),
                generating: model.generating ?? [],
                activities: model.activities ?? []
            )
            next[model.id] = ModelActivitySnapshot(
                requests: linger.merge(live: rows, for: model.id, now: now),
                queued: model.waitingRequests ?? 0
            )
        }
        if next != snapshots { snapshots = next }
    }

    deinit { pollTask?.cancel() }
}

// MARK: - Views

struct ModelActivityBadge: View {
    let snapshot: ModelActivitySnapshot
    @Environment(\.omlxTheme) private var theme

    var body: some View {
        StatusPill(status: .custom(color: tint, label: snapshot.badge, fillBg: true))
    }

    private var tint: Color {
        switch snapshot.badgePhase {
        case .prefill:              return theme.blueDot
        case .generating, .working: return theme.greenDot
        case .queued:               return theme.amberDot
        }
    }
}

struct ModelActivityList: View {
    let snapshot: ModelActivitySnapshot
    @Environment(\.omlxTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(snapshot.requests) { ModelActivityRow(request: $0) }
            if snapshot.queued > 0 {
                HStack(spacing: 8) {
                    Circle().fill(theme.amberDot).frame(width: 5, height: 5)
                    Text(ActivityFormat.queuedDetail(count: snapshot.queued))
                        .font(.omlxMono(10.5))
                        .foregroundStyle(theme.textTertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        // Keyed on the row set, not the snapshot: the numbers change every
        // poll and cross-fading those would smear the text.
        .animation(.easeInOut(duration: 0.18), value: rowIdentity)
    }

    private var rowIdentity: [String] {
        snapshot.requests.map(\.id) + ["queued:\(snapshot.queued)"]
    }
}

private struct ModelActivityRow: View {
    let request: ModelRequestActivity
    @Environment(\.omlxTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(request.shortID)
                .font(.omlxMono(10.5))
                .foregroundStyle(theme.textTertiary)
                .frame(width: 60, alignment: .leading)

            if let fraction = request.fraction, request.isLive {
                ProgressBar(progress: fraction, tint: tint)
                    .frame(width: 70)
                Text(request.percentText ?? "")
                    .font(.omlxMono(10.5))
                    .foregroundStyle(tint)
                    .frame(width: 32, alignment: .trailing)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 5, height: 5)
                    Text(label).font(.omlxMono(10.5)).lineLimit(1)
                }
                .foregroundStyle(tint)
                // 70 + 8 + 32, so the detail column lines up with prefill rows.
                .frame(width: 110, alignment: .leading)
            }

            Text(request.detail)
                .font(.omlxMono(10.5))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .opacity(request.isLive ? 1 : 0.55)
    }

    private var label: String {
        switch request.phase {
        case .prefill:    return ActivityFormat.badge(for: .prefill)
        case .generating: return ActivityFormat.badge(for: .generating)
        case .working:    return ActivityFormat.badge(for: .working)
        case .finished:   return ActivityFormat.doneBadge
        }
    }

    private var tint: Color {
        guard request.isLive else { return theme.textTertiary }
        switch request.phase {
        case .prefill:  return theme.blueDot
        default:        return theme.greenDot
        }
    }
}
