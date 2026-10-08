import Foundation

extension Bundle {
    /// SwiftPM's resource bundle for this module: the string catalog and the
    /// asset catalogue.
    ///
    /// Not `Bundle.module` on its own. The accessor SwiftPM generates looks
    /// beside the `.app` (not in `Contents/Resources`, where `bundle.sh` puts
    /// it, and where code signing wants it) and then at the absolute `.build`
    /// path of the Mac that compiled it. On that Mac the second path exists,
    /// so everything works; on anyone else's the accessor calls `fatalError`
    /// and the app dies before its first window. So: the app's own Resources
    /// first, then beside it, and `Bundle.module` only when this is not a
    /// shipped app at all (`swift run`, `swift test`).
    static let appResources: Bundle = {
        let name = "LidEffort_LidEffort.bundle"
        let places = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for place in places.compactMap({ $0 }) {
            if let bundle = Bundle(url: place.appendingPathComponent(name)) { return bundle }
        }
        // A shipped app without its resources reads English and draws no
        // logos, rather than crashing.
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        return .module
    }()
}
