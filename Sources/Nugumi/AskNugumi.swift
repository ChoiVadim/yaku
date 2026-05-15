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

enum AskNugumiCoordinateMapper {
    static func screenPoint(
        for target: AskNugumiPetTarget,
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let mappedX = screenFrame.minX + target.x * screenFrame.width
        let mappedY = screenFrame.maxY - target.y * screenFrame.height

        return CGPoint(
            x: min(max(mappedX, visibleFrame.minX), visibleFrame.maxX),
            y: min(max(mappedY, visibleFrame.minY), visibleFrame.maxY)
        )
    }
}
