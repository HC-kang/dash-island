import Foundation

extension Locale {
    /// The UI language the app runs in (Korean when the system prefers it and the
    /// bundle has ko.lproj, else English). Dates follow it, so a date never shows
    /// in another language than the sentence around it.
    static let ui: Locale = Bundle.main.preferredLocalizations.first == "ko"
        ? Locale(identifier: "ko_KR") : Locale(identifier: "en_US")
}
