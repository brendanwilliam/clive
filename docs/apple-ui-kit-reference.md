# Apple UI kit reference

Use this page with the [Human Interface Guidelines](human-interface-guidelines.md).
The HIG explains the design principles and platform conventions; Apple’s UI frameworks
provide the concrete controls, containers, materials, and behaviors that implement them.
Prefer the native element that already supplies the expected behavior before creating a
custom equivalent.

## Framework entry points

- [SwiftUI](https://developer.apple.com/documentation/swiftui/) — declarative views and
  platform-adaptive app structure used throughout the iOS client.
- [UIKit](https://developer.apple.com/documentation/uikit/) — imperative views and
  controls used for the terminal surface and custom keyboard toolbar.
- [AppKit](https://developer.apple.com/documentation/appkit/) — macOS companion windows,
  menus, and controls.

## Common SwiftUI elements

| Need | Start with | Reference |
| --- | --- | --- |
| Screen hierarchy and back navigation | `NavigationStack`, `navigationTitle`, toolbar items | [Navigation](https://developer.apple.com/documentation/swiftui/navigation) |
| Temporary task or settings surface | `sheet`, `presentationDetents`, `presentationDragIndicator` | [Presenting views](https://developer.apple.com/documentation/swiftui/presenting-views) |
| Primary or destructive action | `Button`, `ButtonRole`, `buttonStyle` | [Button](https://developer.apple.com/documentation/swiftui/button) |
| Grouped settings and editable values | `Form`, `Section`, `Toggle`, `Picker` | [Form](https://developer.apple.com/documentation/swiftui/form) |
| Collections and rows | `List`, `ForEach`, `ContentUnavailableView` | [List](https://developer.apple.com/documentation/swiftui/list) |
| System-styled chrome and materials | `Toolbar`, `Material`, `glassEffect` when available | [Toolbar](https://developer.apple.com/documentation/swiftui/toolbar), [glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) |

## Common UIKit elements

| Need | Start with | Reference |
| --- | --- | --- |
| Interactive control | `UIButton`, `UIControl` | [UIButton](https://developer.apple.com/documentation/uikit/uibutton), [UIControl](https://developer.apple.com/documentation/uikit/uicontrol) |
| View hierarchy and constraints | `UIView`, Auto Layout | [UIView](https://developer.apple.com/documentation/uikit/uiview), [Auto Layout](https://developer.apple.com/documentation/uikit/using-auto-layout) |
| Navigation and modal presentation | `UINavigationController`, `UISheetPresentationController` | [UINavigationController](https://developer.apple.com/documentation/uikit/uinavigationcontroller), [UISheetPresentationController](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller) |
| Translucent or Liquid Glass-style chrome | `UIVisualEffectView`, `UIGlassEffect` on supported OS versions | [UIVisualEffectView](https://developer.apple.com/documentation/uikit/uivisualeffectview), [UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect) |
| Accessibility semantics | `accessibilityLabel`, `accessibilityIdentifier`, traits, Dynamic Type | [Accessibility](https://developer.apple.com/documentation/uikit/accessibility) |

## Applying the references

1. Identify the user goal and the relevant HIG principle: purpose, agency,
   responsibility, familiarity, flexibility, simplicity, craft, or delight.
2. Choose the closest native SwiftUI, UIKit, or AppKit element and preserve its normal
   interaction, accessibility, sizing, and platform behavior.
3. Use Liquid Glass and system materials for supported navigation chrome, toolbars,
   sheets, and controls; keep content legible and provide a native fallback for older
   deployment targets.
4. Customize only where Clive’s terminal or security requirements demand it, and record
   the reason in the implementation review.

The framework reference is an implementation index, not a replacement for the HIG.
Always check the current component documentation for availability, platform differences,
and accessibility behavior.
