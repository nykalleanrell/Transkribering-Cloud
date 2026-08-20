import SwiftUI
import UniformTypeIdentifiers

struct NewTranscriptionView: View {
    let store: TranscriptStore
    var initialURL: URL? = nil
    @Environment(\.dismiss) var dismiss

    @AppStorage("openai_api_key") private var apiKey = ""

    @State private var selectedURL:   URL?
    @State private var language       = "sv"
    @State private var speakerCount   = 2
    @State private var isDragging     = false
    @State private var isTranscribing = false
    @State private var errorMessage   = ""

    @StateObject private var whisper = WhisperService()

    var body: some View {
        VStack(spacing: 0) {
            // Namnlist
            HStack {
                Text("Nytt transkript")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Avbryt") { dismiss() }
                    .keyboardShortcut(.escape)
                    .disabled(isTranscribing)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Varning om API-nyckel saknas
                    if apiKey.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("OpenAI API-nyckel saknas — ange den i Inställningar innan du transkriberar.")
                                .font(.system(size: 12))
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // Filzon
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isDragging ? Color.accentColor : Color.secondary.opacity(0.3),
                                          style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .background(isDragging ? Color.accentColor.opacity(0.05) : Color.clear)
                            .cornerRadius(12)
                            .frame(height: 160)

                        VStack(spacing: 10) {
                            if let url = selectedURL {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.green)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                Button("Byt fil") { openFilePicker() }
                                    .font(.system(size: 12))
                            } else {
                                Image(systemName: "waveform")
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary)
                                Text("Dra en fil hit")
                                    .font(.system(size: 14, weight: .medium))
                                Text("MP3, WAV, M4A, MP4, FLAC")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Button("Välj fil") { openFilePicker() }
                                    .font(.system(size: 13))
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .onDrop(of: [.audio, .movie, .fileURL], isTargeted: $isDragging) { providers in
                        handleDrop(providers: providers)
                    }

                    // Språkval
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Språk").font(.system(size: 13, weight: .medium))
                        Picker("", selection: $language) {
                            Text("Svenska").tag("sv")
                            Text("Engelska").tag("en")
                            Text("Auto-detect").tag("auto")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Antal talare
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Antal talare").font(.system(size: 13, weight: .medium))
                        HStack(spacing: 12) {
                            ForEach(1...6, id: \.self) { n in
                                Button(action: { speakerCount = n }) {
                                    Text("\(n)")
                                        .font(.system(size: 13, weight: speakerCount == n ? .semibold : .regular))
                                        .frame(width: 36, height: 28)
                                        .background(speakerCount == n ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                                        .foregroundColor(speakerCount == n ? .white : .primary)
                                        .cornerRadius(7)
                                }
                                .buttonStyle(.plain)
                            }
                            Button(action: { speakerCount = 0 }) {
                                Text("Vet ej")
                                    .font(.system(size: 13, weight: speakerCount == 0 ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(speakerCount == 0 ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                                    .foregroundColor(speakerCount == 0 ? .white : .primary)
                                    .cornerRadius(7)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Framsteg
                    if isTranscribing {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(whisper.statusText)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            ProgressView(value: whisper.progress)
                                .progressViewStyle(.linear)
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }

                    // Fel
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(8)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                if isTranscribing {
                    Button("Avbryt") {
                        whisper.cancel()
                        isTranscribing = false
                        errorMessage   = ""
                    }
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button("Transkribera") { startTranscription() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedURL == nil || isTranscribing || apiKey.isEmpty)
                    .keyboardShortcut(.return)
            }
            .padding(16)
        }
        .frame(width: 480, height: 600)
        .onAppear { if let u = initialURL { selectedURL = u } }
    }

    // MARK: - Filval

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .audio, .movie,
            UTType(filenameExtension: "m4a")!,
            UTType(filenameExtension: "flac") ?? .audio
        ]
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { selectedURL = panel.url }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let ids = [UTType.fileURL.identifier, "public.file-url", UTType.audio.identifier, UTType.movie.identifier]
        for id in ids where provider.hasItemConformingToTypeIdentifier(id) {
            provider.loadItem(forTypeIdentifier: id) { item, _ in
                let url: URL?
                if let u = item as? URL                                    { url = u }
                else if let d = item as? Data                              { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let s = item as? String                            { url = URL(string: s) }
                else                                                       { url = nil }
                if let url { DispatchQueue.main.async { self.selectedURL = url } }
            }
            return true
        }
        return false
    }

    // MARK: - Transkribering

    private func startTranscription() {
        guard let url = selectedURL else { return }
        isTranscribing = true
        errorMessage   = ""

        whisper.transcribe(url: url, language: language, speakerCount: speakerCount) { result in
            DispatchQueue.main.async {
                isTranscribing = false
                switch result {
                case .success(let segments):
                    let bookmark = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    let job = TranscriptJob(
                        fileName:        url.deletingPathExtension().lastPathComponent,
                        createdAt:       Date(),
                        userEmail:       "",
                        segments:        segments,
                        language:        language,
                        durationSeconds: segments.last?.end ?? 0,
                        audioBookmark:   bookmark
                    )
                    store.save(job: job)
                    dismiss()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
