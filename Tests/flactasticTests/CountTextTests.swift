import Foundation
import Testing
@testable import flactastic

struct CountTextTests {
    @Test func singularOnlyForOne() {
        #expect(CountText.of(1, "track") == "1 track")
        #expect(CountText.of(0, "track") == "0 tracks")
        #expect(CountText.of(2, "play") == "2 plays")
    }

    @Test func irregularPlural() {
        #expect(CountText.of(3, "child", "children") == "3 children")
    }

    @Test func largeNumbersAreFormatted() {
        #expect(CountText.of(2431, "track") == "\(2431.formatted()) tracks")
    }
}
