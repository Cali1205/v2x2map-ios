# V2X Map for iOS + CarPlay

Unofficial iPhone/CarPlay client for the open-source ITS-G5 receiver from
[pit711/V2X2MAP](https://github.com/pit711/V2X2MAP) (ESP32-C5, firmware ≥ 0.2.5).
It connects to the receiver over Bluetooth LE, decodes the European V2X messages it
hears on 5.9 GHz (CAM, DENM, SPATEM, MAPEM, …) and shows them on a map, on the
iPhone and in CarPlay.

> **Not affiliated** with the V2X2MAP project or its official iOS app. If you just want a
> working app, check the App Store first. This repo is a hobby project that can be built
> **without a Mac** (GitHub Actions) and installed via TestFlight.

> **Status: early / untested on real hardware.** Decoder and wire format are unit-tested
> in CI; BLE and CarPlay have not been verified on a device yet.

## Features

| | iPhone | CarPlay |
|---|---|---|
| BLE connection to `ITS-G5-RX`, auto-reconnect (also in background) | ✅ | shared |
| Map markers per station: colour by message type, traffic-light phase red/yellow/green, vehicle heading + speed | ✅ | ✅ |
| Follow / heading-up mode | ✅ | ✅ |
| Hazard banner for new DENMs within 2 km | – | ✅ |
| List of nearby hazards and traffic lights | station list | ✅ |
| Station list, expandable to the last 20 frames, distance, 🔒 signed / 🔓 unsigned | ✅ | |
| Own track | ✅ | |
| "Geiger counter" mode (click/haptic per frame, alert on DENM) | ✅ | |
| PCAP recording for Wireshark (Files app / share sheet) | ✅ | |
| MQTT forwarding of raw frames (`its/<node>/packet`, `mqtts://`/`mqtt://`, optional login) | ✅ | shared |
| Receiver duty-cycle settings | ✅ | |

Not ported from the Android app: MQTT type filter and multiple brokers, USB serial (not possible on iOS),
offline tile cache and OSM tile styles (MapKit is used instead). The UI is in German.

## Hardware

An ESP32-C5 board (e.g. Waveshare ESP32-C5-WIFI6-KIT) flashed with the V2X2MAP firmware ≥ 0.2.5,
e.g. with the [web flasher](https://pit711.github.io/v2x2map/flash/).
Use an antenna that actually covers **5.9 GHz**; plain 2.4 GHz Wi-Fi/BT antennas will receive almost nothing.

## Build & install without a Mac

You need a paid Apple Developer account. Everything else runs on GitHub Actions.

1. **Fork** this repo.
2. **Create an App ID / app record:** in [App Store Connect](https://appstoreconnect.apple.com) → *Apps* → **+**,
   iOS, with a bundle ID of your own (e.g. `io.github.<you>.v2x2map`).
   Set it as repository **variable** `BUNDLE_ID` (*Settings → Secrets and variables → Actions → Variables*).
3. **Create an API key:** App Store Connect → *Users and Access → Integrations → Team Keys* → **+**,
   role **Admin** (needed so CI can create certificates and profiles). Download the `.p8` (only possible once).
4. **Add repository secrets** (*Settings → Secrets and variables → Actions → Secrets*):

   | Secret | Value |
   |---|---|
   | `ASC_KEY_ID` | Key ID |
   | `ASC_ISSUER_ID` | Issuer ID |
   | `ASC_KEY_P8` | full contents of the `.p8` file |
   | `APPLE_TEAM_ID` | your 10-character Team ID (developer.apple.com → Membership) |

   ```powershell
   gh secret set ASC_KEY_ID --body "<key id>"
   gh secret set ASC_ISSUER_ID --body "<issuer id>"
   gh secret set APPLE_TEAM_ID --body "<team id>"
   Get-Content AuthKey_<key id>.p8 -Raw | gh secret set ASC_KEY_P8
   ```
5. *Actions* → **iOS** → *Run workflow* (TestFlight ✅). After processing, the build shows up in
   App Store Connect → *TestFlight*; add yourself as internal tester and install it with the TestFlight app.

Every push and pull request only builds and runs the unit tests on the simulator, unsigned and without secrets.

## CarPlay

Drawing a custom map in CarPlay requires the **CarPlay Navigation entitlement**
(`com.apple.developer.carplay-maps`), which Apple grants on request:

1. Request it at <https://developer.apple.com/contact/carplay/> (category *Navigation*).
2. Once granted, enable *CarPlay Navigation* for your App ID under
   *Certificates, Identifiers & Profiles → Identifiers → Additional Capabilities*.
3. Run the workflow with **CarPlay ✅**. It signs with `V2X2/CarPlay.entitlements`.
   (Before Apple has granted it, this option makes signing fail.)

The CarPlay scene (`V2X2/CarPlay/CarPlaySceneDelegate.swift`) is always compiled. Without the
entitlement the app just doesn't appear in CarPlay.

In the car: full-screen map following the vehicle, zoom and re-center buttons, an *Meldungen*
(alerts) list of hazards and traffic lights sorted by distance, and an 8-second banner for new hazard warnings.

## Project layout

```
project.yml                     XcodeGen spec (the .xcodeproj is generated in CI)
V2X2/Receiver/Receiver.swift    CoreBluetooth: scan, connect, notify, config, MAC
V2X2/Decode/                    ITS5 wire-format reader, 802.11p/GeoNetworking/BTP decoder, DENM/SPATEM UPER
                                → ports of the Android Kotlin decoders; keep them in sync
V2X2/Model/                     shared state for iPhone + CarPlay, location/track, PCAP writer
V2X2/UI/                        SwiftUI map, station list, settings
V2X2/CarPlay/                   CPMapTemplate + MKMapView in the CarPlay window
Tests/                          decoder and wire-format tests (run in CI)
scripts/redact.sh               strips names/e-mails from signing logs (Actions logs are public)
```

### BLE protocol (firmware `bt_stream.c`)

| UUID | | |
|---|---|---|
| `B6E57E90-12D8-4A47-9B21-3F0000000001` | service | advertised by `ITS-G5-RX` |
| `…0002` | notify | stream of `"ITS5" · sec u32 LE · usec u32 LE · len u16 LE · raw 802.11 frame`, split at MTU size |
| `…0003` | read/write | duty cycle, 4 × u16 LE ms: search-sniff, search-BLE, connected-sniff, connected-BLE |
| `…0004` | read | receiver MAC (iOS hides BLE addresses) |

## Privacy & legal

- Everything is decoded on the phone. The app has no server, account or analytics.
  Location is only used to show your position and distances.
- The only network traffic is the optional MQTT forwarding (off by default). It sends the raw received
  frames to the broker you configure; the broker password is stored in the iOS Keychain.
- PCAP recordings stay on the device until you share them. They contain raw radio frames,
  including other vehicles' positions, so be careful where you publish them.
- Receiving and especially redistributing ITS-G5 data may be restricted by telecommunications
  and data-protection law in your country.

## Security

- Signing secrets are only used by the manual `workflow_dispatch` job. Pull requests from forks never get them.
- Workflow token is read-only (`permissions: contents: read`).
- Signing output is redacted before it reaches the public log.

Found a problem? Please open an issue. For security-relevant reports, use GitHub's private vulnerability reporting.

## License

MIT, see [LICENSE](LICENSE). The decoders are ported from V2X2MAP © 2026 Peter Holzhauser and contributors (MIT).
