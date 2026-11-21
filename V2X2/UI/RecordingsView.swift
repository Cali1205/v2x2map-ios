import SwiftUI
import UniformTypeIdentifiers

/// Lists recorded drives from the Documents folder and lets the user replay, share, delete or import .pcap files.
struct RecordingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var files: [RecordingFile] = []
    @State private var importing = false

    private static let pcapType = UTType(filenameExtension: "pcap") ?? .data

    var body: some View {
        NavigationStack {
            List {
                if let err = model.replay.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Section {
                    Button {
                        importing = true
                    } label: {
                        Label("PCAP-Datei öffnen …", systemImage: "folder")
                    }
                } footer: {
                    Text("Unterstützt Aufnahmen der App (.pcap + GPS-Spur) sowie Wireshark-PCAPs (802.11 / Radiotap).")
                }

                if !files.isEmpty {
                    Section("Aufgezeichnete Fahrten") {
                        ForEach(files) { file in
                            row(for: file)
                        }
                    }
                }
            }
            .overlay {
                if files.isEmpty && !model.replay.loading {
                    ContentUnavailableView("Keine Aufnahmen", systemImage: "play.rectangle",
                                           description: Text("Tippe auf „Aufnahme“, um eine Fahrt mitzuschneiden, oder öffne eine vorhandene PCAP-Datei."))
                }
            }
            .navigationTitle("Fahrten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .onAppear { reload() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [Self.pcapType, .data]) { result in
                if case .success(let url) = result {
                    model.replay.load(url)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func row(for file: RecordingFile) -> some View {
        let recordingNow = model.recorder.currentFile == file.url
        HStack {
            Button {
                model.replay.load(file.url)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(for: file))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        if file.hasTrack {
                            Text("· mit GPS-Spur")
                        }
                        if recordingNow {
                            Text("· Aufnahme läuft").foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(recordingNow)

            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !recordingNow) {
            if !recordingNow {
                Button("Löschen", role: .destructive) {
                    file.delete()
                    reload()
                }
            }
        }
    }

    private func reload() {
        files = RecordingFile.all()
    }

    private func title(for file: RecordingFile) -> String {
        if let d = file.started {
            return d.formatted(date: .abbreviated, time: .shortened)
        }
        return file.url.deletingPathExtension().lastPathComponent
    }
}
