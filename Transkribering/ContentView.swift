import SwiftUI
import UniformTypeIdentifiers

// Slår ihop "visa sheet" + "initial URL" till en Identifiable struct
// så att .sheet(item:) garanterat ser rätt URL när den visas.
private struct NewTranscriptionRequest: Identifiable {
    let id = UUID()
    let initialURL: URL?
}

struct ContentView: View {
    @EnvironmentObject var auth: AuthManager
    @StateObject private var store: TranscriptStore
    @State private var selectedJob: TranscriptJob?
    @State private var newTranscriptionRequest: NewTranscriptionRequest? = nil
    @State private var showingSettings  = false
    @State private var showingSplitter  = false
    @State private var renamingJob: TranscriptJob? = nil
    @State private var renameText = ""
    @State private var isDropTargeted = false

    private let retentionDays: Int?
    private let showFileSplitter: Bool

    init(retentionDays: Int? = nil, showFileSplitter: Bool = false) {
        self.retentionDays = retentionDays
        self.showFileSplitter = showFileSplitter
        // Ersätts i onAppear med rätt e-post
        _store = StateObject(wrappedValue: TranscriptStore(userEmail: "", retentionDays: retentionDays))
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transkribering")
                            .font(.system(size: 13, weight: .semibold))
                        Text(auth.currentUser?.name ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                // Job list
                if store.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "waveform")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("Inga transkript ännu")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    List(store.jobs, selection: $selectedJob) { job in
                        JobRow(job: job,
                               daysRemaining: store.daysRemaining(for: job),
                               isRenaming: renamingJob?.id == job.id,
                               renameText: $renameText,
                               onRenameCommit: {
                                   commitRename(job: job)
                               })
                            .tag(job)
                            .contextMenu {
                                Button("Byt namn") {
                                    startRename(job: job)
                                }
                                Divider()
                                Button("Ta bort", role: .destructive) {
                                    store.delete(job: job)
                                    if selectedJob?.id == job.id { selectedJob = nil }
                                }
                            }
                            .onTapGesture(count: 2) {
                                startRename(job: job)
                            }
                    }
                    .listStyle(.sidebar)
                }

                Spacer()
                Divider()

                // New transcription button
                Button(action: { newTranscriptionRequest = NewTranscriptionRequest(initialURL: nil) }) {
                    Label("Nytt transkript", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if showFileSplitter {
                    Button(action: { showingSplitter = true }) {
                        Label("Dela upp fil", systemImage: "scissors")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .frame(minWidth: 220)
        } detail: {
            if let job = selectedJob,
               let idx = store.jobs.firstIndex(where: { $0.id == job.id }) {
                TranscriptDetailView(job: $store.jobs[idx], store: store)
                    .id(job.id)
            } else {
                EmptyDetailView(isTargeted: isDropTargeted)
            }
        }
        .onDrop(of: [.audio, .movie, .fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            let ids = [UTType.fileURL.identifier, "public.file-url", UTType.audio.identifier, UTType.movie.identifier]
            for id in ids where provider.hasItemConformingToTypeIdentifier(id) {
                provider.loadItem(forTypeIdentifier: id) { item, _ in
                    let url: URL?
                    if let u = item as? URL                                { url = u }
                    else if let d = item as? Data                          { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let s = item as? String                        { url = URL(string: s) }
                    else                                                   { url = nil }
                    if let url {
                        DispatchQueue.main.async {
                            self.newTranscriptionRequest = NewTranscriptionRequest(initialURL: url)
                        }
                    }
                }
                return true
            }
            return false
        }
        .sheet(item: $newTranscriptionRequest) { req in
            NewTranscriptionView(store: store, initialURL: req.initialURL)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(auth)
        }
        .sheet(isPresented: $showingSplitter) {
            FileSplitterView()
        }
        .onAppear {
            if let email = auth.currentUser?.email {
                store.reinitialize(userEmail: email)
            }
        }
    }

    // MARK: - Namnbyte

    private func startRename(job: TranscriptJob) {
        renamingJob = job
        renameText  = job.fileName
    }

    private func commitRename(job: TranscriptJob) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, var updated = store.jobs.first(where: { $0.id == job.id }) {
            updated.fileName = trimmed
            store.update(job: updated)
            if selectedJob?.id == job.id { selectedJob = updated }
        }
        renamingJob = nil
        renameText  = ""
    }
}

struct JobRow: View {
    let job: TranscriptJob
    var daysRemaining: Int? = nil
    var isRenaming: Bool = false
    @Binding var renameText: String
    var onRenameCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isRenaming {
                TextField("Namn", text: $renameText)
                    .font(.system(size: 13, weight: .medium))
                    .textFieldStyle(.plain)
                    .onSubmit { onRenameCommit() }
                    .onExitCommand { onRenameCommit() }   // Escape sparar också
                    .focusedOnAppear()
            } else {
                Text(job.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(job.formattedDate)
                Text("·")
                Text("\(job.speakerCount) talare")
                Text("·")
                Text(job.formattedDuration)
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            if let days = daysRemaining {
                Text(days == 0 ? "Raderas idag" : "Raderas om \(days) dag\(days == 1 ? "" : "ar")")
                    .font(.system(size: 10))
                    .foregroundColor(days <= 3 ? .orange : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Fokus-modifier

private struct FocusOnAppearModifier: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onAppear { focused = true }
    }
}

private extension View {
    func focusedOnAppear() -> some View {
        modifier(FocusOnAppearModifier())
    }
}

struct EmptyDetailView: View {
    var isTargeted: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
                .cornerRadius(16)
                .padding(20)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

            VStack(spacing: 12) {
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "waveform.badge.microphone")
                    .font(.system(size: 48))
                    .foregroundColor(isTargeted ? .accentColor : .secondary)
                    .animation(.easeInOut(duration: 0.15), value: isTargeted)
                Text(isTargeted ? "Släpp filen här" : "Välj ett transkript")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isTargeted ? .accentColor : .primary)
                if !isTargeted {
                    Text("eller dra en ljudfil hit för att transkribera")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
