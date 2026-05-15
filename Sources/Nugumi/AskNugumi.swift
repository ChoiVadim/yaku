import CoreGraphics
import Foundation

enum AskNugumiCoordinateSpace: String, Codable, Equatable {
    case screenshotNormalized = "screenshot_normalized"
}

struct AskNugumiPetTarget: Codable, Equatable {
    let x: Double
    let y: Double
    let coordinateSpace: AskNugumiCoordinateSpace

    var isValid: Bool {
        x.isFinite
            && y.isFinite
            && (0...1).contains(x)
            && (0...1).contains(y)
            && coordinateSpace == .screenshotNormalized
    }
}

enum AskNugumiEmotion: String, Codable, Equatable {
    case neutral
    case happy
    case surprised
    case confused
    case concerned
}

struct AskNugumiResponse: Codable, Equatable {
    let message: String
    let petTarget: AskNugumiPetTarget?
    let emotion: AskNugumiEmotion?

    static func parse(_ raw: String) -> AskNugumiResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let decoded = parseJSONResponse(from: trimmed) {
            return decoded
        }

        if let jsonObject = firstBalancedJSONObject(in: trimmed),
           let decoded = parseJSONResponse(from: jsonObject) {
            return decoded
        }

        return AskNugumiResponse(message: trimmed, petTarget: nil, emotion: nil)
    }

    private static func parseJSONResponse(from json: String) -> AskNugumiResponse? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AskNugumiResponse.self, from: data)
        else {
            return nil
        }

        guard !decoded.message.isEmpty else {
            return AskNugumiResponse(message: "", petTarget: nil, emotion: nil)
        }

        return decoded
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else {
                if character == "\"" {
                    isInsideString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1

                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case petTarget
        case emotion
    }

    init(message: String, petTarget: AskNugumiPetTarget?, emotion: AskNugumiEmotion?) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.petTarget = petTarget?.isValid == true ? petTarget : nil
        self.emotion = emotion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .message)
        let petTarget = try? container.decode(AskNugumiPetTarget.self, forKey: .petTarget)
        let emotion = try? container.decode(AskNugumiEmotion.self, forKey: .emotion)

        self.init(message: message, petTarget: petTarget, emotion: emotion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(petTarget, forKey: .petTarget)
        try container.encodeIfPresent(emotion, forKey: .emotion)
    }
}

enum AskNugumiPromptBuilder {
    static func visionPrompt(
        question: String,
        imagePixelSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> String {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let pixelWidth = Int(imagePixelSize.width.rounded())
        let pixelHeight = Int(imagePixelSize.height.rounded())

        return """
User question:
\(cleanQuestion)

Coordinate guide for petTarget:
- The attached PNG is exactly \(pixelWidth)x\(pixelHeight) pixels.
- Return petTarget normalized over the full attached PNG, not over an app window, visibleFrame, or text label.
- If you choose target pixel center (px, py) with top-left origin, return x = px / \(pixelWidth) and y = py / \(pixelHeight).
- For menu bar items, use the tiny icon glyph center in the top strip of the full PNG.
- macOS screenFrame in points: x=\(format(screenFrame.minX)), y=\(format(screenFrame.minY)), width=\(format(screenFrame.width)), height=\(format(screenFrame.height)).
- macOS visibleFrame in points excludes the menu bar/dock: x=\(format(visibleFrame.minX)), y=\(format(visibleFrame.minY)), width=\(format(visibleFrame.width)), height=\(format(visibleFrame.height)).
- The app will convert your normalized PNG coordinate back to screen coordinates; do not compensate for Retina scale or visibleFrame.
"""
    }

    private static func format(_ value: CGFloat) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return String(Int(rounded))
        }
        return String(format: "%.3f", Double(value))
    }
}

struct AskNugumiAnswerBubbleLayout: Equatable {
    let panelSize: CGSize
    let bubbleFrame: CGRect
    let viewportFrame: CGRect
    let documentHeight: CGFloat
    let needsScroll: Bool
}

struct AskNugumiPromptInputLayout: Equatable {
    let panelSize: CGSize
    let bubbleFrame: CGRect
    let textFrame: CGRect
}

struct AskNugumiPetBubblePresentation: Equatable {
    let promptFrame: CGRect
    let petOrigin: CGPoint
}

enum AskNugumiPromptInputMetrics {
    static let panelWidth: CGFloat = 182
    static let minimumPanelHeight: CGFloat = 98
    static let maximumPanelHeight: CGFloat = 210
    static let fontSize: CGFloat = 13
    static let textMeasurementWidth: CGFloat = 104
    static let textMeasurementBottomInset: CGFloat = 6

    private static let bubbleX: CGFloat = 0
    private static let bubbleY: CGFloat = 34
    private static let bubbleWidth: CGFloat = 176
    private static let textX: CGFloat = 30
    private static let textY: CGFloat = 52
    private static let textWidth: CGFloat = 116
    private static let minimumTextHeight: CGFloat = 22
    private static let topTextInset: CGFloat = 24
    private static let bubbleBottomInset: CGFloat = 38

    static func layout(forContentHeight contentHeight: CGFloat) -> AskNugumiPromptInputLayout {
        let sanitizedContentHeight = contentHeight.isFinite
            ? max(1, ceil(contentHeight))
            : minimumTextHeight
        let maximumTextHeight = maximumPanelHeight - textY - topTextInset
        let textHeight = min(
            max(minimumTextHeight, sanitizedContentHeight),
            maximumTextHeight
        )
        let panelHeight = textHeight + textY + topTextInset
        let bubbleHeight = panelHeight - bubbleBottomInset

        return AskNugumiPromptInputLayout(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            bubbleFrame: CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight),
            textFrame: CGRect(x: textX, y: textY, width: textWidth, height: textHeight)
        )
    }
}

enum AskNugumiAnswerBubbleMetrics {
    static let panelWidth: CGFloat = 300
    static let minimumPanelHeight: CGFloat = 136
    static let maximumPanelHeight: CGFloat = 254

    private static let bubbleX: CGFloat = 0
    private static let bubbleY: CGFloat = 34
    private static let bubbleWidth: CGFloat = 294
    private static let textX: CGFloat = 30
    private static let textY: CGFloat = 56
    private static let textWidth: CGFloat = 234
    private static let minimumViewportHeight: CGFloat = 54
    private static let topTextInset: CGFloat = 26
    private static let bubbleBottomInset: CGFloat = 38

    static func layout(forContentHeight contentHeight: CGFloat) -> AskNugumiAnswerBubbleLayout {
        let sanitizedContentHeight = contentHeight.isFinite
            ? max(1, ceil(contentHeight))
            : minimumViewportHeight
        let maximumViewportHeight = maximumPanelHeight - textY - topTextInset
        let viewportHeight = min(
            max(minimumViewportHeight, sanitizedContentHeight),
            maximumViewportHeight
        )
        let panelHeight = viewportHeight + textY + topTextInset
        let bubbleHeight = panelHeight - bubbleBottomInset

        return AskNugumiAnswerBubbleLayout(
            panelSize: CGSize(width: panelWidth, height: panelHeight),
            bubbleFrame: CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight),
            viewportFrame: CGRect(x: textX, y: textY, width: textWidth, height: viewportHeight),
            documentHeight: max(sanitizedContentHeight, viewportHeight),
            needsScroll: sanitizedContentHeight > maximumViewportHeight
        )
    }
}

enum AskNugumiTargetMarkerMetrics {
    static let size: CGFloat = 15
    static let padding: CGFloat = 6

    static func frame(centeredAt point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size
        )
    }

    static func paddedFrame(centeredAt point: CGPoint) -> CGRect {
        frame(centeredAt: point).insetBy(dx: -padding, dy: -padding)
    }
}

enum AskNugumiPetBubblePresentationMetrics {
    static let bubbleToPetPanelGap: CGFloat = -6

    static func presentation(
        petOrigin: CGPoint,
        petSize: CGSize,
        promptSize: CGSize,
        bubbleFrame: CGRect,
        visibleFrame: CGRect,
        edgeMargin: CGFloat
    ) -> AskNugumiPetBubblePresentation {
        let desiredPromptOrigin = CGPoint(
            x: petOrigin.x,
            y: petOrigin.y + petSize.height - bubbleFrame.minY + bubbleToPetPanelGap
        )
        let promptOrigin = clampedOrigin(
            desiredPromptOrigin,
            size: promptSize,
            visibleFrame: visibleFrame,
            edgeMargin: edgeMargin
        )
        var adjustedPetOrigin = petOrigin

        let bubbleOriginY = promptOrigin.y + bubbleFrame.minY
        let targetPetMaxY = bubbleOriginY - bubbleToPetPanelGap
        if petOrigin.y + petSize.height > targetPetMaxY {
            adjustedPetOrigin.y = targetPetMaxY - petSize.height
        }
        adjustedPetOrigin = clampedOrigin(
            adjustedPetOrigin,
            size: petSize,
            visibleFrame: visibleFrame,
            edgeMargin: edgeMargin
        )

        return AskNugumiPetBubblePresentation(
            promptFrame: CGRect(origin: promptOrigin, size: promptSize),
            petOrigin: adjustedPetOrigin
        )
    }

    private static func clampedOrigin(
        _ origin: CGPoint,
        size: CGSize,
        visibleFrame: CGRect,
        edgeMargin: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: min(
                max(origin.x, visibleFrame.minX + edgeMargin),
                visibleFrame.maxX - size.width - edgeMargin
            ),
            y: min(
                max(origin.y, visibleFrame.minY + edgeMargin),
                visibleFrame.maxY - size.height - edgeMargin
            )
        )
    }
}

enum AskNugumiCoordinateMapper {
    static func exactScreenPoint(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect
    ) -> CGPoint {
        let mappedX = screenFrame.minX + target.x * screenFrame.width
        let mappedY = screenFrame.maxY - target.y * screenFrame.height

        return CGPoint(
            x: min(max(mappedX, screenFrame.minX), screenFrame.maxX),
            y: min(max(mappedY, screenFrame.minY), screenFrame.maxY)
        )
    }

    static func screenPoint(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let point = exactScreenPoint(for: target, screenFrame: screenFrame)

        return CGPoint(
            x: min(max(point.x, visibleFrame.minX), visibleFrame.maxX),
            y: min(max(point.y, visibleFrame.minY), visibleFrame.maxY)
        )
    }
}
