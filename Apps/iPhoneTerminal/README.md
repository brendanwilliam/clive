# iPhone app target

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig`, and set the bundle identifier and development team. Run `xcodegen generate` to create the iOS 17+ project from `project.yml`. Package versions are committed in the repository `Package.resolved`.

The app source is intentionally separate from the SwiftPM macOS service so the iOS target owns signing, camera, LocalAuthentication, Bonjour, and Keychain entitlements. Terminal bytes pass directly between Network.framework and SwiftTerm and are never persisted or logged. Each tab has one TLS connection and shell; moving the app inactive closes them all and returning requires biometrics again.
