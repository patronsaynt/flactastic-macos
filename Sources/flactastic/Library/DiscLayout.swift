import Foundation

/// Reads disc tags as other apps write them: DISCNUMBER may be "2" or "2/3",
/// and the total may sit in its own DISCTOTAL (or TOTALDISCS) tag instead.
enum DiscTag {
    static func parse(number: String?, total: String?) -> (number: Int?, total: Int?) {
        let parts = (number ?? "").split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let n = parts.first.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        let inline = parts.count > 1 ? Int(parts[1]) : nil
        let t = (total.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? inline).flatMap { $0 > 0 ? $0 : nil }
        return (n, t)
    }
}

/// Where an album's discs split, as positions in its running order: a break
/// at 4 means the fifth track starts the next disc. Positional, so dragging a
/// track across a break moves it onto the other disc.
enum DiscLayout {
    /// The breaks for tracks already in order, from their disc numbers.
    static func breaks(forDiscs discs: [Int?]) -> Set<Int> {
        var result: Set<Int> = []
        for i in discs.indices.dropFirst() where (discs[i] ?? 1) != (discs[i - 1] ?? 1) {
            result.insert(i)
        }
        return result
    }

    /// The disc (from 1) that the track at `index` falls on.
    static func disc(at index: Int, breaks: Set<Int>) -> Int {
        1 + breaks.filter { $0 <= index }.count
    }

    /// Track numbers that restart at 1 on every disc.
    static func trackNumbers(count: Int, breaks: Set<Int>) -> [Int] {
        var numbers: [Int] = []
        var n = 0
        for i in 0..<count {
            n = breaks.contains(i) ? 1 : n + 1
            numbers.append(n)
        }
        return numbers
    }

    /// Breaks that still make sense after the list changes length: inside the
    /// list, never before the first track.
    static func clamped(_ breaks: Set<Int>, count: Int) -> Set<Int> {
        breaks.filter { $0 > 0 && $0 < count }
    }
}
