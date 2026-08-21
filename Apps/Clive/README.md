# iPhone app target

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig`, and set the bundle identifier and development team. Run `xcodegen generate` to create the iOS 17+ project from `project.yml`. Package versions are committed in the repository `Package.resolved`.

The app source is intentionally separate from the SwiftPM macOS service so the iOS target owns signing, camera, LocalAuthentication, Bonjour, and Keychain entitlements. Terminal bytes pass directly between Network.framework and SwiftTerm and are never persisted or logged. Moving the app inactive detaches its TLS connections; returning requires biometrics and can reattach to Mac-owned shells for up to 30 minutes.

The terminal menu manages active shells, while the connection menu switches paired Macs and performs acknowledged two-sided unpairing. App settings are stored with complete file protection and include an iPhone-side cellular-route opt-in, a default Mac working directory, and ordered named CLI shortcuts. Shortcut commands are explicit user configuration and are never inferred from or captured from terminal traffic.

## Widget and App Shortcut

The generated project embeds a configurable terminal widget and publishes the **Resume Terminal** App Shortcut. A widget can start a new terminal or run one saved CLI shortcut in a new terminal. The app group shares only shortcut names and opaque IDs with the widget; command text, Mac details, output, certificates, and tokens remain in the app. Every widget launch returns to the biometric gate, creates a fresh TLS/PTY session in the configured default directory, and only then runs the selected command.

Run the iOS unit tests after generating the project:

```sh
xcodebuild -project Clive.xcodeproj -scheme Clive -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Before release, verify on a physical iOS 17+ device that the small Home Screen widget and the App Shortcut behave identically for a selected terminal, the terminal list, no saved screen, an offline Mac, a revoked pairing, a changed certificate, and cancelled biometric authentication. Confirm that neither surface displays connection or terminal metadata.

## TestFlight deployment

The `Deploy iOS to TestFlight` GitHub Actions workflow archives and uploads a manually requested build. Configure a protected GitHub environment named `testflight` with these variables:

- `APPLE_TEAM_ID`: the 10-character Apple Developer team ID
- `CLIVE_BUNDLE_ID`: the App Store Connect bundle ID; the widget uses `<bundle-id>.widget` and the shared container uses `group.<bundle-id>`

Add these environment secrets:

- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_PRIVATE_KEY`: the complete contents of the `.p8` key
- `APPLE_DEVELOPMENT_CERTIFICATE_BASE64`: the team's Apple Development identity and private key, exported as a `.p12` and Base64 encoded
- `APPLE_DEVELOPMENT_CERTIFICATE_PASSWORD`: the Development `.p12` export password
- `APPLE_DISTRIBUTION_CERTIFICATE_BASE64`: an Apple Distribution `.p12`, encoded with `base64 -i Distribution.p12 | pbcopy`
- `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`: the `.p12` export password
- `APP_STORE_PROVISIONING_PROFILE_BASE64`: the app's App Store Connect `.mobileprovision`, Base64 encoded
- `WIDGET_APP_STORE_PROVISIONING_PROFILE_BASE64`: the widget's App Store Connect `.mobileprovision`, Base64 encoded

Create the app, widget identifiers, iCloud container, App Store Connect app record, and the `group.<bundle-id>` app group before the first run. Enable that app group for both identifiers, then create separate App Store Connect provisioning profiles for the app and widget. Both profiles must include the shared app group and use the uploaded Apple Distribution certificate. The API key must be allowed to upload builds. Run the workflow from the Actions tab, enter the marketing version, and approve the `testflight` environment if protection rules are enabled. GitHub's run number becomes the monotonically increasing build number.

After Apple finishes processing the first upload, complete its export-compliance response and assign the build to an internal testing group in App Store Connect. Keep external testing disabled until physical-device acceptance and Beta App Review are complete.
