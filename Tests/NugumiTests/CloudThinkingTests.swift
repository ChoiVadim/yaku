import XCTest
@testable import Nugumi

final class CloudThinkingTests: XCTestCase {
    func testOpenAIAndGeminiUseReasoningEffort() {
        let openAI = CloudThinkingOptions(
            provider: .openAI,
            model: "gpt-5.5",
            thinkingLevel: .high
        )
        let gemini = CloudThinkingOptions(
            provider: .gemini,
            model: "gemini-2.5-flash",
            thinkingLevel: .medium
        )

        XCTAssertEqual(openAI.reasoningEffort, "high")
        XCTAssertNil(openAI.thinking)
        XCTAssertNil(openAI.outputConfig)
        XCTAssertEqual(gemini.reasoningEffort, "medium")
        XCTAssertNil(gemini.thinking)
        XCTAssertNil(gemini.outputConfig)
    }

    func testClaudeLegacyThinkingUsesBudgetTokens() {
        let options = CloudThinkingOptions(
            provider: .anthropic,
            model: "claude-haiku-4-5-20251001",
            thinkingLevel: .medium
        )

        XCTAssertNil(options.reasoningEffort)
        XCTAssertEqual(options.thinking?.type, "enabled")
        XCTAssertEqual(options.thinking?.budgetTokens, 2_048)
        XCTAssertNil(options.outputConfig)
    }

    func testClaudeAdaptiveThinkingUsesEffortForNewerModels() {
        let sonnet = CloudThinkingOptions(
            provider: .anthropic,
            model: "claude-sonnet-4-6",
            thinkingLevel: .low
        )
        let opus = CloudThinkingOptions(
            provider: .anthropic,
            model: "claude-opus-4-7",
            thinkingLevel: .high
        )

        XCTAssertEqual(sonnet.thinking?.type, "adaptive")
        XCTAssertNil(sonnet.thinking?.budgetTokens)
        XCTAssertEqual(sonnet.outputConfig?.effort, "low")
        XCTAssertEqual(opus.thinking?.type, "adaptive")
        XCTAssertNil(opus.thinking?.budgetTokens)
        XCTAssertEqual(opus.outputConfig?.effort, "high")
    }

    func testCloudThinkingOptionsEncodeProviderSpecificKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let openAIData = try encoder.encode(CloudThinkingOptions(
            provider: .openAI,
            model: "gpt-5.5",
            thinkingLevel: .low
        ))
        let openAIJSON = String(data: openAIData, encoding: .utf8)
        XCTAssertEqual(openAIJSON, #"{"reasoning_effort":"low"}"#)

        let anthropicData = try encoder.encode(CloudThinkingOptions(
            provider: .anthropic,
            model: "claude-opus-4-7",
            thinkingLevel: .medium
        ))
        let anthropicJSON = String(data: anthropicData, encoding: .utf8)
        XCTAssertEqual(anthropicJSON, #"{"output_config":{"effort":"medium"},"thinking":{"type":"adaptive"}}"#)
    }
}
