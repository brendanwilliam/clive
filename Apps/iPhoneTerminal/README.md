# iPhone app target

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then run `xcodegen generate` in this directory to create the iOS 17+ Xcode project defined by `project.yml`. It adds the local core package and pinned SwiftTerm dependency. Change the placeholder bundle identifier and select a development team before installing on a device.

The app source is intentionally separate from the SwiftPM macOS service so the iOS target can own signing, camera, LocalAuthentication, Bonjour, and Keychain entitlements. Terminal bytes pass directly between Network.framework and SwiftTerm and are never persisted or logged.
