import Foundation
import AVFoundation

// MARK: - WhisperService (Cloud)
// Anropar OpenAI Whisper API. Delar automatiskt upp filer > 24 MB i bitar.

class WhisperService: ObservableObject {
    @Published var progress:   Double = 0
    @Published var statusText: String = ""
    @Published var isRunning:  Bool   = false

    private let maxBytes       = 24 * 1024 * 1024   // 24 MB säkerhetsmarginal mot OpenAI:s 25 MB
    private let minChunkSec    = 30.0               // minst 30 s per bit
    private let maxChunkSec    = 600.0              // aldrig längre än 10 min per bit

    private var currentTask: Task<Void, Never>?

    // MARK: - Avbryt

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning  = false
        progress   = 0
        statusText = ""
    }

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "openai_api_key") ?? ""
    }

    // MARK: - Transkribera

    func transcribe(
        url: URL,
        language: String,
        speakerCount: Int = 0,
        completion: @escaping (Result<[TranscriptSegment], Error>) -> Void
    ) {
        guard !apiKey.isEmpty else {
            completion(.failure(WhisperError.missingAPIKey))
            return
        }

        isRunning = true
        progress  = 0

        currentTask = Task {
            do {
                await self.setStatus("Förbereder ljudfil…", progress: 0.03)
                let audioURL = try await convertToAudioOnly(url: url)
                defer { if audioURL != url { try? FileManager.default.removeItem(at: audioURL) } }

                let fileSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let singleAsset = AVURLAsset(url: audioURL)
                let audioDuration = try await singleAsset.load(.duration).seconds
                let segments: [TranscriptSegment]

                let raw: [OpenAISegment]
                if fileSize > maxBytes || audioDuration > 1380 {
                    raw = try await transcribeInChunksRaw(audioURL: audioURL, language: language)
                } else {
                    await setStatus("Skickar till OpenAI Whisper…", progress: 0.10)
                    raw = try await callWhisperAPI(audioURL: audioURL, language: language,
                                                   timeOffset: 0, chunkDuration: audioDuration)
                }

                await setStatus("Analyserar talare med GPT-4o…", progress: 0.87)
                let assigned = try await assignSpeakersWithGPT(raw, speakerCount: speakerCount)

                await setStatus("Tvättar språket med GPT-4o…", progress: 0.93)
                segments = try await polishTranscript(assigned)

                await setStatus("Klart!", progress: 1.0)
                await MainActor.run {
                    self.isRunning = false
                    completion(.success(segments))
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Dela upp i bitar (pausbaserad)

    private func transcribeInChunksRaw(audioURL: URL, language: String) async throws -> [OpenAISegment] {
        let asset    = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds

        await setStatus("Analyserar tystnadspunkter…", progress: 0.07)
        let splitPoints = try await findSplitPoints(asset: asset, totalDuration: duration)
        let nChunks = splitPoints.count - 1

        await setStatus("Delar upp filen i \(nChunks) delar…", progress: 0.09)

        // Exportera alla bitar sekventiellt (samma asset kan inte läsas parallellt)
        var chunkURLs: [(url: URL, start: Double, duration: Double)] = []
        for i in 0..<nChunks {
            let startSec = splitPoints[i]
            let endSec   = splitPoints[i + 1]
            let chunkURL = try await exportChunk(asset: asset, start: startSec, end: endSec, index: i)
            chunkURLs.append((chunkURL, startSec, endSec - startSec))
        }

        // Transkribera alla bitar parallellt mot OpenAI
        await setStatus("Transkriberar \(nChunks) delar parallellt…", progress: 0.10)
        var ordered = Array(repeating: [OpenAISegment](), count: nChunks)
        try await withThrowingTaskGroup(of: (Int, [OpenAISegment]).self) { group in
            for (i, chunk) in chunkURLs.enumerated() {
                group.addTask {
                    defer { try? FileManager.default.removeItem(at: chunk.url) }
                    return try await (i, self.callWhisperAPI(
                        audioURL: chunk.url, language: language,
                        timeOffset: chunk.start, chunkDuration: chunk.duration))
                }
            }
            var done = 0
            for try await (i, segs) in group {
                ordered[i] = segs
                done += 1
                await setStatus("Transkriberat \(done) av \(nChunks) delar…", progress: 0.10 + 0.75 * Double(done) / Double(nChunks))
            }
        }
        return ordered.flatMap { $0 }
    }

    // MARK: - Hitta delningspunkter baserade på tystnad

    /// Returnerar en lista av tidsstämplar [0.0, …, duration] som definierar bitgränserna.
    /// Delar vid naturliga pauser (låg RMS), men aldrig kortare än minChunkSec per bit.
    private func findSplitPoints(asset: AVURLAsset, totalDuration: Double) async throws -> [Double] {

        // Läs PCM-sampel via AVAudioFile — hanterar alla format utan att krascha
        guard let audioFile = try? AVAudioFile(forReading: asset.url) else {
            return fallbackSplits(totalDuration: totalDuration)
        }

        let srcFormat   = audioFile.processingFormat
        let srcRate     = srcFormat.sampleRate
        // Läs i block om 0.25 s för RMS-analys
        let windowFrames = AVAudioFrameCount(srcRate * 0.25)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: windowFrames) else {
            return fallbackSplits(totalDuration: totalDuration)
        }

        var rmsFrames: [(time: Double, rms: Float)] = []
        var sampleIndex: Double = 0

        while true {
            do { try audioFile.read(into: buffer, frameCount: windowFrames) } catch { break }
            guard buffer.frameLength > 0 else { break }

            // Beräkna RMS över alla kanaler
            var sumSq: Float = 0
            let n = Int(buffer.frameLength)
            if let ch0 = buffer.floatChannelData?[0] {
                for i in 0..<n { sumSq += ch0[i] * ch0[i] }
            }
            let rms = sqrt(sumSq / Float(max(n, 1)))
            let t   = sampleIndex / srcRate
            rmsFrames.append((t, rms))
            sampleIndex += Double(buffer.frameLength)

            if buffer.frameLength < windowFrames { break }  // sista blocket
        }

        if rmsFrames.isEmpty { return fallbackSplits(totalDuration: totalDuration) }

        // Beräkna dynamisk tröskel: medelvärde × 0.4 (anpassar sig till olika mikrofoner)
        let avgRMS    = rmsFrames.map(\.rms).reduce(0, +) / Float(rmsFrames.count)
        let threshold = avgRMS * 0.4

        // Hitta tystnadsfönster (≥ 0.5 s sammanhängande)
        let minSilenceFrames = Int(0.5 / 0.25)   // 2 fönster
        var silenceRanges: [(start: Double, end: Double)] = []
        var silenceStart: Double? = nil

        for frame in rmsFrames {
            if frame.rms < threshold {
                if silenceStart == nil { silenceStart = frame.time }
            } else {
                if let s = silenceStart {
                    let duration = frame.time - s
                    if duration >= Double(minSilenceFrames) * 0.25 {
                        silenceRanges.append((s, frame.time))
                    }
                    silenceStart = nil
                }
            }
        }
        if let s = silenceStart {
            silenceRanges.append((s, totalDuration))
        }

        // Välj delningspunkter: mitt i varje tystnad, med krav ≥ minChunkSec per bit
        var splits: [Double] = [0.0]
        var chunkStart = 0.0

        for silence in silenceRanges {
            let midpoint    = (silence.start + silence.end) / 2.0
            let chunkLength = midpoint - chunkStart

            // Respektera maxChunkSec: dela även om ingen tystnad hittats
            if chunkLength >= maxChunkSec {
                splits.append(midpoint)
                chunkStart = midpoint
                continue
            }
            // Dela bara om biten är tillräckligt lång
            if chunkLength >= minChunkSec {
                splits.append(midpoint)
                chunkStart = midpoint
            }
        }

        // Om sista biten är < minChunkSec: slå ihop med föregående
        let lastChunkLen = totalDuration - chunkStart
        if lastChunkLen < minChunkSec && splits.count > 1 {
            splits.removeLast()
        }

        splits.append(totalDuration)
        return splits
    }

    private func fallbackSplits(totalDuration: Double) -> [Double] {
        var pts = stride(from: 0.0, to: totalDuration, by: maxChunkSec).map { $0 }
        pts.append(totalDuration)
        return pts
    }

    // MARK: - Exportera en bit

    private func exportChunk(asset: AVURLAsset, start: Double, end: Double, index: Int) async throws -> URL {
        let comp   = AVMutableComposition()
        let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                          preferredTrackID: kCMPersistentTrackID_Invalid)

        guard let srcTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw WhisperError.conversionFailed
        }

        let cmStart  = CMTime(seconds: start, preferredTimescale: 44100)
        let cmEnd    = CMTime(seconds: end,   preferredTimescale: 44100)
        let range    = CMTimeRange(start: cmStart, end: cmEnd)
        try aTrack?.insertTimeRange(range, of: srcTrack, at: .zero)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk_\(index)_\(UUID().uuidString).m4a")

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw WhisperError.conversionFailed
        }
        session.outputURL      = outURL
        session.outputFileType = .m4a
        await session.export()

        guard session.status == .completed else { throw WhisperError.conversionFailed }
        return outURL
    }

    // MARK: - HTTP-anrop mot OpenAI

    private func callWhisperAPI(
        audioURL: URL,
        language: String,
        timeOffset: Double,
        chunkDuration: Double
    ) async throws -> [OpenAISegment] {

        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request  = URLRequest(url: endpoint)
        request.httpMethod      = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: audioURL)
        let ext  = audioURL.pathExtension.lowercased()
        var body = Data()

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\n"
        body += "Content-Type: audio/\(ext)\r\n\r\n"
        body.append(data)
        body += "\r\n"

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
        body += "gpt-4o-transcribe\r\n"

        if language != "auto" {
            body += "--\(boundary)\r\n"
            body += "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
            body += language + "\r\n"
        }

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n"
        body += "json\r\n"

        body += "--\(boundary)--\r\n"
        request.httpBody = body

        // Whisper API: försök upp till 3 gånger vid rate-limit (429) eller serverproblem (5xx)
        var lastError: Error = WhisperError.networkError
        for attempt in 1...3 {
            if attempt > 1 {
                let delay: UInt64 = attempt == 2 ? 20_000_000_000 : 40_000_000_000
                await setStatus("Rate-limit — väntar \(attempt == 2 ? 20 : 40) s innan nytt försök…", progress: self.progress)
                try? await Task.sleep(nanoseconds: delay)
            }

            let (responseData, response): (Data, URLResponse)
            do {
                (responseData, response) = try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
                continue
            }

            guard let http = response as? HTTPURLResponse else { throw WhisperError.networkError }

            if http.statusCode == 200 {
                let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: responseData)
                if let segs = decoded.segments, !segs.isEmpty {
                    return segs.map {
                        OpenAISegment(start: $0.start + timeOffset,
                                      end:   $0.end   + timeOffset,
                                      text:  $0.text)
                    }
                }
                guard let fullText = decoded.text, !fullText.isEmpty else {
                    let raw = String(data: responseData, encoding: .utf8) ?? ""
                    throw WhisperError.serverError("Tomt svar från OpenAI. Råsvar: \(raw.prefix(200))")
                }
                return splitTextIntoSegments(fullText, audioDuration: chunkDuration, offset: timeOffset)
            }

            let msg = String(data: responseData, encoding: .utf8) ?? "Okänt fel"

            // Kolla om det är slut på kredit — permanent fel, försök inte igen
            if http.statusCode == 429, msg.contains("insufficient_quota") {
                throw WhisperError.serverError("OpenAI-kontot har slut på krediter. Fyll på under platform.openai.com → Billing.")
            }

            // Rate-limit eller tillfälligt serverfel → försök igen
            if http.statusCode == 429 || http.statusCode >= 500 {
                lastError = WhisperError.serverError("OpenAI-fel \(http.statusCode): \(msg)")
                continue
            }

            throw WhisperError.serverError("OpenAI-fel \(http.statusCode): \(msg)")
        }

        throw lastError
    }

    // MARK: - Fallback: fördela text jämnt när timestamps saknas

    private func splitTextIntoSegments(_ text: String, audioDuration: Double, offset: Double) -> [OpenAISegment] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { return [] }
        let segDur = audioDuration / Double(sentences.count)
        return sentences.enumerated().map { i, s in
            let start = offset + Double(i) * segDur
            return OpenAISegment(start: start, end: start + segDur, text: s + ".")
        }
    }

    // MARK: - Konvertera till ljud-only M4A

    private func convertToAudioOnly(url: URL) async throws -> URL {
        let ext       = url.pathExtension.lowercased()
        let fileSize  = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        let audioOnly = ["mp3", "wav", "flac", "aac"]

        // Rent ljudformat och litet — skicka direkt
        if audioOnly.contains(ext) && fileSize < maxBytes { return url }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        let asset  = AVURLAsset(url: url)

        // Bygg en komposition med enbart ljudspåret
        let comp   = AVMutableComposition()
        let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                          preferredTrackID: kCMPersistentTrackID_Invalid)

        if let srcTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let dur   = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: dur)
            try? aTrack?.insertTimeRange(range, of: srcTrack, at: .zero)
        }

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw WhisperError.conversionFailed
        }
        session.outputURL      = outURL
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else { throw WhisperError.conversionFailed }
        return outURL
    }

    // MARK: - Talaridentifiering via GPT-4o (chunked)

    private let gptChunkSize = 150  // segment per GPT-4o-anrop

    private func assignSpeakersWithGPT(_ segments: [OpenAISegment], speakerCount: Int) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TranscriptSegment] = []
        var chunkStart = 0

        while chunkStart < segments.count {
            let chunkEnd = min(chunkStart + gptChunkSize, segments.count)
            let chunk    = Array(segments[chunkStart..<chunkEnd])
            let context  = Array(result.suffix(5))   // sista 5 redan tilldelade segment som kontext

            let chunkResult = try await assignSpeakersChunk(
                chunk,
                globalOffset: chunkStart,
                speakerCount: speakerCount,
                previousContext: context
            )
            result.append(contentsOf: chunkResult)
            chunkStart = chunkEnd

            let pct = 0.87 + 0.06 * Double(chunkStart) / Double(segments.count)
            let part = segments.count > gptChunkSize
                ? " (del \(chunkStart / gptChunkSize) av \((segments.count + gptChunkSize - 1) / gptChunkSize))"
                : ""
            await setStatus("Analyserar talare med GPT-4o\(part)…", progress: pct)
        }

        return result
    }

    private func assignSpeakersChunk(
        _ chunk: [OpenAISegment],
        globalOffset: Int,
        speakerCount: Int,
        previousContext: [TranscriptSegment]
    ) async throws -> [TranscriptSegment] {

        let lines = chunk.enumerated().map { i, seg in
            let t = Int(seg.start)
            return "[\(globalOffset + i)] \(t/60):\(String(format: "%02d", t%60)) \(seg.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")

        let speakerHint = speakerCount > 0
            ? "Det är exakt \(speakerCount) talare i hela inspelningen."
            : "Antalet talare är okänt — använd det antal som verkar rimligt."

        var contextHint = ""
        if !previousContext.isEmpty {
            let ctxLines = previousContext.map { "\($0.speakerName): \($0.text.prefix(80))" }.joined(separator: "\n")
            contextHint = "\n\nDe närmast föregående segmenten var:\n\(ctxLines)\nFortsätt med samma talar-numrering (0-baserad) och identifiera talarna konsekvent."
        }

        let systemPrompt = """
        Du är en expert på talaridentifiering. Givet ett transkript med numrerade segment, tilldela varje segment ett talarnummer (0-baserat).
        \(speakerHint)\(contextHint)
        Analysera samtalsdynamiken: vem ställer frågor, vem svarar, ton, ämnesbyten, meningsbyggnad.
        Svara ENBART med ett JSON-objekt där nyckeln är segmentets globala index (sträng) och värdet är talarnumret (heltal). Exempel: {"\(globalOffset)":0,"\(globalOffset+1)":1}
        """

        let body: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": lines]
            ]
        ]

        let text = try await callGPT(body: body, timeout: 120)
        let jsonStr: String
        if let s = text.range(of: "{"), let e = text.range(of: "}", options: .backwards) {
            jsonStr = String(text[s.lowerBound..<e.upperBound])
        } else { jsonStr = text }

        let assignments = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Int]) ?? [:]

        // Bygg konsistenta talarnamn för detta chunk
        let usedSpeakers = Array(Set(assignments.values)).sorted()
        var speakerNames: [Int: String] = [:]
        for (rank, spNum) in usedSpeakers.enumerated() {
            speakerNames[spNum] = "Talare \(rank + 1)"
        }

        return chunk.enumerated().map { i, seg in
            let key    = "\(globalOffset + i)"
            let spNum  = assignments[key] ?? 0
            let spName = speakerNames[spNum] ?? "Talare 1"
            return TranscriptSegment(
                start:       seg.start,
                end:         seg.end,
                speaker:     "speaker_\(spNum)",
                speakerName: spName,
                text:        seg.text.trimmingCharacters(in: .whitespaces)
            )
        }
    }

    // MARK: - Språktvättning via GPT-4o (chunked)

    private func polishTranscript(_ segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }

        var chunks: [(offset: Int, chunk: [TranscriptSegment])] = []
        var i = 0
        while i < segments.count {
            let end = min(i + gptChunkSize, segments.count)
            chunks.append((i, Array(segments[i..<end])))
            i = end
        }

        await setStatus("Tvättar språket med GPT-4o…", progress: 0.93)
        var ordered = Array(repeating: [TranscriptSegment](), count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, [TranscriptSegment]).self) { group in
            for (idx, item) in chunks.enumerated() {
                group.addTask {
                    return try await (idx, self.polishChunk(item.chunk, globalOffset: item.offset))
                }
            }
            var done = 0
            for try await (idx, result) in group {
                ordered[idx] = result
                done += 1
                await setStatus("Tvättat \(done) av \(chunks.count) delar…", progress: 0.93 + 0.06 * Double(done) / Double(chunks.count))
            }
        }
        return ordered.flatMap { $0 }
    }

    private func polishChunk(_ chunk: [TranscriptSegment], globalOffset: Int) async throws -> [TranscriptSegment] {
        let lines = chunk.enumerated().map { i, seg in
            "[\(globalOffset + i)] \(seg.text)"
        }.joined(separator: "\n")

        let systemPrompt = """
        Du är en expert på att redigera talspråk till läsbar text på svenska. \
        Du får en numrerad lista med transkriberade segment från ett samtal.
        Din uppgift:
        • Rätta uppenbara transkriptionsfel (förväxlade ord, felstavningar).
        • Ta bort utfyllnadsord och stakningar (öh, eh, liksom, alltså när det används som utfyllnad, mm, hmm).
        • Lägg till punktuation och stor bokstav där det saknas.
        • Behåll talspråklig ton och meningsinnehåll — ändra INTE vad personen faktiskt säger.
        • Slå INTE ihop segment — varje index ska ha exakt ett svar.
        Svara ENBART med ett JSON-objekt: {"\(globalOffset)":"polerad text",...}
        """

        let body: [String: Any] = [
            "model": "gpt-4o",
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": lines]
            ]
        ]

        let text = try await callGPT(body: body, timeout: 180)
        let jsonStr: String
        if let s = text.range(of: "{"), let e = text.range(of: "}", options: .backwards) {
            jsonStr = String(text[s.lowerBound..<e.upperBound])
        } else { jsonStr = text }

        let polished = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: String]) ?? [:]

        return chunk.enumerated().map { i, seg in
            var updated = seg
            let key = "\(globalOffset + i)"
            if let clean = polished[key], !clean.isEmpty { updated.text = clean }
            return updated
        }
    }

    // MARK: - Gemensamt GPT-anrop

    private func callGPT(body: [String: Any], timeout: TimeInterval) async throws -> String {
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request  = URLRequest(url: endpoint)
        request.httpMethod      = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = WhisperError.networkError
        for attempt in 1...3 {
            if attempt > 1 {
                let delay: UInt64 = attempt == 2 ? 20_000_000_000 : 40_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }

            let (data, response): (Data, URLResponse)
            do { (data, response) = try await URLSession.shared.data(for: request) }
            catch { lastError = error; continue }

            guard let http = response as? HTTPURLResponse else { throw WhisperError.networkError }
            if http.statusCode == 200 {
                let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let content = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
                return (content?["content"] as? String) ?? ""
            }

            let msg = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 429, msg.contains("insufficient_quota") {
                throw WhisperError.serverError("OpenAI-kontot har slut på krediter. Fyll på under platform.openai.com → Billing.")
            }
            if http.statusCode == 429 || http.statusCode >= 500 {
                lastError = WhisperError.serverError("GPT-4o-fel \(http.statusCode): \(msg)")
                continue
            }
            throw WhisperError.serverError("GPT-4o-fel \(http.statusCode): \(msg)")
        }
        throw lastError
    }

    // MARK: - Talaridentifiering pausbaserad (fallback)

    private func assignSpeakers(_ segments: [OpenAISegment], speakerCount: Int = 0) -> [TranscriptSegment] {
        // speakerCount == 0 means unknown — cycle freely up to 8
        let maxSpeakers  = speakerCount > 0 ? speakerCount : 8
        var speakerIndex = 0
        var lastEnd      = -999.0
        var result: [TranscriptSegment] = []

        for seg in segments {
            if seg.start - lastEnd > 1.5 {
                speakerIndex = (speakerIndex + 1) % maxSpeakers
            }
            lastEnd = seg.end
            result.append(TranscriptSegment(
                start:       seg.start,
                end:         seg.end,
                speaker:     "speaker_\(speakerIndex)",
                speakerName: "Talare \(speakerIndex + 1)",
                text:        seg.text.trimmingCharacters(in: .whitespaces)
            ))
        }
        return result
    }

    // MARK: - Hjälpare

    private func setStatus(_ text: String, progress: Double) async {
        await MainActor.run {
            self.statusText = text
            self.progress   = progress
        }
    }
}

// MARK: - Svarsmodeller

private struct OpenAIResponse: Decodable {
    let segments: [OpenAISegment]?
    let text: String?
}

private struct OpenAISegment: Decodable {
    let start: Double
    let end:   Double
    let text:  String
}

// MARK: - Fel

enum WhisperError: LocalizedError {
    case networkError
    case conversionFailed
    case serverError(String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .networkError:         return "Nätverksfel — kontrollera din internetanslutning."
        case .conversionFailed:     return "Kunde inte konvertera ljudfilen."
        case .serverError(let msg): return msg
        case .missingAPIKey:        return "OpenAI API-nyckel saknas. Ange den i Inställningar."
        }
    }
}

// MARK: - Data-hjälpare

private func += (lhs: inout Data, rhs: String) {
    if let d = rhs.data(using: .utf8) { lhs.append(d) }
}
