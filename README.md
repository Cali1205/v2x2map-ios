# V2X Map für iPhone & CarPlay

Live-Karte für europäische Car2X- / ITS-G5-Funkmeldungen (5,9 GHz) auf dem iPhone – entwickelt für den Open-Source-Empfänger von [pit711/V2X2MAP](https://github.com/pit711/V2X2MAP) (ESP32-C5).

Die App verbindet sich per **Bluetooth LE** mit dem Empfänger und zeigt Fahrzeuge, Einsatzfahrzeuge, Gefahrenmeldungen und vernetzte Ampeln in Echtzeit auf der Karte und in einer Telemetrie-Übersicht an.

> **Unabhängiges Community-Projekt:** Nicht offiziell mit dem V2X2MAP-Projekt verbunden. Die App wird als offenes Hobbyprojekt über GitHub Actions gebaut und per **TestFlight** verteilt.

---

## App installieren (TestFlight)

Die App wird kostenlos als Beta über **Apple TestFlight** bereitgestellt (iOS 17 oder neuer):

1. **TestFlight installieren:** Lade die kostenlose App [TestFlight](https://apps.apple.com/app/testflight/id899247664) aus dem App Store auf dein iPhone.
2. **Einladung öffnen:** Öffne den TestFlight-Einladungslink *(oder die Einladung per E-Mail)* auf dem iPhone und tippe auf **Installieren**.
   - **Öffentlicher TestFlight-Link:** *Wird hier ergänzt, sobald der externe TestFlight-Link in App Store Connect freigegeben ist – bis dahin Einladung auf Anfrage über GitHub Issues.*
3. **Berechtigungen erlauben:** Erlaube beim ersten Start **Bluetooth** (für den ESP32-Empfänger) und **Standort** (für eigene Position, Entfernungen und Spuraufzeichnung).

> **Auch ohne Hardware ausprobieren:** Über **Fahrten → PCAP-Datei öffnen …** kannst du aufgezeichnete ITS-G5-Fahrten (`.pcap` aus der App oder aus Wireshark) direkt auf der Karte abspielen.

---

## Was du brauchst (Hardware)

- Ein **ESP32-C5-Board** (z. B. *Waveshare ESP32-C5-WIFI6-KIT*) mit der **V2X2MAP-Firmware ≥ 0.2.5** – am einfachsten direkt im Browser flashen über den [V2X2MAP Web-Flasher](https://pit711.github.io/v2x2map/flash/).
- Eine **5,9-GHz-Antenne** (Dual-/Tri-Band oder dedizierte 5,9-GHz-V2X-Antenne). Reine 2,4-GHz-WLAN/Bluetooth-Antennen empfangen auf 5,9 GHz kaum Reichweite.
- Stromversorgung im Auto (z. B. USB-Anschluss oder Powerbank). Der Empfänger meldet sich automatisch als **`ITS-G5-RX`** per Bluetooth LE.

---

## Was die App kann

### Live-Karte
- **Fahrzeuge (CAM):** Richtungspfeil in Fahrtrichtung (dreht sich mit der Karte mit), aktuelle Geschwindigkeit, blinkende Seitenblinker, roter Brems-/Notbremsring sowie Status-Badges für Beschleunigung, ACC, Tempomat, Limiter, Fernlicht, Nebellicht und Rückwärtsgang.
- **Einsatzfahrzeuge:** Hervorhebung mit **`BLAULICHT`**- / **`SIRENE`**-Badge und blauem Ring, sobald der `SpecialVehicleContainer` aktiv ist.
- **Gefahrenmeldungen (DENM):** Warnmarker direkt am gemeldeten **Ereignisort** (z. B. Stauende, Baustelle, Unfall, Pannenfahrzeug, Einsatzfahrzeug) mit Ursache und Unterkategorie.
- **Ampeln & Infrastruktur (SPATEM / MAPEM / RSU):** Farbcodierte Ampelphasen (**Rot / Gelb / Grün**) und eigenes Antennen-Symbol für Straßenrand-Stationen (RSU).
- **Eigenes Fahrzeug (`ICH`):** Erkennt dein eigenes Fahrzeug automatisch anhand von Position, Kurs und Geschwindigkeit – auch über regelmäßige ITS-G5-Pseudonym-Wechsel hinweg. In den Optionen lässt sich der eigene Marker auf Wunsch ausblenden.
- **Aktivitätsstatus:** Sendende Objekte pulsieren; nach 15 Sekunden ohne Empfang werden sie grau dargestellt (oder ausgeblendet) und nach der eingestellten Marker-Lebensdauer entfernt.
- **Kartenansicht:** Standard, Hybrid oder Satellit, Kompass-Folgemodus (Fahrtrichtung oben) sowie eigene GPS-Spur.

### Telemetrie-Inspektor & Tabellenansicht
- **Marker antippen:** Öffnet den **Live-Telemetrie-Inspektor** mit allen dekodierten Daten der Station:
  - Bewegung & Position (Tempo, Kurs + Himmelsrichtung, Fahrtrichtung, Entfernung, Spur, Koordinaten, Höhe)
  - Fahrdynamik (Längs-, Quer- und Vertikalbeschleunigung, Lenkwinkel, Gierrate, Kurvenradius)
  - Fahrzeugdaten (Klasse, Rolle, Länge × Breite, Leistungsklasse, Blaulicht/Martinshorn)
  - Assistenzsysteme, Pedale & Beleuchtung als übersichtliche Status-Kacheln
  - Funk & Protokoll (Station-ID, Signaturstatus 🔒/🔓, Empfangsrate in Hz, Frame-Zähler, letzte 20 Rohframes als Hex)
  - **Karte**-Button zum direkten Zentrieren auf die Station
- **Liste & Tabelle:** Tippe unten auf **Liste** und schalte oben zwischen **Liste** und **Tabelle** um. Die **Tabelle** zeigt alle Stationen nebeneinander mit allen Fahrzeugwerten im Live-Vergleich (horizontal & vertikal scrollbar, mit Filter **Aktiv**).

### Aufnahme & Wiedergabe (Replay)
- **Fahrt aufzeichnen:** Speichert alle empfangenen Rohframes als Wireshark-kompatible `.pcap`-Datei plus GPS-Spur (auch im Hintergrund). Beim App-Start fragt die App auf Wunsch direkt nach oder startet automatisch (*Optionen → Immer automatisch aufzeichnen*).
- **Fahrten abspielen:** Über **Fahrten** spielst du eigene Aufnahmen oder importierte Wireshark-PCAPs erneut ab – mit Zeitstrahl-Scrubbing, ±15-s-Sprüngen und Geschwindigkeit von **1× bis 32×**.
- **Teilen:** Aufnahmen können direkt aus der App geteilt oder über die iOS-**Dateien**-App kopiert werden.

### Weitere Optionen
- **Geigerzähler-Modus:** Dezenter Klick + Haptik pro empfangenem Frame und deutlicher Warnton bei Gefahrenmeldungen (DENM).
- **MQTT-Weiterleitung (optional, standardmäßig aus):** Sendet empfangene Rohframes an einen eigenen Broker (`mqtts://` / `mqtt://`, Topic `its/<Node-ID>/packet`, Passwort geschützt im iOS-Schlüsselbund).
- **Empfänger-Konfiguration:** Sniff- und Bluetooth-Zeitfenster des ESP32-C5 direkt aus den Einstellungen anpassen.

### CarPlay
- Die CarPlay-Oberfläche (*Driving Task* mit Karte der 12 nächsten Objekte, Meldungsliste und automatischem Gefahren-Hinweis innerhalb von 2 km) ist vollständig in der App enthalten.
- **Hinweis:** Für die Anzeige in CarPlay ist eine Freigabe des CarPlay-Entitlements durch Apple erforderlich. Solange diese aussteht, läuft die App regulär auf dem iPhone (inkl. Hintergrundbetrieb bei angeschlossenem Empfänger).

---

## Schnellstart

1. ESP32-C5 einschalten (mit 5,9-GHz-Antenne).
2. **V2X Map** auf dem iPhone öffnen – oben erscheint nach wenigen Sekunden ein grüner Punkt (**Empfänger verbunden**).
3. Auf der Karte erscheinen erkannte Fahrzeuge, Ampeln und Gefahrenmeldungen live; tippe einen Marker an, um alle Telemetriedaten zu sehen, oder öffne **Liste → Tabelle** für die Gesamtübersicht.

---

## Datenschutz & Rechtliches

- **Alles lokal auf dem iPhone:** Kein Nutzerkonto, kein Tracking, keine Analyse-Dienste. Dein Standort wird ausschließlich für Position, Fahrspur und Entfernungsberechnung genutzt.
- **MQTT nur auf Wunsch:** Netzwerkverkehr entsteht erst, wenn du die MQTT-Weiterleitung aktiv einschaltest.
- **Aufnahmen (PCAP):** Bleiben lokal auf deinem iPhone, bis du sie aktiv teilst. Sie enthalten rohe Funkframes inkl. Positionen anderer Verkehrsteilnehmer – bitte verantwortungsvoll behandeln.
- **Rechtlicher Hinweis:** Empfang und insbesondere Weiterverbreitung von ITS-G5-Funkdaten können je nach Land telekommunikations- und datenschutzrechtlichen Bestimmungen unterliegen.

---

## Feedback & Ideen

- **Beta-Feedback:** Direkt über TestFlight (*Screenshot erstellen → Feedback teilen*) oder als [GitHub Issue](https://github.com/Cali1205/v2x2map-ios/issues).
- **Geplante Erweiterungen:** Eine Übersicht über nächste Ideen (u. a. CarPlay Live Activity & Widget ohne Entitlement, Sprachansagen, SPATEM-Countdown, Replay-Ereignis-Timeline) findest du in [IDEAS.md](IDEAS.md).

---

<details>
<summary><strong>Für Entwickler: Architektur, Selbst-Bauen ohne Mac & BLE-Protokoll</strong></summary>

### Selbst bauen & via TestFlight verteilen (ohne Mac)

Voraussetzung ist ein Apple Developer Account. Der gesamte Build inkl. Signierung läuft über GitHub Actions (`xcode-27` / iOS 27 SDK):

1. Repository **forken**.
2. In [App Store Connect](https://appstoreconnect.apple.com) eine neue iOS-App mit eigener Bundle-ID anlegen (z. B. `io.github.<name>.v2x2map`) und diese als Repository-Variable `BUNDLE_ID` hinterlegen (*Settings → Secrets and variables → Actions → Variables*).
3. In App Store Connect unter *Users and Access → Integrations → Team Keys* einen API-Key mit Rolle **Admin** erstellen und die `.p8`-Datei herunterladen.
4. Folgende Repository-Secrets setzen (*Settings → Secrets and variables → Actions → Secrets*):
   - `ASC_KEY_ID` – Key ID
   - `ASC_ISSUER_ID` – Issuer ID
   - `ASC_KEY_P8` – vollständiger Inhalt der `.p8`-Datei
   - `APPLE_TEAM_ID` – 10-stellige Team-ID
   - *(optional)* `FEEDBACK_PASS` – Passphrase für verschlüsselte TestFlight-Feedback-Artefakte (`.github/workflows/feedback.yml`)
5. Unter *Actions → iOS → Run workflow* mit **TestFlight ✅** starten (CarPlay erst aktivieren, nachdem Apple `com.apple.developer.carplay-driving-task` freigegeben hat).

Jeder Push und Pull Request baut und prüft automatisch alle Unit-Tests unsigniert im Simulator. Weitere technische Details, Architektur-Konventionen und Übergabe-Hinweise stehen in [AGENTS.md](AGENTS.md).

### BLE-Protokoll (`bt_stream.c`)

| UUID | Funktion | Beschreibung |
|---|---|---|
| `B6E57E90-12D8-4A47-9B21-3F0000000001` | Service | Advertised von `ITS-G5-RX` |
| `…0002` | Notify | Stream `"ITS5" · sec u32 LE · usec u32 LE · len u16 LE · raw 802.11 frame` |
| `…0003` | Read/Write | Duty-Cycle, 4 × u16 LE ms (Suche Sniff/BLE, Verbunden Sniff/BLE) |
| `…0004` | Read | Empfänger-MAC |

### Sicherheit & Lizenz

- Signier-Secrets werden ausschließlich bei manuellem `workflow_dispatch` geladen (nie bei Fork-PRs); `permissions: contents: read`; Logs werden über `scripts/redact.sh` bereinigt.
- **Lizenz:** MIT – siehe [LICENSE](LICENSE). Die Basis-Decoder wurden von [V2X2MAP](https://github.com/pit711/V2X2MAP) © 2026 Peter Holzhauser und Mitwirkende (MIT) portiert.

</details>
