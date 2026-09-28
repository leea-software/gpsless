import SwiftUI

/// Recorded drives: export, replay and delete. Shown inside Settings.
struct DrivesView: View {
    @ObservedObject var store: NavigationStore
    /// Called before a replay starts so the settings sheet can close.
    var onReplay: () -> Void
    @State private var drives = DriveRecorder.recordings()
    @State private var references = FieldReferenceStore.recordings()

    private var exportFiles: [URL] {
        return drives + references
    }

    var body: some View {
        List {
                Section {
                    Text("Recordings stay on this iPhone until you export them. Replay recalculates a drive with the installed engine.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Files → On My iPhone → GPSLess → Drives / FieldReferences")
                        .font(.footnote)
                    if !exportFiles.isEmpty {
                        ShareLink(items: exportFiles) {
                            Label("Export all test data", systemImage: "square.and.arrow.up.on.square")
                        }
                        .accessibilityIdentifier("exportAll")
                        Text("\(drives.count) drive segments · \(references.count) references · \(totalSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if drives.isEmpty {
                    ContentUnavailableView("No recorded drives", systemImage: "waveform.path", description: Text("Start tracking to record your first drive."))
                }
                ForEach(drives, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(url.lastPathComponent.replacingOccurrences(of: ".jsonl.gz", with: "").replacingOccurrences(of: ".jsonl", with: "").replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(fileSize(url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 24) {
                            ShareLink(item: url) {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                onReplay()
                                store.replay(url)
                            } label: {
                                Label("Replay", systemImage: "play")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 5)
                }
                .onDelete { indices in
                    for index in indices {
                        do {
                            try FileManager.default.removeItem(at: drives[index])
                        } catch {
                            store.message = "Could not delete recording: \(error.localizedDescription)"
                        }
                    }
                    drives = DriveRecorder.recordings()
                }
                if !references.isEmpty {
                    Section("Field references") {
                        ForEach(references, id: \.self) { url in
                            ShareLink(item: url) {
                                Label(url.deletingPathExtension().lastPathComponent, systemImage: "flag.checkered")
                                    .font(.caption)
                            }
                        }
                        .onDelete { indices in
                            for index in indices {
                                do {
                                    try FileManager.default.removeItem(at: references[index])
                                } catch {
                                    store.message = "Could not delete reference: \(error.localizedDescription)"
                                }
                            }
                            references = FieldReferenceStore.recordings()
                        }
                    }
                }
            }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Recorded drives")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(store.$lastRecording) { _ in
            drives = DriveRecorder.recordings()
            references = FieldReferenceStore.recordings()
        }
    }

    private var totalSize: String {
        let size = exportFiles.reduce(Int64(0)) { total, url in
            return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func fileSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
