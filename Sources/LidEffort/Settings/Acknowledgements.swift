import Foundation

/// The notices for the open-source software spyx is built with, which their
/// licenses require to travel with the app. `script/bundle.sh` copies
/// `THIRD_PARTY_NOTICES.md` into the bundle's resources.
enum Acknowledgements {
    static var url: URL? {
        Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
    }
}
