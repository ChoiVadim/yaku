# Ask Nugumi Design

Date: 2026-05-15
Status: Approved design, pending implementation plan

## Summary

Ask Nugumi is a new assistance mode for Nugumi. A double press of the Control key opens a compact prompt near the cursor. The user types a question, Nugumi captures the active screen, sends the prompt plus screenshot to a vision-capable LLM, then shows the answer. When the LLM can identify a visual target, it returns a normalized coordinate and the pet animates to that location, pauses, and returns to normal follow-cursor behavior.

This is separate from translation, rewrite, and smart reply. It answers questions about what is currently visible on screen.

## Goals

- Open a near-cursor prompt field from a double-Control gesture.
- Submit the user's typed prompt with an immediate screenshot as image input to the LLM.
- Require a structured response with a message and optional target coordinate.
- Convert the returned normalized coordinate into the correct macOS screen position.
- Move the pet to the target with animation, hold briefly, then return it to follow-cursor behavior.
- Fail gracefully: show an answer even when no coordinate is present or JSON parsing fails.

## Non-Goals

- No automatic clicking, keyboard input, or destructive desktop actions.
- No multi-step agent loop in the first version.
- No OCR-only fallback for Ask Nugumi. The MVP relies on a vision-capable model.
- No manual screenshot area picker in the first version.
- No persistent conversation history in the first version.

## User Flow

1. User double-presses Control within about 300 ms.
2. Nugumi opens a small prompt bubble near the current cursor position.
3. User types a question such as "Where is the Save button?".
4. User presses Enter.
5. Nugumi captures the full active screen and sends the prompt plus screenshot to the selected vision-capable backend.
6. Nugumi shows a loading state in the prompt bubble or pet.
7. LLM returns JSON containing `message` and optionally `petTarget`.
8. Nugumi shows `message` in the existing answer panel style.
9. If `petTarget` is valid, the pet moves to that screen position, pauses for 2-4 seconds, then returns to follow the cursor.

Escape closes the prompt bubble. Empty prompt submit does nothing.

## UX Details

The prompt bubble should be compact and non-activating where possible, visually aligned with Nugumi's existing floating controls. It should appear near the cursor but clamp to the visible screen frame. It should not cover the cursor directly.

Suggested placeholder: `Ask about this screen...`

The prompt should keep focus until submitted or dismissed. It should not steal the source app longer than necessary after submission.

If the selected model cannot accept images, Ask Nugumi should show a short setup error: `Ask Nugumi needs a vision model.` The menu can later guide the user to a supported cloud model, but the MVP only needs a clear error.

## Screenshot Scope

MVP captures the full active screen automatically.

Reasoning:

- "Where is this button?" usually needs surrounding UI context.
- Full active screen is simpler and more reliable than active-window cropping.
- Coordinates returned by the model map naturally to the screenshot.

Later versions can add active-window or cursor-area capture if privacy or token cost becomes a problem.

## LLM Contract

The LLM must return a JSON object. Nugumi should request JSON only, but it must tolerate code fences or extra prose by extracting the first valid JSON object.

Schema:

```json
{
  "message": "Click the Save button in the top-right corner.",
  "petTarget": {
    "x": 0.82,
    "y": 0.18,
    "coordinateSpace": "screenshot_normalized"
  }
}
```

Fields:

- `message`: required string. User-visible answer.
- `petTarget`: optional object. Present only when pointing is useful.
- `petTarget.x`: number from `0.0` to `1.0`, left to right in screenshot space.
- `petTarget.y`: number from `0.0` to `1.0`, top to bottom in screenshot space.
- `petTarget.coordinateSpace`: must be `screenshot_normalized`.

Invalid, missing, out-of-range, or unsupported target values must be ignored while still showing `message`.

## Coordinate Mapping

The screenshot capture result must preserve enough metadata to map the image back to an `NSScreen`.

For a full active-screen screenshot:

1. Determine the active screen from the cursor position at submit time, falling back to `NSScreen.main`.
2. Capture that screen.
3. Store the screen's AppKit frame and visible frame.
4. Convert normalized target to AppKit coordinates:
   - `x = screen.frame.minX + target.x * screen.frame.width`
   - `y = screen.frame.maxY - target.y * screen.frame.height`
5. Clamp the final pet destination to the screen visible frame so the pet stays on screen.

The y-axis is inverted because screenshots use top-left image coordinates while AppKit screen coordinates use bottom-left.

## Architecture

### App Orchestration

Add an Ask Nugumi flow in `NugumiApp`:

- `startAskNugumiPrompt()` opens the prompt.
- `submitAskNugumiPrompt(_:)` captures the active screen and calls the backend.
- `presentAskNugumiResult(_:)` shows the answer and moves the pet if needed.

This should not branch through `TranslationMode`; Ask Nugumi is not translation.

### Prompt Controller

Add an `AskPromptController` near the other floating panel controllers. It owns:

- `NSPanel`
- prompt text field
- submit and close callbacks
- loading state

It should use the same clamp-to-visible-frame behavior as existing floating UI.

### Double-Control Detector

Carbon hotkeys are not enough for double-Control because the gesture is modifier-only. Add a small detector that listens for Control `flagsChanged` events:

- Detect Control key down transitions.
- If two presses occur within about 300 ms, trigger Ask Nugumi.
- Ignore repeated key-repeat noise.
- Ignore while the shortcut recorder is open.
- Ignore while an Ask prompt is already visible.

This can be implemented with a global event monitor first. If global modifier detection is unreliable in some apps, use a listen-only `CGEventTap`.

### Screenshot Capture

Extend the existing screenshot utilities with full active-screen capture. Unlike the existing interactive area capture, Ask Nugumi should not ask the user to draw a region.

The capture API should return:

- PNG data for `ImageInput`
- media type `image/png`
- source screen frame
- visible frame

If Screen Recording permission is missing, reuse the existing permission error UX.

### Backend

Add an Ask-specific backend call instead of overloading `translate()`:

```swift
func ask(
    prompt: String,
    image: ImageInput,
    onPartial: @escaping (String) -> Void
) async throws -> AskNugumiResponse
```

Only vision-capable backends should support this path. Text-only backends should throw a clear unsupported-model error.

### Response Parsing

Add `AskNugumiResponse` and `PetTarget` types:

```swift
struct AskNugumiResponse: Decodable {
    let message: String
    let petTarget: PetTarget?
}

struct PetTarget: Decodable {
    let x: Double
    let y: Double
    let coordinateSpace: String
}
```

Parsing should:

- Decode strict JSON first.
- If strict decoding fails, extract the first balanced JSON object and retry.
- If response text is not valid JSON, show it as a plain message with no pet target.
- Reject targets outside `0...1` or with a different coordinate space.

### Pet Movement

Extend `PetController` with a temporary pointing mode:

- Accept a destination point in AppKit screen coordinates.
- Stop ordinary follow-cursor tracking while pointing.
- Animate the pet toward the destination.
- Keep it there for 2-4 seconds.
- Resume normal follow-cursor tracking.

If the pet is not currently visible, create/show it for the pointing action.

## Error Handling

- Missing Screen Recording permission: reuse current screen-recording permission flow.
- Unsupported model: show `Ask Nugumi needs a vision model.`
- Empty prompt: keep prompt open and do nothing.
- Network/API failure: show the backend error in the prompt/result panel.
- JSON parse failure: show raw text answer and skip pet movement.
- Invalid coordinate: show answer and skip pet movement.
- Capture cancellation or no image: close loading state and show a concise error.

## Testing Plan

Unit tests:

- JSON parser accepts strict JSON.
- JSON parser extracts JSON from code fences or surrounding text.
- Invalid coordinates are rejected.
- Coordinate conversion maps normalized top-left screenshot points to AppKit bottom-left screen points.

Manual verification:

- Double-Control opens prompt near cursor.
- Escape closes prompt.
- Enter submits prompt.
- Screen Recording denial routes to permission UX.
- Vision model receives image input.
- Answer appears without pet move when no `petTarget`.
- Pet moves to returned target, pauses, and returns.
- Prompt and pet clamp correctly near screen edges.
- Behavior works on at least one secondary display or with a non-origin screen frame.

## Implementation Order

1. Add response models, parser, and coordinate conversion tests.
2. Add full active-screen capture API.
3. Add Ask backend method for vision-capable cloud models.
4. Add prompt controller.
5. Add double-Control detector.
6. Add pet pointing animation.
7. Wire the full flow through `NugumiApp`.
8. Run unit tests and a manual app verification pass.

## Open Decisions Locked For MVP

- Screenshot scope: full active screen.
- Coordinate format: normalized screenshot coordinates.
- Trigger: double Control.
- Pet behavior: move, pause, return.
- Model support: vision-capable backends only.
