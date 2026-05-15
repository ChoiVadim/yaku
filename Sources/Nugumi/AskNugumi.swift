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

enum AskNugumiPromptInputMetrics {
    static let panelWidth: CGFloat = 182
    static let minimumPanelHeight: CGFloat = 98
    static let maximumPanelHeight: CGFloat = 210
    static let fontSize: CGFloat = 13

    private static let bubbleX: CGFloat = 0
    private static let bubbleY: CGFloat = 34
    private static let bubbleWidth: CGFloat = 176
    private static let textX: CGFloat = 16
    private static let textY: CGFloat = 52
    private static let textWidth: CGFloat = 144
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
    private static let textX: CGFloat = 22
    private static let textY: CGFloat = 56
    private static let textWidth: CGFloat = 252
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
