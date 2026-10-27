import Combine
import XCTest
@testable import SnapLex

@MainActor
final class DashboardNavigationTests: XCTestCase {
    func testAllDashboardSectionsCanBeSelectedAndReselectingIsIdempotent() {
        let navigation = DashboardNavigation()
        var changeCount = 0
        let subscription = navigation.$selectedSection.dropFirst().sink { _ in
            changeCount += 1
        }

        for section in DashboardSection.allCases {
            navigation.select(section)
            XCTAssertEqual(navigation.selectedSection, section)
            let countAfterSelection = changeCount
            navigation.select(section)
            XCTAssertEqual(changeCount, countAfterSelection, "Selecting the current section should be idempotent")
        }
        XCTAssertEqual(changeCount, DashboardSection.allCases.count - 1)

        withExtendedLifetime(subscription) {}
    }

    func testNavigationCanStartOnAnyRequestedSection() {
        for section in DashboardSection.allCases {
            XCTAssertEqual(DashboardNavigation(initialSection: section).selectedSection, section)
        }
    }
}
