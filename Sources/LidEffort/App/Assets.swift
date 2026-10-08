import AppKit

/// Where the images live depends on how the app was built. Under Xcode the
/// asset catalogue is compiled into the app bundle and `NSImage(named:)`
/// finds everything. Under `swift build` nothing compiles the catalogue, so
/// it is copied into the package's resource bundle as-is and each
/// `<name>.imageset` is read straight from its vector or bitmap file.
enum Assets {
    static func image(named name: String) -> NSImage? {
        if let image = NSImage(named: name) { return image }
        guard let catalogue = Bundle.appResources.url(forResource: "Assets", withExtension: "xcassets") else { return nil }
        let set = catalogue.appendingPathComponent("\(name).imageset")
        guard let files = try? FileManager.default.contentsOfDirectory(at: set, includingPropertiesForKeys: nil) else { return nil }
        for ext in ["svg", "pdf", "png"] {
            if let file = files.first(where: { $0.pathExtension == ext }), let image = NSImage(contentsOf: file) {
                image.setName(name)
                return image
            }
        }
        return nil
    }
}
