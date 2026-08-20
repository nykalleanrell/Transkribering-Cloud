import Foundation

// MARK: - Models

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var speaker: String
    var speakerName: String
    var text: String

    var formattedStart: String {
        let m = Int(start) / 60
        let s = Int(start) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct TranscriptJob: Codable, Identifiable, Hashable {
    static func == (lhs: TranscriptJob, rhs: TranscriptJob) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var id = UUID()
    var fileName: String
    var createdAt: Date
    var userEmail: String
    var segments: [TranscriptSegment]
    var language: String
    var durationSeconds: Double
    var audioBookmark: Data? = nil

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "sv_SE")
        return f.string(from: createdAt)
    }

    var formattedDuration: String {
        let m = Int(durationSeconds) / 60
        let s = Int(durationSeconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    var wordCount: Int {
        segments.flatMap { $0.text.split(separator: " ") }.count
    }

    var speakerCount: Int {
        Set(segments.map { $0.speaker }).count
    }

    // Export as plain text
    func toTXT(useNames: Bool = true) -> String {
        segments.map { seg in
            let name = useNames ? seg.speakerName : seg.speaker
            return "[\(seg.formattedStart)] \(name): \(seg.text)"
        }.joined(separator: "\n")
    }

    // Export as SRT
    func toSRT() -> String {
        var result = ""
        for (i, seg) in segments.enumerated() {
            result += "\(i + 1)\n"
            result += "\(srtTime(seg.start)) --> \(srtTime(seg.end))\n"
            result += "\(seg.speakerName): \(seg.text)\n\n"
        }
        return result
    }

    private func srtTime(_ t: Double) -> String {
        let h  = Int(t) / 3600
        let m  = (Int(t) % 3600) / 60
        let s  = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

// MARK: - Storage

class TranscriptStore: ObservableObject {
    @Published var jobs: [TranscriptJob] = []
    private(set) var userEmail: String
    private let retentionDays: Int?     // nil = behåll för evigt

    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Transkribering")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(userEmail.replacingOccurrences(of: "@", with: "_")).json")
    }

    init(userEmail: String, retentionDays: Int? = nil) {
        self.userEmail     = userEmail
        self.retentionDays = retentionDays
        if !userEmail.isEmpty { load() }
    }

    /// Byt användare och ladda om historiken — anropas från ContentView.onAppear.
    func reinitialize(userEmail: String) {
        guard self.userEmail != userEmail else { return }
        self.userEmail = userEmail
        load()
    }

    func save(job: TranscriptJob) {
        jobs.insert(job, at: 0)
        persist()
    }

    /// Returnerar hur många dagar kvar ett jobb har, eller nil om ingen gräns finns.
    func daysRemaining(for job: TranscriptJob) -> Int? {
        guard let days = retentionDays else { return nil }
        let expiry   = Calendar.current.date(byAdding: .day, value: days, to: job.createdAt)!
        let remaining = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        return max(0, remaining)
    }

    func delete(job: TranscriptJob) {
        jobs.removeAll { $0.id == job.id }
        persist()
    }

    func update(job: TranscriptJob) {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
            persist()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode([TranscriptJob].self, from: data)
        else { return }
        jobs = loaded
        purgeExpired()
    }

    private func purgeExpired() {
        guard let days = retentionDays else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let before = jobs.count
        jobs = jobs.filter { $0.createdAt > cutoff }
        if jobs.count != before { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: storageURL)
        }
    }
}
