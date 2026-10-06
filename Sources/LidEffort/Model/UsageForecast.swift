import Foundation
import LidEffortCore

/// When a limit window runs out at the rate it is being used — said only
/// when that is before it resets, because "you'll be fine" is not news.
struct UsageForecast: Equatable {
    let runsOutAt: Date

    /// "out in 25 min" inside the hour, "out ~16:40" after it.
    func text(now: Date) -> String {
        let minutes = Int((runsOutAt.timeIntervalSince(now) / 60).rounded())
        if minutes < 60 { return L10n.t("out in \(max(1, minutes)) min") }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDate(runsOutAt, inSameDayAs: now) ? .none : .short
        return L10n.t("out ~\(formatter.string(from: runsOutAt))")
    }

    /// The rate is the recent one when there is enough of it — the last
    /// three quarters of an hour, at least five minutes apart — else the
    /// window's average so far. Nil when usage is not rising, when the
    /// window is already spent, or when it lasts until its reset.
    static func forecast(used: Double, resetsAt: Date, duration: TimeInterval?,
                         samples: [(at: Date, used: Double)], now: Date) -> UsageForecast? {
        guard used.isFinite, used >= 0, used < 1, resetsAt > now else { return nil }
        var rate: Double?   // fraction per second
        let recent = samples.filter { now.timeIntervalSince($0.at) <= 45 * 60 }.sorted { $0.at < $1.at }
        if let first = recent.first, let last = recent.last, last.at.timeIntervalSince(first.at) >= 5 * 60 {
            rate = (last.used - first.used) / last.at.timeIntervalSince(first.at)
        } else if let duration, duration > 0 {
            let elapsed = duration - resetsAt.timeIntervalSince(now)
            if elapsed >= 10 * 60 { rate = used / elapsed }
        }
        guard let rate, rate > 0 else { return nil }
        let runsOutAt = now.addingTimeInterval((1 - used) / rate)
        return runsOutAt < resetsAt ? UsageForecast(runsOutAt: runsOutAt) : nil
    }
}

/// Remembers each window's recent readings, so a forecast can use the rate
/// of the last half hour rather than the average since the window opened.
@MainActor
final class UsageForecaster {
    static let shared = UsageForecaster()

    private var samples: [String: [(at: Date, used: Double)]] = [:]

    static func key(providerID: String, window: LimitWindow) -> String { "\(providerID)|\(window.id)" }

    func observe(_ snapshots: [ProviderSnapshot], now: Date = Date()) {
        for snapshot in snapshots {
            for window in snapshot.windows {
                guard let used = window.usedFraction else { continue }
                let key = Self.key(providerID: snapshot.providerID, window: window)
                var list = samples[key] ?? []
                // A reset: the old readings describe another window.
                if let last = list.last, used + 0.02 < last.used { list.removeAll() }
                if list.last?.used != used || (list.last.map { now.timeIntervalSince($0.at) > 300 } ?? true) {
                    list.append((now, used))
                }
                samples[key] = list.filter { now.timeIntervalSince($0.at) <= 60 * 60 }
            }
        }
    }

    /// Readings put in by hand — for the feature demo.
    func inject(providerID: String, windowID: String, samples list: [(at: Date, used: Double)]) {
        samples["\(providerID)|\(windowID)"] = list
    }

    func forget(providerID: String) {
        samples = samples.filter { !$0.key.hasPrefix("\(providerID)|") }
    }

    func forecast(providerID: String, window: LimitWindow, now: Date = Date()) -> UsageForecast? {
        guard let used = window.usedFraction, let resetsAt = window.resetsAt else { return nil }
        return UsageForecast.forecast(used: used, resetsAt: resetsAt, duration: window.duration,
                                      samples: samples[Self.key(providerID: providerID, window: window)] ?? [],
                                      now: now)
    }
}

/// Lowers the lid's effort a step when an agent is about to run out —
/// switched on in Settings, once per reset of that window, never below
/// the lowest level. What it did is said on the effort card.
@MainActor
final class AutoEco {
    static let defaultsKey = "effort.autoEco"
    /// Close enough to running out to act: forecast within this, or this used.
    static let warning: TimeInterval = 45 * 60
    static let usedThreshold = 0.9

    private var acted: Set<String> = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isOn: Bool { defaults.bool(forKey: Self.defaultsKey) }

    /// The provider that should make effort step down now, if any — each
    /// window's reset counted once.
    func trigger(_ snapshots: [ProviderSnapshot], forecaster: UsageForecaster,
                 agents: Set<String> = Set(BuiltInTargets.all.map(\.id)), now: Date = Date()) -> ProviderSnapshot? {
        guard isOn else { return nil }
        for snapshot in snapshots where agents.contains(EffortState.targetID(forProviderID: snapshot.providerID)) {
            for window in snapshot.windows {
                guard let used = window.usedFraction, used < 1, let resetsAt = window.resetsAt else { continue }
                let near = used >= Self.usedThreshold
                    || (forecaster.forecast(providerID: snapshot.providerID, window: window, now: now)
                        .map { $0.runsOutAt.timeIntervalSince(now) <= Self.warning } ?? false)
                let key = "\(snapshot.providerID)|\(window.id)|\(Int(resetsAt.timeIntervalSince1970 / 60))"
                if near, !acted.contains(key) {
                    acted.insert(key)
                    return snapshot
                }
            }
        }
        return nil
    }
}
