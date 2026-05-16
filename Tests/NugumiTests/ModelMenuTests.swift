import XCTest
@testable import Nugumi

final class ModelMenuTests: XCTestCase {
    func testModeMenuKeepsAPIKeyModelsInSingleSubmenu() {
        let entries = LLMModel.modeMenuEntries

        XCTAssertEqual(entries.count, 3)

        guard case let .model(online) = entries[0] else {
            return XCTFail("First mode menu entry should be Online.")
        }
        XCTAssertEqual(online.shortName, "Online")

        guard case let .model(offline) = entries[1] else {
            return XCTFail("Second mode menu entry should be Offline.")
        }
        XCTAssertEqual(offline.shortName, "Offline")

        guard case let .apiKeyModels(title, models) = entries[2] else {
            return XCTFail("Third mode menu entry should hold API key models.")
        }
        XCTAssertEqual(title, "API key models")
        XCTAssertEqual(models.map(\.id), LLMModel.all.filter { $0.cloudProvider != nil }.map(\.id))
        XCTAssertTrue(models.allSatisfy { $0.cloudProvider != nil })
    }
}
