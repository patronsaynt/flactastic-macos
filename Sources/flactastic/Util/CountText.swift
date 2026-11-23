import Foundation

/// A count with its noun: "1 track", "0 tracks", "2,431 tracks".
/// The number is formatted for the user's locale.
enum CountText {
    static func of(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(count.formatted()) \(count == 1 ? singular : plural ?? singular + "s")"
    }
}
