# iPhone app target

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig`, and set the bundle identifier and development team. Run `xcodegen generate` to create the iOS 17+ project from `project.yml`. Package versions are committed in the repository `Package.resolved`.

The app source is intentionally separate from the SwiftPM macOS service so the iOS target owns signing, camera, LocalAuthentication, Bonjour, and Keychain entitlements. Terminal bytes pass directly between Network.framework and SwiftTerm and are never persisted or logged. Each tab has one TLS connection and shell; moving the app inactive closes them all and returning requires biometrics again.

## Widget and App Shortcut

The generated project embeds the `CliveResumeWidget` extension and publishes the **Resume Terminal** App Shortcut. The widget carries only the fixed `clive://resume-or-start` URL; it does not read app storage or expose a Mac, terminal label, command, output, certificate, or token. Both entry points return to the app's biometric gate before the coordinator restores navigation or creates a fresh TLS/PTY session.

Run the iOS unit tests after generating the project:

```sh
xcodebuild -project iPhoneTerminal.xcodeproj -scheme iPhoneTerminal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Before release, verify on a physical iOS 17+ device that the small Home Screen widget and the App Shortcut behave identically for a selected terminal, the terminal list, no saved screen, an offline Mac, a revoked pairing, a changed certificate, and cancelled biometric authentication. Confirm that neither surface displays connection or terminal metadata.
