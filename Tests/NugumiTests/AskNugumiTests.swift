import XCTest
@testable import Nugumi

final class AskNugumiTests: XCTestCase {
    func testParsesStrictJSONResponse() throws {
        let raw = """
        {"message":"Click Save.","petTarget":{"x":0.82,"y":0.18,"coordinateSpace":"screenshot_normalized"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click Save.")
        XCTAssertEqual(response.petTarget?.x, 0.82)
        XCTAssertEqual(response.petTarget?.y, 0.18)
        XCTAssertEqual(response.petTarget?.coordinateSpace, .screenshotNormalized)
    }

    func testExtractsJSONFromFencedResponse() throws {
        let raw = """
        Here is the answer:
        ```json
        {"message":"Use the button on the right.","petTarget":{"x":0.9,"y":0.5,"coordinateSpace":"screenshot_normalized"}}
        ```
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Use the button on the right.")
        XCTAssertEqual(response.petTarget?.x, 0.9)
        XCTAssertEqual(response.petTarget?.y, 0.5)
    }

    func testParsesOptionalEmotion() {
        let raw = """
        {"message":"That worked.","emotion":"happy"}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "That worked.")
        XCTAssertEqual(response.emotion, .happy)
        XCTAssertNil(response.petTarget)
    }

    func testRejectsUnsupportedEmotion() {
        let raw = """
        {"message":"I am not sure.","emotion":"sleepy"}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "I am not sure.")
        XCTAssertNil(response.emotion)
    }

    func testFallsBackToPlainMessageForNonJSON() {
        let response = AskNugumiResponse.parse("The save button is at the top right.")

        XCTAssertEqual(response.message, "The save button is at the top right.")
        XCTAssertNil(response.petTarget)
    }

    func testBlankDecodedMessageDoesNotFallBackToRawJSON() {
        let response = AskNugumiResponse.parse("{\"message\":\"   \"}")

        XCTAssertEqual(response.message, "")
        XCTAssertNil(response.petTarget)
    }

    func testRejectsInvalidTargetCoordinates() {
        let raw = """
        {"message":"Click there.","petTarget":{"x":1.4,"y":0.2,"coordinateSpace":"screenshot_normalized"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click there.")
        XCTAssertNil(response.petTarget)
    }

    func testRejectsUnsupportedCoordinateSpace() {
        let raw = """
        {"message":"Click there.","petTarget":{"x":0.4,"y":0.2,"coordinateSpace":"screen_pixels"}}
        """

        let response = AskNugumiResponse.parse(raw)

        XCTAssertEqual(response.message, "Click there.")
        XCTAssertNil(response.petTarget)
    }

    func testMapsTopLeftNormalizedCoordinateToAppKitScreenPoint() {
        let screenFrame = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 100, y: 200, width: 1000, height: 760)
        let target = AskNugumiPetTarget(
            x: 0.25,
            y: 0.10,
            coordinateSpace: .screenshotNormalized
        )

        let point = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(point.x, 350, accuracy: 0.001)
        XCTAssertEqual(point.y, 920, accuracy: 0.001)
    }

    func testClampsMappedCoordinateToVisibleFrame() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 50, y: 40, width: 900, height: 700)
        let target = AskNugumiPetTarget(
            x: 1.0,
            y: 1.0,
            coordinateSpace: .screenshotNormalized
        )

        let point = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(point.x, 950, accuracy: 0.001)
        XCTAssertEqual(point.y, 40, accuracy: 0.001)
    }

    func testExactScreenPointKeepsMenuBarCoordinatesForPointer() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 760)
        let target = AskNugumiPetTarget(
            x: 0.5,
            y: 0.0,
            coordinateSpace: .screenshotNormalized
        )

        let movementPoint = AskNugumiCoordinateMapper.screenPoint(
            for: target,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
        let pointerPoint = AskNugumiCoordinateMapper.exactScreenPoint(
            for: target,
            screenFrame: screenFrame
        )

        XCTAssertEqual(movementPoint.y, 760, accuracy: 0.001)
        XCTAssertEqual(pointerPoint.y, 800, accuracy: 0.001)
    }

    func testAnswerBubbleLayoutGrowsBeforeScrollLimit() {
        let short = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 30)
        let taller = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 120)

        XCTAssertGreaterThan(taller.panelSize.height, short.panelSize.height)
        XCTAssertGreaterThan(taller.bubbleFrame.height, short.bubbleFrame.height)
        XCTAssertFalse(taller.needsScroll)
    }

    func testAnswerBubbleLayoutUsesScrollAfterMaximumHeight() {
        let layout = AskNugumiAnswerBubbleMetrics.layout(forContentHeight: 600)

        XCTAssertEqual(layout.panelSize.height, AskNugumiAnswerBubbleMetrics.maximumPanelHeight)
        XCTAssertTrue(layout.needsScroll)
        XCTAssertGreaterThan(layout.documentHeight, layout.viewportFrame.height)
    }
}
