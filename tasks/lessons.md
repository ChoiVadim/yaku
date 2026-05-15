# Lessons

- When the user provides a premium Apple liquid glass visual reference, do not keep a native bordered text field inside the glass surface. Build one cohesive pill surface with borderless input chrome, strong rounded geometry, subtle blue glass glow, and expected dismissal behavior such as closing on outside click.
- If the user says a prompt should feel like Apple liquid glass, do not fake it with a large opaque custom overlay. Keep the window compact, disable rectangular panel shadows, let native glass/visual-effect material carry the surface, and use only subtle highlights/accent glows inside the rounded pill.
- When the user asks to remove extra prompt icons, strip accessory controls completely instead of shrinking them. Keep the Ask UI as the input itself, with no plus, divider, mode label, microphone, or expand glyph unless explicitly requested.
- For AppKit borderless prompt fields, vertical centering should be solved in the `NSTextFieldCell`, not by eyeballing a constraint offset.
- For floating AppKit glass popups with layer shadows, make the panel larger than the visible pill and place the pill inside a transparent `shadowMargin`; otherwise the shadow/blur is clipped by the window content rect.
- When reducing the Ask prompt height, scale the pill height, corner radius, font size, input height, and shadow radius together so the result feels intentionally compact instead of vertically squashed.
