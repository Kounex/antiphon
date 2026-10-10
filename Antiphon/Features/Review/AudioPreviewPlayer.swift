import AVFoundation
import Observation

/// Plays one catalog preview at a time.
@MainActor
@Observable
final class AudioPreviewPlayer {
    private(set) var playingURL: URL?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        player?.play()
        playingURL = url
    }

    func stop() {
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playingURL = nil
    }
}
