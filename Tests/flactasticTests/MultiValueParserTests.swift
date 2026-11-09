import Foundation
import Testing
@testable import flactastic

// Runs Tests/Fixtures/metadata-parsing.json through MultiValueParser.resolve.
// The JSON is the spec; this file only adapts it to Swift.

private struct ParsingFixture: Decodable {
    struct Generated: Decodable { var kind: String; var length: Int?; var count: Int? }
    enum Expected: Decodable, Equatable {
        case values([String]), review
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), s == "review" { self = .review } else { self = .values(try c.decode([String].self)) }
        }
    }
    enum DecisionValue: Decodable {
        case keep, split([String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), s == "keep" { self = .keep } else { self = .split(try c.decode([String].self)) }
        }
        var decision: MultiValueParser.Decision {
            switch self { case .keep: .keep; case .split(let parts): .split(parts) }
        }
    }
    struct Case: Decodable {
        var name: String
        var field: String
        var native: [String]?
        var plural: [String]?
        var known: [String]?
        var mbidCount: Int?
        var decision: DecisionValue?
        var generated: Generated?
        var expected: Expected?
        var expectedLengths: [Int]?
        var expectedCount: Int?
    }
    var cases: [Case]
}

private let fixture: ParsingFixture = {
    let url = FixtureSupport.fixturesDir.appendingPathComponent("metadata-parsing.json")
    return try! JSONDecoder().decode(ParsingFixture.self, from: Data(contentsOf: url))
}()

@Test(arguments: fixture.cases.map(\.name))
func metadataParsingCase(_ name: String) throws {
    let c = try #require(fixture.cases.first { $0.name == name })
    let field = try #require(MultiValueParser.Field(rawValue: c.field))
    var native = c.native ?? []
    if let g = c.generated {
        switch g.kind {
        case "longValue": native = [String(repeating: "x", count: g.length ?? 0)]
        case "manyValues": native = (1...(g.count ?? 0)).map { "Artist \($0)" }
        default: Issue.record("unknown generator \(g.kind)")
        }
    }
    let known = Set((c.known ?? []).map { ArtistResolver.key(for: $0) })
    let outcome = MultiValueParser.resolve(
        field: field, plural: c.plural ?? [], native: native, mbidCount: c.mbidCount ?? 0,
        isKnown: { known.contains(ArtistResolver.key(for: $0)) }, decision: c.decision?.decision
    )
    switch c.expected {
    case .review?:
        #expect(outcome == .review(native.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
    case .values(let expected)?:
        #expect(outcome == .values(expected))
    case nil:
        guard case .values(let values) = outcome else { Issue.record("expected values, got \(outcome)"); return }
        if let lengths = c.expectedLengths { #expect(values.map(\.count) == lengths) }
        if let count = c.expectedCount { #expect(values.count == count) }
    }
}

/// The stored form keeps a single string byte for byte, and turns lists into
/// the app's `" ; "` form unless the singular tag already reads as the list.
@Test func storedCreditKeepsTheAppsOwnStrings() {
    #expect(MultiValueParser.storedCredit(plural: [], native: ["Deadmau5; Kaskade"]) == ("Deadmau5; Kaskade", false))
    #expect(MultiValueParser.storedCredit(plural: [], native: ["Simon & Garfunkel"]) == ("Simon & Garfunkel", false))
    #expect(MultiValueParser.storedCredit(plural: ["A", "B"], native: ["A; B"]) == ("A; B", true))
    #expect(MultiValueParser.storedCredit(plural: ["A", "B"], native: ["A feat. B"]) == ("A ; B", true))
    #expect(MultiValueParser.storedCredit(plural: [], native: ["A", "B"]) == ("A ; B", true))
    #expect(MultiValueParser.storedCredit(plural: [], native: ["A & B"], mbidCount: 2) == ("A ; B", true))
    #expect(MultiValueParser.storedCredit(plural: [], native: []) == (nil, false))
}

/// The lyrics lookup's lead-artist guess cuts only at spaced tokens.
@Test func leadArtistGuessForLookups() {
    #expect(MultiValueParser.leadArtistGuess("Future, Metro Boomin") == "Future")
    #expect(MultiValueParser.leadArtistGuess("Deadmau5 ; Rob Swire") == "Deadmau5")
    #expect(MultiValueParser.leadArtistGuess("Kaskade feat. Deadmau5") == "Kaskade")
    #expect(MultiValueParser.leadArtistGuess("AC/DC") == "AC/DC")
    #expect(MultiValueParser.leadArtistGuess("Simon&Garfunkel") == "Simon&Garfunkel")
}
