import AVFoundation
import SwiftUI

final class AudioPlayerModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double    = 0
    @Published var isPlaying: Bool     = false
    @Published var isLoaded: Bool      = false
    @Published var fileName: String    = ""
    @Published var linkError: String?  = nil

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var securityScopedURL: URL?
    private var durationTask: Task<Void, Never>?

    // MARK: - Load from security-scoped bookmark

    func load(bookmark: Data) {
        cleanup()
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            linkError = "Kunde inte lösa upp bokmärket för ljudfilen."
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            linkError = "Saknar behörighet att öppna filen."
            return
        }
        securityScopedURL = url
        fileName = url.lastPathComponent

        let item = AVPlayerItem(url: url)
        let p    = AVPlayer(playerItem: item)
        player   = p

        // Ladda duration asynkront — spara tasken så vi kan avbryta den vid cleanup
        durationTask = Task { @MainActor [weak self] in
            if let dur = try? await item.asset.load(.duration), dur.isNumeric, !Task.isCancelled {
                self?.duration = dur.seconds
            }
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.isLoaded else { return }
            self.currentTime = time.seconds
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying   = false
            self?.currentTime = 0
            self?.player?.seek(to: .zero)
        }

        isLoaded  = true
        linkError = nil
    }

    // MARK: - Playback controls

    func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else         { player.play();  isPlaying = true  }
    }

    func seek(to time: Double) {
        let t = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func seekAndPlay(to time: Double) {
        seek(to: time)
        if !isPlaying, let player { player.play(); isPlaying = true }
    }

    // MARK: - Cleanup

    func cleanup() {
        durationTask?.cancel()
        durationTask = nil
        isLoaded = false      // stäng av tidsobservern tidigt via guard i callbacken
        player?.pause()
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
        securityScopedURL?.stopAccessingSecurityScopedResource()
        player            = nil
        timeObserver      = nil
        endObserver       = nil
        securityScopedURL = nil
        isPlaying         = false
        currentTime       = 0
        duration          = 0
        fileName          = ""
        linkError         = nil
    }

    deinit {
        durationTask?.cancel()
        player?.pause()
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}

// MARK: - Mini player bar

struct AudioPlayerBar: View {
    @ObservedObject var model: AudioPlayerModel
    var onLinkFile: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                // Play / pause
                Button(action: { model.togglePlay() }) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isLoaded)

                // Current time
                Text(formatTime(model.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 42, alignment: .trailing)

                // Seek bar
                Slider(
                    value: Binding(
                        get: { model.duration > 0 ? model.currentTime / model.duration : 0 },
                        set: { model.seek(to: $0 * model.duration) }
                    )
                )
                .disabled(!model.isLoaded)

                // Duration
                Text(formatTime(model.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 42, alignment: .leading)

                // Filename or link button
                if model.isLoaded {
                    Text(model.fileName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .trailing)
                } else if let linkFile = onLinkFile {
                    Button(action: linkFile) {
                        Label("Koppla ljudfil", systemImage: "waveform.badge.plus")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    if let err = model.linkError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
