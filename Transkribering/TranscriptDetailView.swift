import SwiftUI
import UniformTypeIdentifiers

// MARK: - Environment key: speakerMode

struct SpeakerModeKey: EnvironmentKey {
    static let defaultValue = true   // Cloud = true, Local = false
}

extension EnvironmentValues {
    var speakerMode: Bool {
        get { self[SpeakerModeKey.self] }
        set { self[SpeakerModeKey.self] = newValue }
    }
}

// MARK: -

let SPEAKER_COLORS: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .yellow, .red]

struct TranscriptDetailView: View {
    @Binding var job: TranscriptJob
    var store: TranscriptStore? = nil
    @Environment(\.speakerMode) private var speakerMode

    @State private var searchText  = ""
    @State private var activeFilter: String? = nil
    @State private var showingExport = false
    @StateObject private var audioPlayer = AudioPlayerModel()

    var speakers: [String] {
        var seen = [String]()
        for seg in job.segments {
            if !seen.contains(seg.speaker) { seen.append(seg.speaker) }
        }
        return seen
    }

    var filteredSegments: [TranscriptSegment] {
        job.segments.filter { seg in
            (activeFilter == nil || seg.speaker == activeFilter) &&
            (searchText.isEmpty || seg.text.localizedCaseInsensitiveContains(searchText) ||
             seg.speakerName.localizedCaseInsensitiveContains(searchText))
        }
    }

    struct SegmentEntry: Identifiable {
        let id: UUID
        let segment: TranscriptSegment
        let isMatch: Bool
        let showBreak: Bool  // visa "…" ovanför denna rad
    }

    var segmentsWithContext: [SegmentEntry] {
        let segs = job.segments.filter { activeFilter == nil || $0.speaker == activeFilter }
        guard !searchText.isEmpty else {
            return segs.map { SegmentEntry(id: UUID(), segment: $0, isMatch: true, showBreak: false) }
        }
        let matchIndices = Set(segs.indices.filter {
            segs[$0].text.localizedCaseInsensitiveContains(searchText) ||
            segs[$0].speakerName.localizedCaseInsensitiveContains(searchText)
        })
        var included = Set<Int>()
        for i in matchIndices {
            if i > 0 { included.insert(i - 1) }
            included.insert(i)
            if i < segs.count - 1 { included.insert(i + 1) }
        }
        let sorted = included.sorted()
        var result: [SegmentEntry] = []
        for (pos, idx) in sorted.enumerated() {
            let showBreak = pos > 0 && sorted[pos - 1] != idx - 1
            result.append(SegmentEntry(id: UUID(), segment: segs[idx],
                                       isMatch: matchIndices.contains(idx), showBreak: showBreak))
        }
        return result
    }

    // Grouped into 2-minute blocks for the non-speaker (local) mode
    var timeBlocks: [(label: String, start: Double, text: String)] {
        let blockSec = 120.0
        guard !job.segments.isEmpty else { return [] }
        let maxTime = job.segments.map(\.end).max() ?? 0
        var blocks: [(label: String, start: Double, text: String)] = []
        var t = 0.0
        while t < maxTime {
            let blockEnd = t + blockSec
            let segs = job.segments.filter { $0.start >= t && $0.start < blockEnd &&
                (searchText.isEmpty || $0.text.localizedCaseInsensitiveContains(searchText)) }
            if !segs.isEmpty {
                let combined = segs.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                blocks.append((label: formatTime(t), start: t, text: combined))
            }
            t = blockEnd
        }
        return blocks
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                HStack(spacing: 16) {
                    if speakerMode {
                        StatBadge(value: "\(job.speakerCount)", label: "talare")
                    }
                    StatBadge(value: job.formattedDuration, label: "längd")
                    StatBadge(value: "\(job.wordCount)", label: "ord")
                }

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 12))
                    TextField("Sök...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .frame(width: 160)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(7)

                Button(action: copyAllText) {
                    Label("Kopiera text", systemImage: "doc.on.doc")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)

                Button(action: { showingExport = true }) {
                    Label("Exportera", systemImage: "arrow.up.doc")
                        .font(.system(size: 13))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if speakerMode {
                // Speaker rename chips (Cloud only)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(speakers.enumerated()), id: \.element) { i, sp in
                            SpeakerRenameChip(
                                speaker: sp,
                                color: SPEAKER_COLORS[i % SPEAKER_COLORS.count],
                                name: Binding(
                                    get: { job.segments.first(where: { $0.speaker == sp })?.speakerName ?? sp },
                                    set: { newName in renameSpeaker(sp, to: newName) }
                                ),
                                isActive: activeFilter == sp,
                                onTap: { activeFilter = activeFilter == sp ? nil : sp }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                Divider()

                // Per-segment rows with speaker label + seek-on-timestamp-click
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(segmentsWithContext) { entry in
                                let seg = entry.segment
                                let spIdx = speakers.firstIndex(of: seg.speaker) ?? 0
                                let speakerEntries: [(id: String, name: String, color: Color)] = speakers.enumerated().map { i, sp in
                                    let name = job.segments.first(where: { $0.speaker == sp })?.speakerName ?? sp
                                    return (sp, name, SPEAKER_COLORS[i % SPEAKER_COLORS.count])
                                }
                                let isHighlighted = audioPlayer.isLoaded &&
                                    seg.start <= audioPlayer.currentTime &&
                                    audioPlayer.currentTime < seg.end
                                if entry.showBreak {
                                    HStack {
                                        Text("…")
                                            .font(.system(size: 13))
                                            .foregroundColor(.secondary)
                                            .padding(.leading, 78)
                                            .padding(.vertical, 4)
                                        Spacer()
                                    }
                                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                }
                                SegmentRow(
                                    segment: seg,
                                    color: SPEAKER_COLORS[spIdx % SPEAKER_COLORS.count],
                                    speakerEntries: speakerEntries,
                                    searchText: entry.isMatch ? searchText : "",
                                    isHighlighted: isHighlighted,
                                    isContext: !entry.isMatch,
                                    onReassign: entry.isMatch ? { newSpeaker in reassignSegment(seg, to: newSpeaker) } : nil,
                                    onSeek: audioPlayer.isLoaded ? { audioPlayer.seekAndPlay(to: $0) } : nil
                                )
                                .id(seg.id)
                                Divider().padding(.leading, 20)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: audioPlayer.currentTime) { time in
                        guard audioPlayer.isPlaying else { return }
                        if let seg = filteredSegments.first(where: { $0.start <= time && time < $0.end }) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(seg.id, anchor: .center)
                            }
                        }
                    }
                }

                // Mini audio player bar
                AudioPlayerBar(model: audioPlayer, onLinkFile: speakerMode ? linkAudioFile : nil)

            } else {
                // 2-minute block view (Local only)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(timeBlocks, id: \.start) { block in
                            TimeBlockRow(label: block.label, text: block.text, searchText: searchText)
                            Divider().padding(.leading, 20)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(job.fileName)
        .sheet(isPresented: $showingExport) {
            ExportView(job: job)
        }
        .onAppear {
            if let bookmark = job.audioBookmark {
                audioPlayer.load(bookmark: bookmark)
            }
        }
        .onDisappear {
            audioPlayer.cleanup()
        }
    }

    private func linkAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie,
            UTType(filenameExtension: "m4a") ?? .audio,
            UTType(filenameExtension: "mp3") ?? .audio]
        panel.canChooseFiles       = true
        panel.canChooseDirectories = false
        panel.message = "Välj den ljudfil som hör till detta transkript"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        job.audioBookmark = bookmark
        store?.update(job: job)
        audioPlayer.load(bookmark: bookmark)
    }

    private func copyAllText() {
        let text: String
        if speakerMode {
            text = job.segments
                .map { "[\($0.formattedStart)] \($0.speakerName): \($0.text)" }
                .joined(separator: "\n")
        } else {
            text = timeBlocks
                .map { "[\($0.label)] \($0.text)" }
                .joined(separator: "\n\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func renameSpeaker(_ speaker: String, to name: String) {
        for i in job.segments.indices {
            if job.segments[i].speaker == speaker {
                job.segments[i].speakerName = name
            }
        }
    }

    private func reassignSegment(_ seg: TranscriptSegment, to newSpeaker: String) {
        guard let idx = job.segments.firstIndex(where: { $0.id == seg.id }) else { return }
        let newName = job.segments.first(where: { $0.speaker == newSpeaker })?.speakerName ?? newSpeaker
        job.segments[idx].speaker     = newSpeaker
        job.segments[idx].speakerName = newName
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Time block row (Local mode)

struct TimeBlockRow: View {
    let label: String
    let text: String
    let searchText: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)

            Text(highlightedText(text, query: searchText))
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    func highlightedText(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.withAlphaComponent(0.4)
            attributed[range].foregroundColor = .primary
            searchRange = range.upperBound..<attributed.endIndex
        }
        return attributed
    }
}

// MARK: - Stat badge

struct StatBadge: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 15, weight: .semibold))
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}

// MARK: - Speaker rename chip

struct SpeakerRenameChip: View {
    let speaker: String
    let color: Color
    @Binding var name: String
    let isActive: Bool
    let onTap: () -> Void

    @State private var isEditing = false
    @State private var editText  = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            if isEditing {
                TextField("", text: $editText, onCommit: {
                    name = editText.isEmpty ? speaker : editText
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 90)
                .onAppear { editText = name }
            } else {
                Text(name).font(.system(size: 12, weight: .medium))
                Button(action: { isEditing = true }) {
                    Image(systemName: "pencil").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? color.opacity(0.15) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(99)
        .overlay(Capsule().stroke(isActive ? color : Color.clear, lineWidth: 1.5))
        .onTapGesture { onTap() }
    }
}

// MARK: - Segment row (Cloud / speaker mode)

struct SegmentRow: View {
    let segment: TranscriptSegment
    let color: Color
    var speakerEntries: [(id: String, name: String, color: Color)] = []
    let searchText: String
    var isHighlighted: Bool = false
    var isContext: Bool = false
    var onReassign: ((String) -> Void)? = nil
    var onSeek: ((Double) -> Void)? = nil

    @State private var showingReassign = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(segment.formattedStart)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(onSeek != nil ? .accentColor : .secondary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)
                .onTapGesture { onSeek?(segment.start) }

            // Talaretikett: vänsterklick = nästa talare, högerklick = välj direkt
            if onReassign != nil {
                Text(segment.speakerName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 90, alignment: .leading)
                    .padding(.top, 2)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(color.opacity(0.08))
                    .cornerRadius(4)
                    .onTapGesture { cycleSpeaker() }
                    .popover(isPresented: $showingReassign, arrowEdge: .bottom) {
                        ReassignPopover(
                            currentSpeaker: segment.speaker,
                            entries: speakerEntries,
                            onSelect: { newSpeaker in
                                showingReassign = false
                                onReassign?(newSpeaker)
                            }
                        )
                    }
                    .contextMenu {
                        ForEach(speakerEntries, id: \.id) { entry in
                            Button(action: { onReassign?(entry.id) }) {
                                HStack {
                                    Text(entry.name)
                                    if entry.id == segment.speaker {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
            } else {
                Text(segment.speakerName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 90, alignment: .leading)
                    .padding(.top, 2)
            }

            Text(highlightedText(segment.text, query: searchText))
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(isContext ? .secondary : .primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(isHighlighted ? Color.accentColor.opacity(0.07) : Color.clear)
        .opacity(isContext ? 0.7 : 1.0)
        .contentShape(Rectangle())
    }

    private func cycleSpeaker() {
        guard let reassign = onReassign, !speakerEntries.isEmpty else { return }
        let ids = speakerEntries.map(\.id)
        let currentIdx = ids.firstIndex(of: segment.speaker) ?? 0
        let nextIdx = (currentIdx + 1) % ids.count
        reassign(ids[nextIdx])
    }

    func highlightedText(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.withAlphaComponent(0.4)
            attributed[range].foregroundColor = .primary
            searchRange = range.upperBound..<attributed.endIndex
        }
        return attributed
    }
}

// MARK: - Reassign popover

struct ReassignPopover: View {
    let currentSpeaker: String
    let entries: [(id: String, name: String, color: Color)]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Byt talare")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(entries, id: \.id) { entry in
                let isCurrent = entry.id == currentSpeaker
                Button(action: { onSelect(entry.id) }) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(entry.color)
                            .frame(width: 8, height: 8)
                        Text(entry.name)
                            .font(.system(size: 13))
                        Spacer()
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
        .frame(minWidth: 170)
    }
}

// MARK: - Export

struct ExportView: View {
    let job: TranscriptJob
    @Environment(\.dismiss) var dismiss
    @State private var format = "txt"

    var body: some View {
        VStack(spacing: 20) {
            Text("Exportera transkript")
                .font(.system(size: 16, weight: .semibold))

            Picker("Format", selection: $format) {
                Text("Textfil (.txt)").tag("txt")
                Text("Undertexter (.srt)").tag("srt")
                Text("JSON (.json)").tag("json")
            }
            .pickerStyle(.radioGroup)
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Avbryt") { dismiss() }
                Button("Spara fil") { saveFile() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 300)
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(job.fileName).\(format)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content: String
        switch format {
        case "srt":  content = job.toSRT()
        case "json":
            let data = (try? JSONEncoder().encode(job.segments)) ?? Data()
            content = String(data: data, encoding: .utf8) ?? ""
        default:     content = job.toTXT()
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
        dismiss()
    }
}
