import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct FileSplitterView: View {
    @Environment(\.dismiss) var dismiss

    @State private var selectedURL:  URL?
    @State private var isDragging    = false
    @State private var chunkMinutes  = 30
    @State private var isSplitting   = false
    @State private var progress:     Double = 0
    @State private var statusText    = ""
    @State private var resultFiles:  [URL] = []
    @State private var errorMessage  = ""

    private let chunkOptions = [15, 20, 30, 45, 60]

    var body: some View {
        VStack(spacing: 0) {
            // Namnlist
            HStack {
                Text("Dela upp ljudfil")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Stäng") { dismiss() }
                    .keyboardShortcut(.escape)
                    .disabled(isSplitting)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Filzon
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isDragging ? Color.accentColor : Color.secondary.opacity(0.3),
                                          style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .background(isDragging ? Color.accentColor.opacity(0.05) : Color.clear)
                            .cornerRadius(12)
                            .frame(height: 140)

                        VStack(spacing: 10) {
                            if let url = selectedURL {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 32)).foregroundColor(.green)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                Text(fileDuration(url: url))
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                                Button("Byt fil") { openFilePicker() }
                                    .font(.system(size: 12))
                            } else {
                                Image(systemName: "scissors")
                                    .font(.system(size: 32)).foregroundColor(.secondary)
                                Text("Dra en ljudfil hit")
                                    .font(.system(size: 14, weight: .medium))
                                Text("MP3, WAV, M4A, MP4, FLAC")
                                    .font(.system(size: 12)).foregroundColor(.secondary)
                                Button("Välj fil") { openFilePicker() }
                                    .font(.system(size: 13)).padding(.top, 4)
                            }
                        }
                    }
                    .onDrop(of: [.audio, .movie, .fileURL], isTargeted: $isDragging) { providers in
                        handleDrop(providers: providers)
                    }

                    // Bitlängd
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dela upp i bitar om").font(.system(size: 13, weight: .medium))
                        HStack(spacing: 10) {
                            ForEach(chunkOptions, id: \.self) { min in
                                Button(action: { chunkMinutes = min }) {
                                    Text("\(min) min")
                                        .font(.system(size: 13, weight: chunkMinutes == min ? .semibold : .regular))
                                        .padding(.horizontal, 14)
                                        .frame(height: 28)
                                        .background(chunkMinutes == min ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                                        .foregroundColor(chunkMinutes == min ? .white : .primary)
                                        .cornerRadius(7)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Framsteg
                    if isSplitting {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(statusText)
                                .font(.system(size: 13)).foregroundColor(.secondary)
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }

                    // Resultat
                    if !resultFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(statusText)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.green)

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(resultFiles, id: \.self) { url in
                                    HStack(spacing: 8) {
                                        Image(systemName: "waveform")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 12))
                                        Spacer()
                                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                                            Image(systemName: "folder")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                            }

                            Button("Visa i Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(resultFiles)
                            }
                            .font(.system(size: 12))
                        }
                    }

                    // Fel
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13)).foregroundColor(.red)
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(8)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                if resultFiles.isEmpty {
                    Button("Dela upp fil") { startSplit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedURL == nil || isSplitting)
                        .keyboardShortcut(.return)
                } else {
                    Button("Klar") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                }
            }
            .padding(16)
        }
        .frame(width: 480, height: 560)
    }

    // MARK: - Filval

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie,
            UTType(filenameExtension: "m4a") ?? .audio,
            UTType(filenameExtension: "mp3") ?? .audio,
            UTType(filenameExtension: "flac") ?? .audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { selectedURL = panel.url }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let ids = [UTType.fileURL.identifier, "public.file-url", UTType.audio.identifier, UTType.movie.identifier]
        for id in ids where provider.hasItemConformingToTypeIdentifier(id) {
            provider.loadItem(forTypeIdentifier: id) { item, _ in
                let url: URL?
                if let u = item as? URL                { url = u }
                else if let d = item as? Data          { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let s = item as? String        { url = URL(string: s) }
                else                                   { url = nil }
                if let url { DispatchQueue.main.async { self.selectedURL = url } }
            }
            return true
        }
        return false
    }

    // MARK: - Dela upp

    private func startSplit() {
        guard let url = selectedURL else { return }
        isSplitting  = true
        resultFiles  = []
        errorMessage = ""
        progress     = 0

        Task {
            do {
                let files = try await performSplit(url: url, chunkMinutes: chunkMinutes)
                await MainActor.run {
                    resultFiles  = files
                    isSplitting  = false
                    progress     = 1.0
                    statusText   = "Klart! \(files.count) filer skapade."
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSplitting  = false
                }
            }
        }
    }

    private func performSplit(url: URL, chunkMinutes: Int) async throws -> [URL] {
        let asset    = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let chunkSec = Double(chunkMinutes * 60)
        let nChunks  = Int(ceil(duration / chunkSec))

        guard let srcTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw SplitError.noAudioTrack
        }

        let outputDir = url.deletingLastPathComponent()
        let baseName  = url.deletingPathExtension().lastPathComponent
        var results:  [URL] = []

        for i in 0..<nChunks {
            let start = Double(i) * chunkSec
            let end   = min(start + chunkSec, duration)

            await MainActor.run {
                progress   = Double(i) / Double(nChunks)
                statusText = "Skapar del \(i + 1) av \(nChunks)…"
            }

            let outputURL = outputDir.appendingPathComponent("\(baseName)_del\(i + 1).m4a")
            try? FileManager.default.removeItem(at: outputURL)

            let comp   = AVMutableComposition()
            let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                              preferredTrackID: kCMPersistentTrackID_Invalid)
            let range  = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 44100),
                end:   CMTime(seconds: end,   preferredTimescale: 44100)
            )
            try aTrack?.insertTimeRange(range, of: srcTrack, at: .zero)

            guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
                throw SplitError.exportFailed
            }
            session.outputURL      = outputURL
            session.outputFileType = .m4a
            await session.export()

            guard session.status == .completed else {
                throw SplitError.exportFailed
            }
            results.append(outputURL)
        }

        return results
    }

    // MARK: - Hjälpare

    private func fileDuration(url: URL) -> String {
        let asset = AVURLAsset(url: url)
        let secs  = CMTimeGetSeconds(asset.duration)
        guard secs > 0 else { return "" }
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        let s = Int(secs) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Fel

enum SplitError: LocalizedError {
    case noAudioTrack
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "Filen innehåller inget ljudspår."
        case .exportFailed: return "Export misslyckades — kontrollera att du har skrivrättigheter till mappen."
        }
    }
}
