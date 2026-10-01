import Foundation

/// One completed response, as the runtime's own log recorded it: counts and
/// timings only. No prompt, reasoning or reply text ever enters this type.
struct LocalPrediction: Equatable {
    /// The model instance the request was addressed to.
    let instance: String
    let at: Date
    let inputTokens: Int?
    let outputTokens: Int?
    /// Output tokens the model spent thinking before it answered.
    let reasoningTokens: Int?
    /// Reported by the runtime for its own native endpoints; the OpenAI-shaped
    /// response carries token counts but no clock.
    let tokensPerSecond: Double?
    let timeToFirstToken: TimeInterval?
    let generationSeconds: TimeInterval?
    /// Speculative decoding: how many tokens a draft proposed, and how many
    /// the model kept. Nil when nothing was drafted.
    let draftTokens: Int?
    let acceptedDraftTokens: Int?

    init(instance: String, at: Date, inputTokens: Int? = nil, outputTokens: Int? = nil,
         reasoningTokens: Int? = nil, tokensPerSecond: Double? = nil,
         timeToFirstToken: TimeInterval? = nil, generationSeconds: TimeInterval? = nil,
         draftTokens: Int? = nil, acceptedDraftTokens: Int? = nil) {
        self.instance = instance
        self.at = at
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.tokensPerSecond = tokensPerSecond
        self.timeToFirstToken = timeToFirstToken
        self.generationSeconds = generationSeconds
        self.draftTokens = draftTokens
        self.acceptedDraftTokens = acceptedDraftTokens
    }
}

/// Tokens per model per day, added up from the responses a local runtime
/// logged. The local counterpart of a cloud quota: nothing here is a limit,
/// it is what was actually spent.
struct LocalTokenLedger: Equatable {
    struct Totals: Equatable {
        var requests = 0
        var inputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var draftTokens = 0
        var acceptedDraftTokens = 0

        mutating func add(_ prediction: LocalPrediction) {
            requests += 1
            inputTokens += prediction.inputTokens ?? 0
            outputTokens += prediction.outputTokens ?? 0
            reasoningTokens += prediction.reasoningTokens ?? 0
            draftTokens += prediction.draftTokens ?? 0
            acceptedDraftTokens += prediction.acceptedDraftTokens ?? 0
        }

        var totalTokens: Int { inputTokens + outputTokens }

        /// The share of generated tokens spent thinking rather than answering.
        /// Nil until something was generated — a share of nothing is not 0%.
        var reasoningShare: Double? {
            outputTokens > 0 ? Double(reasoningTokens) / Double(outputTokens) : nil
        }

        /// How many speculative drafts the model kept. Nil when the runtime
        /// drafted nothing, which is not the same as accepting none.
        var draftAcceptance: Double? {
            draftTokens > 0 ? Double(acceptedDraftTokens) / Double(draftTokens) : nil
        }
    }

    /// What one model's tooltip shows: today's totals and the last response.
    struct Summary: Equatable {
        let today: Totals
        let last: LocalPrediction?

        /// How much of the loaded context the last request filled. Capped at
        /// one: a prompt the runtime truncated still reads as a full window.
        func contextFraction(contextLength: Int?) -> Double? {
            guard let input = last?.inputTokens, let contextLength, contextLength > 0 else { return nil }
            return min(1, Double(input) / Double(contextLength))
        }

        func contextText(contextLength: Int?) -> String {
            guard let input = last?.inputTokens else { return "—" }
            guard let fraction = contextFraction(contextLength: contextLength) else {
                return L10n.t("\(LimitWindow.compact(input)) tokens")
            }
            return "\(Percent.text(for: fraction))% · \(LimitWindow.compact(input))"
        }

        var tokensTodayText: String {
            L10n.t("\(LimitWindow.compact(today.inputTokens)) in · \(LimitWindow.compact(today.outputTokens)) out")
        }

        var requestsTodayText: String { "\(today.requests)" }

        var reasoningShareText: String {
            today.reasoningShare.map { "\(Percent.text(for: $0))%" } ?? "—"
        }

        var draftAcceptanceText: String {
            today.draftAcceptance.map { "\(Percent.text(for: $0))%" } ?? "—"
        }
    }

    /// The calendar a day is filed under *and* looked up by.
    ///
    /// One property rather than an argument to each call. A day's key is
    /// `startOfDay`, an absolute instant, so the same date in two time zones is
    /// two different keys — and when filing took its caller's calendar while
    /// every query defaulted to `.current`, a ledger filled in one zone and
    /// read in another answered with an empty day and no error.
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Per instance, per local calendar day.
    private(set) var days: [String: [Date: Totals]] = [:]
    private(set) var last: [String: LocalPrediction] = [:]

    /// Long enough for a month's view later; old days are dropped as new ones
    /// arrive, so a year of logs does not stay resident for a reading about today.
    static let retentionDays = 60

    var isEmpty: Bool { days.isEmpty }
    var instances: [String] { Array(days.keys).sorted() }

    /// `key` names the entry — a notch cell id, so the tooltip can look its
    /// own model up — and defaults to the instance the log named.
    mutating func record(_ prediction: LocalPrediction, as key: String? = nil) {
        let instance = key ?? prediction.instance
        let day = calendar.startOfDay(for: prediction.at)
        days[instance, default: [:]][day, default: Totals()].add(prediction)
        // History is read oldest-first, but a live line can land while an
        // older file is still being read; the newest response keeps the cell.
        if (last[instance]?.at ?? .distantPast) <= prediction.at {
            last[instance] = prediction
        }
        if let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: day) {
            for instance in days.keys {
                days[instance]?.keys.filter { $0 < cutoff }.forEach { days[instance]?.removeValue(forKey: $0) }
            }
        }
    }

    func totals(for instance: String, on day: Date) -> Totals? {
        days[instance]?[calendar.startOfDay(for: day)]
    }

    func summary(for instance: String, now: Date) -> Summary? {
        guard days[instance] != nil || last[instance] != nil else { return nil }
        return Summary(today: totals(for: instance, on: now) ?? Totals(),
                       last: last[instance])
    }

    /// Everything logged today across every instance, for Settings.
    func totalsToday(now: Date) -> Totals {
        let day = calendar.startOfDay(for: now)
        return days.values.reduce(into: Totals()) { sum, perDay in
            guard let totals = perDay[day] else { return }
            sum.requests += totals.requests
            sum.inputTokens += totals.inputTokens
            sum.outputTokens += totals.outputTokens
            sum.reasoningTokens += totals.reasoningTokens
            sum.draftTokens += totals.draftTokens
            sum.acceptedDraftTokens += totals.acceptedDraftTokens
        }
    }
}

/// What a local model instance is doing right now, as its runtime reports it.
struct LocalModelActivity: Equatable {
    enum Phase: Equatable {
        case processingPrompt
        case generating
    }

    let phase: Phase
    /// Requests waiting behind the one in progress.
    let queued: Int
    /// When this phase began.
    let since: Date

    var label: String {
        switch phase {
        case .processingPrompt: return L10n.t("Reading prompt")
        case .generating:       return L10n.t("Generating")
        }
    }

    /// The tooltip header's note: the phase, and the line behind it when
    /// there is one. Shorter than `label` because it shares a line with the
    /// card's title, which must not be the one to give way.
    var note: String {
        let phase = self.phase == .processingPrompt ? L10n.t("Prompt") : label
        return queued > 0 ? L10n.t("\(phase) · \(queued) queued") : phase
    }
}
