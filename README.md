# V2X Map – iOS + CarPlay

iPhone-App für den ITS-G5-Empfänger aus [pit711/V2X2MAP](https://github.com/pit711/V2X2MAP)
(ESP32-C5, Firmware ≥ 0.2.5). Verbindet sich per Bluetooth mit `ITS-G5-RX`, dekodiert
CAM / DENM / SPATEM / MAPEM und zeigt sie auf der Karte – auf dem iPhone und in CarPlay.

Gebaut wird komplett auf GitHub Actions (macOS-Runner), **kein Mac nötig**.
Installiert wird über **TestFlight**.

## Funktionen

| | iPhone | CarPlay |
|---|---|---|
| BLE-Verbindung, Auto-Reconnect (auch im Hintergrund) | ✅ | ✅ (gemeinsam) |
| Karte mit Markern je Station (Farbe nach Typ, Ampelphase rot/gelb/grün, Fahrtrichtung) | ✅ | ✅ |
| Kompass-/Folgen-Modus | ✅ | ✅ |
| Eigene Spur | ✅ | – |
| Stationsliste, aufklappbar auf die letzten 20 Frames, Entfernung, 🔒/🔓 | ✅ | Liste der Gefahren + Ampeln |
| Geigerzähler-Modus (Klick/Vibration, Warnton bei DENM) | ✅ | |
| PCAP-Aufnahme für Wireshark (Dateien-App / Teilen) | ✅ | |
| Duty-Cycle des Empfängers einstellen | ✅ | |

Bewusst weggelassen gegenüber Android: MQTT-Weiterleitung, USB (geht auf iOS nicht),
Offline-Kartencache (MapKit), OSM-Kartenstile (MapKit hat Standard/Hybrid/Satellit).

## Einmalige Einrichtung

### 1. App in App Store Connect anlegen
1. <https://appstoreconnect.apple.com> → *Apps* → **+** → *Neue App*
2. Plattform iOS, Name z. B. „V2X Map privat“, Sprache Deutsch
3. **Bundle-ID**: `io.github.cali1205.v2x2map`
   (falls nicht in der Liste: unter <https://developer.apple.com/account/resources/identifiers>
   als *App ID* anlegen, oder erst einmal den Workflow laufen lassen – er registriert sie automatisch)
4. SKU: beliebig, z. B. `v2x2map`

### 2. API-Key erzeugen
<https://appstoreconnect.apple.com/access/integrations/api> → *Team Keys* → **+**
- Name: `github-actions`, Zugriff: **Admin** (nötig, damit CI Zertifikate + Profile selbst anlegen darf)
- `.p8` herunterladen (geht nur einmal!), **Key ID** und **Issuer ID** notieren

Team-ID: <https://developer.apple.com/account> → *Membership details*.

### 3. GitHub-Secrets setzen
Repo → *Settings* → *Secrets and variables* → *Actions*:

| Secret | Inhalt |
|---|---|
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | kompletter Inhalt der `.p8`-Datei inkl. `-----BEGIN PRIVATE KEY-----` |
| `APPLE_TEAM_ID` | 10-stellige Team-ID |

Oder per CLI (PowerShell, im Repo-Ordner):
```powershell
gh secret set ASC_KEY_ID --body "XXXXXXXXXX"
gh secret set ASC_ISSUER_ID --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
gh secret set APPLE_TEAM_ID --body "XXXXXXXXXX"
Get-Content AuthKey_XXXXXXXXXX.p8 -Raw | gh secret set ASC_KEY_P8
```

### 4. Bauen & installieren
GitHub → *Actions* → **iOS** → *Run workflow* (TestFlight ✅).
Nach ~10–20 min erscheint der Build in App Store Connect → *TestFlight*.
Dort dich selbst als internen Tester eintragen → TestFlight-App auf dem iPhone → installieren.

Jeder Push auf `main` baut und testet nur (Simulator, ohne Signierung).

## CarPlay

Eine eigene Karte in CarPlay ist nur für Apps mit dem **CarPlay-Navigation-Entitlement**
(`com.apple.developer.carplay-maps`) erlaubt. Das vergibt Apple auf Antrag:

1. Antrag: <https://developer.apple.com/contact/carplay/> → Kategorie *Navigation*.
   Beschreibung z. B.: „Zeigt V2X/ITS-G5-Verkehrsmeldungen (Gefahren, Ampelphasen,
   Fahrzeuge) eines Bluetooth-Empfängers auf einer Karte“.
2. Nach Freigabe: <https://developer.apple.com/account/resources/identifiers> → App ID
   `io.github.cali1205.v2x2map` → *Capabilities* → *Additional Capabilities* → **CarPlay Navigation** aktivieren.
3. Workflow mit **CarPlay ✅** starten → signiert mit `V2X2/CarPlay.entitlements`.

Der CarPlay-Code (`V2X2/CarPlay/CarPlaySceneDelegate.swift`) ist schon fertig und wird
einfach mitgebaut: ohne Entitlement taucht die App in CarPlay nur nicht auf.
Wird der Workflow mit CarPlay ✅ gestartet, **bevor** Apple freigegeben hat, schlägt die
Signierung fehl.

CarPlay-Ansicht: Vollbild-Karte mit Markern (folgt Fahrtrichtung), Buttons für Zoom
und Zentrieren, oben rechts „Meldungen“ = Liste der Gefahren und Ampeln, nächste zuerst.

## Aufbau

```
project.yml                 XcodeGen-Projekt (die .xcodeproj wird in CI erzeugt)
V2X2/Receiver/Receiver.swift    CoreBluetooth: Scan, Verbindung, Notify, Config, MAC
V2X2/Decode/                FrameReader (ITS5-Wireformat), ItsG5Decoder, DENM/SPATEM-UPER
                            → 1:1-Port der Android-Kotlin-Dateien, bei Änderungen beide anpassen
V2X2/Model/AppModel.swift   Stationen, Zähler – gemeinsam für iPhone und CarPlay
V2X2/UI/                    SwiftUI: Karte, Stationsliste, Einstellungen
V2X2/CarPlay/               CPMapTemplate + MKMapView im CarPlay-Fenster
Tests/                      Decoder- und Wireformat-Tests (laufen in CI)
```

BLE-Protokoll (Firmware `bt_stream.c`): Service `B6E57E90-12D8-4A47-9B21-3F0000000001`,
Notify `…0002` (Stream `"ITS5" | sec u32 | usec u32 | len u16 | 802.11-Frame`),
Config `…0003` (4 × u16 ms), MAC `…0004`.

## Lizenz

MIT. Die Decoder sind portiert aus V2X2MAP © 2026 Peter Holzhauser and contributors (MIT).
