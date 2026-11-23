# AGENTS.md – Developer & Agent Handoff Guide

Technical onboarding document for AI agents and contributors working on **V2X Map for iOS + CarPlay** (`Cali1205/v2x2map-ios`).

## 1. Repository & Upstream Context

- **Repository:** `Cali1205/v2x2map-ios` (default branch: `main`, single-branch workflow).
- **Upstream reference (Android app + ESP32-C5 firmware):** `pit711/v2x2map`. Keep wire format (`ITS5`) and core ITS-G5 decoding aligned with upstream when protocol changes occur.
- **UI Language:** All user-facing UI strings, accessibility labels, and `README.md` are in **German**.
- **Roadmap:** Planned features (CarPlay Live Activity & Widget without entitlement, voice alerts, SPATEM countdown, IVIM/CPM decoding, replay timeline markers, RSSI diagnostics) are documented in [`IDEAS.md`](IDEAS.md).

## 2. Project Structure

The Xcode project (`V2X2.xcodeproj`) is **not** checked into git; it is generated from [`project.yml`](project.yml) via **XcodeGen** (`xcodegen generate`). Any new `.swift` file added under `V2X2/` or `Tests/` is picked up automatically.

| Path | Responsibility |
|---|---|
| `project.yml` | XcodeGen specification (`iOS 17.0`, Swift 5, Info.plist keys, `V2X2` & `V2X2Tests` targets). |
| `V2X2/App.swift` | SwiftUI `@main` entry point injecting `AppModel.shared`. |
| `V2X2/Receiver/Receiver.swift` | CoreBluetooth central manager (`ITS-G5-RX`, service `B6E57E90-…-0001`), auto-reconnect, duty-cycle config, MAC read. |
| `V2X2/Decode/FrameReader.swift` | Resyncing BLE stream parser for `"ITS5"` framed 802.11 payloads. |
| `V2X2/Decode/ItsG5Decoder.swift` | 802.11p / LLC-SNAP (`0x8947`) / GeoNetworking (unsecured + IEEE 1609.2 envelope) / BTP-B decoder, `MsgType` (incl. `displayPriority`), `StationClass`. |
| `V2X2/Decode/UperParsers.swift` | ASN.1 UPER `BitReader` + `SpatTemParser`, `DenmParser` (eventPosition, altitude, stationType, cause/subCause), `CamParser` (Basic, High-Frequency, Low-Frequency, PathHistory, SpecialVehicleContainer). |
| `V2X2/Model/AppModel.swift` | `@Observable` `AppModel.shared`, `Station` state & merge logic, `Settings` keys, `Geiger` audio/haptic ticks. |
| `V2X2/Model/EgoDetector.swift` | Own-vehicle detection via motion correlation (distance, speed, heading) + pseudonym ID switch handoff (`ICH` / superseded IDs). |
| `V2X2/Model/LocationTracker.swift` | CoreLocation navigation tracker (`allowsBackgroundLocationUpdates = true`, `showsBackgroundLocationIndicator = true`, `WhenInUse`). |
| `V2X2/Model/PcapRecorder.swift` | Wireshark PCAP writer + companion GPS track CSV in Documents (`UIFileSharingEnabled`). |
| `V2X2/Model/Replayer.swift` | Drive replay engine (`Clock.now` virtual clock, 1×–32× playback, seek/scrubbing, Wireshark PCAP + Radiotap import). |
| `V2X2/Model/MqttClient.swift` | Minimal TLS/TCP MQTT 3.1.1 client + Keychain password storage (`MqttPassword`). |
| `V2X2/UI/ContentView.swift` | Main MapKit screen, `StatusBar`, `ReplayBar`, tappable `StationMarker`, `VehicleBadges`, `MarkerGeometry`, recording prompt on first ESP32 connect. |
| `V2X2/UI/StationDetailView.swift` | Live telemetry inspector sheet (`StationDetailView` + `StationSelection`) with structured key/value sections & raw frame log. |
| `V2X2/UI/StationListView.swift` | Segmented `Liste` / `Tabelle` view with active-only filter, scrollable live telemetry matrix, and drill-down into `StationDetailView`. |
| `V2X2/UI/RecordingsView.swift` | Recorded drives manager, replay launcher, ShareLink, swipe-delete, PCAP file importer. |
| `V2X2/UI/SettingsView.swift` | Map, Geiger, Recording, MQTT, and ESP32 duty-cycle settings. |
| `V2X2/CarPlay/CarPlaySceneDelegate.swift` | CarPlay Driving Task scene (`CPPointOfInterestTemplate` max 12 pins + `CPListTemplate` + DENM `CPAlertTemplate`). |
| `Tests/` | `CamTests`, `DecoderTests`, `EgoDetectorTests`, `MarkerGeometryTests`, `MqttTests`, `ReplayTests`. |
| `scripts/redact.sh` | Strips personal names/emails/IDs from signing logs before public Actions output. |

## 3. Build, Test & Release Workflows

Everything builds on GitHub Actions (no local Mac required):

- **CI on push / PR (`.github/workflows/ios.yml`):**
  - Runs on **`xcode-27`** (Xcode 27.2 / iOS 27.2 SDK — required by App Store Connect starting April 2027).
  - Generates `V2X2.xcodeproj` with `xcodegen generate` and runs all unit tests on an iPhone Simulator (`CODE_SIGNING_ALLOWED=NO`).
  - Prints any compiler warnings matching `warning: .*/V2X2/` and every `Test Case` result. **Keep warnings in `V2X2/` at 0.**
- **Signed TestFlight Deploy (manual `workflow_dispatch`):**
  ```bash
  gh workflow run ios.yml -R Cali1205/v2x2map-ios -f testflight=true -f carplay=true -f runner=xcode-27
  ```
  - Uses `CURRENT_PROJECT_VERSION="${{ github.run_number }}"` (auto-incrementing build number).
  - Signs with `V2X2/CarPlay.entitlements` (`com.apple.developer.carplay-driving-task`) by default (`carplay=true`). Pass `-f carplay=false` only on forks whose App ID lacks the CarPlay entitlement.
  - Required GitHub secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID`. Optional variable: `BUNDLE_ID` (defaults to `io.github.cali1205.v2x2map`).
- **TestFlight Feedback Fetch (`.github/workflows/feedback.yml`):**
  - Manual `workflow_dispatch` fetching TestFlight screenshots, comments, and crash logs via App Store Connect API, encrypted with `FEEDBACK_PASS` as a 1-day artifact (`feedback-encrypted`).
  - Never print raw tester feedback, emails, or personal info into public CI logs or git commits.

## 4. Critical Design Invariants

1. **Virtual Time (`Clock.now`):** Always use `Clock.now` (not `Date()`) when evaluating station activity, TTL pruning, or UI ages so live mode and drive replay behave identically.
2. **Station Multi-Message Stability (`msgTypes` + `displayPriority`):** Traffic-light RSUs alternate between `SPATEM`, `MAPEM`, and `RTCMEM` under one station ID. Always record into `Station.msgTypes` and only replace `Station.msgType` when `incoming.displayPriority >= current.displayPriority`.
3. **CAM Partial-Frame Merging:** Low-frequency containers (lights, role, pathHistory) and `SpecialVehicleContainer` (lightBar, siren) are only transmitted every ~500 ms; optional HF fields may be omitted. Preserve last-known values in `AppModel.apply(_:quiet:)` rather than overwriting with `nil`.
4. **UPER Bit-Exactness:** Verify any new ASN.1 UPER parser fields against ETSI EN 302 637-2 / 302 637-3 / TS 102 894-2 (watch for 1-bit extension markers, e.g. `PathDeltaTime`, `CurvatureCalculationMode`, `ManagementContainer`) and back every decoded field with a unit test in `Tests/CamTests.swift` or `Tests/DecoderTests.swift`.
5. **SwiftUI & MapKit Gotchas:**
   - Avoid ambiguous `ShapeStyle` ternaries (e.g. write `active ? Color.green : Color.gray` instead of `.green : .gray`, and avoid mixing `.tertiary` with `Color`).
   - Map `Annotation` tap targets should wrap marker content in `Button { ... } label: { ... }.buttonStyle(.plain)` so taps aren't swallowed by map pan gestures.
   - Stick to standard iOS 17+ SF Symbols (`car.fill`, `bus.fill`, `box.truck.fill`, `scooter`, `bicycle`, `figure.walk`, `tram.fill`, `light.beacon.max.fill`, `antenna.radiowaves.left.and.right`, `viewfinder.circle.fill`, `scope`, `tablecells`, `list.bullet`).
6. **App Store / TestFlight Compliance:**
   - `ITSAppUsesNonExemptEncryption: false` is set in `project.yml` so TestFlight builds don't block on export compliance.
   - If adding a Widget / Live Activity extension (see `IDEAS.md` §1), remember to add a separate bundle ID (`<BUNDLE_ID>.widget`), App Group entitlement on both targets, and update `ios.yml` archive/codesign steps to sign the embedded `.appex`.

## 5. Current State (as of handoff)

- **Main branch:** Clean, all 25 unit tests passing, 0 warnings on `xcode-27` (Xcode 27.2 / iOS 27.2 SDK).
- **Implemented:** BLE receiver + duty-cycle config, 802.11p/GN/BTP/1609.2 decoder, full CAM + DENM (incl. `eventPosition`) + SPATEM phase decoder, own-vehicle & pseudonym-switch detection, live map with marker tap → `StationDetailView`, `Liste`/`Tabelle` view, PCAP + GPS recording & replay (1×–32×), MQTT forwarding, Geiger mode, CarPlay Driving Task scene (signed with `com.apple.developer.carplay-driving-task` by default).
- **Next suggested milestone:** See [`IDEAS.md`](IDEAS.md) — **CarPlay Live Activity (`ActivityKit`)** or **Acoustic / Voice Hazard Warnings**.
