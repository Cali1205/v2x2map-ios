import SwiftUI

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer()
            Text("\(model.itsFrames) ITS · \(model.totalFrames) total")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal)
    }

    private var text: String {
        if model.replay.loading { return "Lade Aufnahme …" }
        if model.replay.isActive { return "Wiedergabe · \(model.replay.name ?? "")" }
        switch model.state {
        case .off: return "Bluetooth aus"
        case .unauthorized: return "Bluetooth nicht erlaubt"
        case .scanning: return "Suche ITS-G5-RX …"
        case .connecting: return "Verbinde …"
        case .connected: return "Empfänger verbunden"
        }
    }

    private var color: Color {
        if model.replay.loading { return .orange }
        if model.replay.isActive { return .blue }
        switch model.state {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        default: return .red
        }
    }
}

struct ReplayBar: View {
    @Environment(AppModel.self) private var model
    let onFitRoute: () -> Void
    @State private var scrubbing = false
    @State private var wasPlaying = false
    @State private var scrubValue = 0.0

    var body: some View {
        let duration = max(1, model.replay.duration)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(model.replay.position?.formatted(date: .omitted, time: .standard) ?? "--:--:--")
                    .font(.caption.monospacedDigit().weight(.semibold))
                if let s = model.replay.fix?.speedMps {
                    Text("· \(s.speedKmhText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(format(scrubbing ? scrubValue : model.replay.elapsed)) / \(format(model.replay.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { model.replay.stop() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Wiedergabe beenden")
            }

            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : min(model.replay.elapsed, duration) },
                    set: { v in
                        scrubValue = v
                        model.replay.seek(toElapsed: v)
                    }
                ),
                in: 0...duration,
                onEditingChanged: { editing in
                    if editing {
                        wasPlaying = model.replay.isPlaying
                        scrubValue = model.replay.elapsed
                        scrubbing = true
                        model.replay.pause()
                    } else {
                        scrubbing = false
                        if wasPlaying { model.replay.play() }
                    }
                }
            )
            .disabled(model.replay.duration <= 0)

            HStack(spacing: 22) {
                Button { model.replay.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title3)
                }
                .accessibilityLabel("15 Sekunden zurück")

                Button {
                    model.replay.isPlaying ? model.replay.pause() : model.replay.play()
                } label: {
                    Image(systemName: model.replay.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                .accessibilityLabel(model.replay.isPlaying ? "Pause" : "Abspielen")

                Button { model.replay.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title3)
                }
                .accessibilityLabel("15 Sekunden vor")

                Spacer()

                Menu {
                    ForEach(Replayer.speeds, id: \.self) { s in
                        Button {
                            model.replay.speed = s
                        } label: {
                            if model.replay.speed == s {
                                Label("\(Int(s))×", systemImage: "checkmark")
                            } else {
                                Text("\(Int(s))×")
                            }
                        }
                    }
                } label: {
                    Text("\(Int(model.replay.speed))×")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                .accessibilityLabel("Geschwindigkeit")

                if model.replay.recording?.region != nil {
                    Button(action: onFitRoute) {
                        Image(systemName: "viewfinder").font(.title3)
                    }
                    .accessibilityLabel("Auf Fahrt zoomen")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
