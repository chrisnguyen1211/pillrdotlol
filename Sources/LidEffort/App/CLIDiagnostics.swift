import Foundation
import LidEffortCore

/// Two flags that make the app answer and exit instead of putting up the
/// notch — for a machine without a hinge sensor, a CI box, or checking what
/// a lid angle would do to each agent's config without moving anything.
///
///   spyx.app/Contents/MacOS/spyx --probe
///   spyx.app/Contents/MacOS/spyx --simulate 175 --dry-run
enum CLIDiagnostics {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--uninstall") {
            let removed = AgentHooks.removeEverything()
            print(removed.isEmpty ? "spyx had nothing in any agent's config."
                                  : "Removed spyx from: \(removed.joined(separator: ", ")).")
            print("You can now move spyx.app to the Trash.")
            exit(0)
        }
        if args.contains("--probe") {
            let sensor = LidAngleSensor()
            print(sensor.diagnostic)
            if let angle = sensor.read() { print("angle: \(angle)°") }
            exit(sensor.read() == nil ? 1 : 0)
        }
        guard let index = args.firstIndex(of: "--simulate") else { return }
        guard index + 1 < args.count, let angle = Double(args[index + 1]) else {
            print("Usage: --simulate <angle> [--dry-run]")
            exit(64)
        }
        // Step mode has no absolute mapping; a fixed angle is read on the
        // standalone tool's 100°–160° dial so the flag still means something.
        var bucketing = EffortBucketing(minAngle: 100, maxAngle: 160, stabilizeSeconds: 0)
        bucketing.update(angle: angle, now: 0)
        let level = bucketing.current
        let dryRun = args.contains("--dry-run")
        print("angle \(angle)° -> lid level \"\(level)\"\(dryRun ? " (dry run)" : "")")
        var failed = false
        for result in EffortTargetWriter.apply(level: level, dryRun: dryRun) {
            let model = result.model ?? "?"
            switch result.outcome {
            case .written(let value): print("  \(result.displayName) [\(model)]: -> \(value)")
            case .unchanged(let value): print("  \(result.displayName) [\(model)]: \(value) (unchanged)")
            case .skipped(let reason): print("  \(result.displayName): skipped — \(reason)")
            case .failed(let message): print("  \(result.displayName) [\(model)]: FAILED — \(message)"); failed = true
            }
        }
        exit(failed ? 1 : 0)
    }
}
