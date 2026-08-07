# iPhone app target

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then run `xcodegen generate` in this directory to create the iOS 17+ Xcode project defined by `project.yml`. It adds the local `IPhoneTerminalCore` package and SwiftTerm. Replace `TerminalSurfaceView` with a `UIViewRepresentable` wrapper around SwiftTerm's `TerminalView`; no terminal bytes should be persisted or logged.

The app source is intentionally separate from the SwiftPM macOS service so the iOS target can own its signing, camera, LocalAuthentication, Bonjour, and Keychain entitlements.
