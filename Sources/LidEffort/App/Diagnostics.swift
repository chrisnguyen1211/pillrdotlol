import AppKit
import MetricKit

/// Crash and hang reports, kept on this Mac.
///
/// macOS hands MetricKit's diagnostics to the app on the launch after they
/// happen — crashes, hangs, disk-write and CPU exceptions. They are written
/// to Application Support as the JSON MetricKit gives, and nothing leaves
/// the machine: Settings offers to copy them, for the user to send if they
/// choose.
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spyx/Diagnostics", isDirectory: true)
    }

    /// Kept to the newest few: they are for a bug report, not an archive.
    static let keep = 20

    func start() {
        guard !Runtime.isUnderTest else { return }
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { Self.save(payload.jsonRepresentation(), at: payload.timeStampEnd) }
    }

    static func save(_ json: Data, at date: Date) {
        let folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("diagnostic-\(stamp)-\(UUID().uuidString.prefix(6)).json")
        try? json.write(to: url, options: .atomic)
        prune()
    }

    /// Newest first.
    static func reports() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }

    private static func prune() {
        for url in reports().dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }

    /// The app and system versions, then the newest reports, as one block
    /// of text to paste into an email or an issue.
    static func summary(limit: Int = 5) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        var text = "spyx \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        let recent = reports().prefix(limit)
        if recent.isEmpty { text += "No crash or hang reports on this Mac.\n" }
        for url in recent {
            text += "\n--- \(url.lastPathComponent)\n"
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return text
    }

    static func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary(), forType: .string)
    }
}
