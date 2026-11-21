# Ideen & Roadmap für V2X Map (iOS / CarPlay)

Gesammelte Ideen und Erweiterungen für kommende Releases.

## 1. CarPlay ohne Apple-Entitlement (iOS 26 / 27+)

Während die vollständige CarPlay-App (`V2X2/CarPlay/CarPlaySceneDelegate.swift`) auf Apples
`com.apple.developer.carplay-driving-task`-Freigabe wartet, funktionieren ab iOS 26 zwei Integrationen
**automatisch in CarPlay – ohne CarPlay-Entitlement**:

### CarPlay Live Activity (`ActivityKit`)
- Erscheint direkt auf dem **CarPlay-Dashboard** (neben Apple Maps / Google Maps) sowie auf Sperrbildschirm und Dynamic Island.
- Kann im Gegensatz zu Widgets **in Echtzeit** von der laufenden App aktualisiert werden, solange BLE + GPS im Hintergrund aktiv sind.
- Geplante Inhalte:
  - **Normalzustand:** Empfänger-Status, Anzahl aktiver V2X-Objekte, Distanz & Tempo des nächsten Fahrzeugs, Aufnahme-Indikator.
  - **Gefahren-Banner (rot/orange):** Sofortige Hervorhebung bei DENM (*„Stauende in 420 m“*, *„Baustelle in 600 m“*), Einsatzfahrzeug mit Blaulicht oder starker Notbremsung voraus.
  - **Ampel-Anzeige:** Aktuelle SPATEM-Phase (rot/gelb/grün) inkl. Restzeit, sobald eine Ampel-RSU in Reichweite ist.

### CarPlay Widget (`WidgetKit`, `.systemSmall`)
- Über *iPhone-Einstellungen → Allgemein → CarPlay → [Fahrzeug] → Widgets* hinzufügbar.
- Übersichts- & Steuer-Kachel mit Verbindungs-/Aufnahmestatus und interaktivem **Start/Stopp-Button für die Aufzeichnung** (`AppIntent`, funktioniert direkt auf CarPlay-Touchscreens).
- Technischer Hinweis für CI/Signing: Benötigt ein Widget-Extension-Target in `project.yml`, eine eigene Bundle-ID (`<BUNDLE_ID>.widget`) und eine App Group zum Datenaustausch.

---

## 2. Akustische Warnungen & Sprachansagen
- Optionale **Sprachansagen** via `AVSpeechSynthesizer` (Audio-Session mit `.duckOthers`, damit Musik/Podcasts nur kurz leiser werden):
  - z. B. *„Notbremsung 120 Meter voraus“*, *„Einsatzfahrzeug nähert sich“*, *„Baustelle in 500 Metern“*.
- **Relevanzfilter:** Richtungs- und Korridorprüfung (Heading + Peilung relativ zur eigenen Fahrtrichtung), damit keine Warnungen von der Gegenfahrbahn ausgelöst werden.
- Konfigurierbare Schwellenwerte (Mindestabstand, Cooldown pro Station/Event).

---

## 3. Weitere ITS-G5-Decoder & Karten-Visualisierung
- **SPATEM-Countdown & Spurzuordnung:** `minEndTime` auswerten (Restsekunden bis Phasenwechsel) und mit `MAPEM`-Kreuzungsgeometrie verknüpfen (eigene Zufahrt/Spur erkennen).
- **IVIM-Inhalts-Parser:** Verkehrszeichen, Tempolimits und Spurreduktionen von Schilderbrücken / Baustellenanhängern dekodieren und als Schild auf der Karte anzeigen.
- **CPM-Objekte (Port 2009):** `PerceivedObjectContainer` parsen, um von anderen Fahrzeugen/RSUs per Radar/Kamera erkannte Fußgänger, Radfahrer und nicht-vernetzte Fahrzeuge auf der Karte darzustellen.
- **Bewegungsspuren (Trails) & `PathHistory`:** Kurze verblassende Schweife hinter aktiven Fahrzeugen + Visualisierung der im CAM mitgesendeten `PathHistory`-Punkte auf der Karte.
- **Entfernungsringe (Reichweiten-Radar):** Optionale konzentrische Ringe (100 m / 300 m / 500 m) um das eigene Fahrzeug zum direkten Einschätzen der 5,9-GHz-Antennenreichweite.
- **Schnellfilter auf der Karte:** Umschalten zwischen *Alle*, *Nur aktiv*, *Nur Warnungen & Ampeln*.

---

## 4. Replay & Fahrt-Analyse
- **Event-Marker auf dem Replay-Zeitstrahl:** Markierungen direkt am Slider für DENMs, Notbremsungen, Blaulicht-Einsätze und neu auftauchende Fahrzeuge + Buttons *„Nächstes / Vorheriges Ereignis“*, um lange Fahrten schnell durchzuspringen.
- **Fahrt-Zusammenfassung / Statistik:** Automatische Kennzahlen pro Aufnahme:
  - Maximale Empfangsreichweite (z. B. *„840 m“*),
  - Anzahl einzigartiger Fahrzeuge (Pseudonym-bereinigt beim eigenen Fahrzeug),
  - Anzahl Gefahrenmeldungen / Ampeln, durchschnittliche Frame-Rate,
  - Optionale Farbcodierung der Replay-Spur nach Funkreichweite oder Verkehrsdichte.

---

## 5. Aufnahme-Komfort & Hardware-Diagnose
- **Smarte Auto-Aufnahme:** Optional erst starten, wenn BLE verbunden ist oder Geschwindigkeit > 5 km/h beträgt; leere 0-Frame-Aufnahmen beim Stoppen automatisch verwerfen.
- **Signalstärke (RSSI / SNR):** Falls die ESP32-Firmware RSSI mitliefert (oder aus Radiotap-Headern bei Wireshark-PCAPs), Empfangspegel pro Station anzeigen – hilfreich zur Optimierung der Antennenposition im Auto.
- **MQTT-Typfilter & mehrere Broker:** Portierung der fehlenden Android-MQTT-Optionen (Filter nach Nachrichtentyp, mehrere Ziel-Broker).
