//
// AudioManager.swift
// Spling
//
import AVFoundation

/// Plays short UI sounds (the "Spling ding" on successful order).
/// Uses AVAudioPlayer so the sound is not affected by the ringer switch —
/// this mirrors the behaviour of payment apps like Apple Pay.
final class AudioManager {
    static let shared = AudioManager()
    private init() { preparePlayer() }

    private var player: AVAudioPlayer?

    // MARK: - Setup

    private func preparePlayer() {
        guard let url = Bundle.main.url(
            forResource: AppConfig.Audio.splingDingFile,
            withExtension: AppConfig.Audio.splingDingExtension
        ) else {
            // Sound file not present — fail silently in production,
            // log in debug so the developer knows to add the asset.
            #if DEBUG
            print("[AudioManager] ⚠️ Missing sound file: \(AppConfig.Audio.splingDingFile).\(AppConfig.Audio.splingDingExtension)")
            #endif
            return
        }

        do {
            // Use .ambient so the sound mixes with background music
            try AVAudioSession.sharedInstance().setCategory(
                .ambient,
                mode: .default,
                options: .mixWithOthers
            )
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.volume = 0.6
        } catch {
            #if DEBUG
            print("[AudioManager] AVAudioSession error: \(error)")
            #endif
        }
    }

    // MARK: - Playback

    /// Plays the confirmation sound when an order is successfully placed.
    func playSplingDing() {
        guard let player else { return }
        if player.isPlaying { player.stop() }
        player.currentTime = 0
        player.play()
    }
}
