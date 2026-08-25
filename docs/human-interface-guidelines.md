# Human Interface Guidelines for agentic workflows

Use the [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
as a required reference for Clive UI work. Treat the HIG as the design-principle and
platform-convention layer, then implement those decisions with the native elements in
the [Apple UI kit reference](apple-ui-kit-reference.md). Review the [design
principles](https://developer.apple.com/design/human-interface-guidelines/design-principles),
[Generative AI](https://developer.apple.com/design/human-interface-guidelines/generative-ai),
and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/)
guidance alongside the relevant iOS, iPadOS, or macOS component and pattern guidance.

## Design principles and UI kit

Use these principles to decide what the interface should communicate and how much
control it should give people. Use the UI kit reference to decide which native Apple
element should express that decision. This keeps Clive aligned with both the intent of
the HIG and the behavior Apple users already understand.

| HIG principle | Clive design question | Typical native expression |
| --- | --- | --- |
| Purpose | Is the primary task obvious? | Focused navigation hierarchy, clear titles, one primary action |
| Agency | Can people start, stop, dismiss, and recover? | `Button`, `sheet`, navigation back actions, cancellation and recovery controls |
| Responsibility | Are consequences, permissions, and security boundaries clear? | Native alerts, confirmation flows, secure authentication and explanatory copy |
| Familiarity | Will this behave like the same control elsewhere on Apple platforms? | `NavigationStack`, `Form`, `List`, standard toolbar and settings patterns |
| Flexibility | Does it adapt to platform, size, input method, and accessibility needs? | Adaptive SwiftUI layout, Auto Layout, Dynamic Type, VoiceOver labels |
| Simplicity | Is every visible element necessary and understandable? | Native controls with concise labels, progressive disclosure, standard sheets |
| Craft | Does the interaction feel deliberate and polished? | System spacing, typography, materials, animation, and state feedback |
| Delight | Does the experience feel human without distracting from the task? | Appropriate symbols, responsive feedback, and restrained Liquid Glass chrome |

For Clive, an **agentic workflow** is a user-facing flow in which the product proposes,
performs, or reports work on a person's behalf. It can include planning, execution,
requests for input, and a final result. It does not change Clive's existing security or
authorization requirements.

## Review expectations

When an agentic workflow UI is added or materially changed, review it for:

- **Purpose and clarity.** Explain the requested outcome and the scope of any work before
  it begins. Do not imply that AI-generated or automated content was authored by a person.
- **Agency and safety.** Keep people in control. Make consequential actions and approval
  boundaries clear, offer cancellation or recovery when practical, and do not substitute a
  workflow approval for an existing pairing, certificate, or authorization control.
- **Feedback and recovery.** Show meaningful progress, distinguish a completed result from
  a request for input or a failure, and offer the next safe action.
- **Platform conventions.** Prefer native iOS and macOS components, navigation, menus,
  alerts, and terminology. Platform terminology wins when it conflicts with this guide.
- **Liquid Glass.** Use Apple's Liquid Glass materials and controls for Clive's iOS and
  macOS navigation chrome, toolbars, sheets, and interactive controls on supported OS
  versions. Keep content legible and visually separate from the glass; use the closest
  native material fallback on older deployment targets rather than imitating the effect.
- **Accessibility.** Give workflow controls and status the same clear terminology in
  visible text and accessibility labels; do not rely on color, animation, or position alone
  to communicate a state.

## Naming guide

Use these terms consistently in user-facing copy, accessibility labels, feature-map
semantic names, and implementation identifiers when they describe the same concept. Keep
documented protocol and CLI spellings unchanged.

| Preferred term | Meaning | Avoid |
| --- | --- | --- |
| **Agentic workflow** | A user-facing flow that proposes, performs, or reports work on the person's behalf. | Magic, autonomous mode |
| **Task** | A discrete unit of requested work. | Job, operation, action (when it is the task itself) |
| **Proposal** | Work the agent presents for review before it starts. | Suggestion (when it requires approval), plan (when it is already executing) |
| **Approval** | Explicit permission to begin a proposal or cross a defined workflow boundary. | Confirm (when no permission is granted) |
| **Run** | One execution of a task. | Session (unless referring to a Terminal session) |
| **Needs attention** | A run is waiting for user input or a decision. | Blocked, stuck, intervention required |
| **Paused** | A run is temporarily stopped and can resume. | Stopped (unless it cannot resume) |
| **Completed** | A run finished successfully. | Done, successful |
| **Failed** | A run could not finish. Pair it with a clear reason and recovery action. | Error (as the status label) |
| **Cancelled** | A person stopped a run before completion. | Aborted |
| **Result** | The useful output or outcome of a completed run. | Response (unless it is specifically a reply) |

Use sentence case for visible status text. Keep a status separate from the action that
changes it: for example, present **Needs attention** with **Review proposal**, not an
ambiguous **Continue** control. Preserve established Clive vocabulary: **Terminal** is a
shell session and UI, **Connection** is a paired Mac and its selected route, and
**Attachment** is a client joined to a shared Terminal.
