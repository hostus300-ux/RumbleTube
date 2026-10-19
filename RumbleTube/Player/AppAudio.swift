import AVFoundation

/// Audio etiquette: browsing never touches whatever the user is already listening to.
/// We only take over audio when a video actually plays with sound, and hand it back afterwards.
enum AppAudio {
    private static var session: AVAudioSession { .sharedInstance() }
    private(set) static var ownsAudio = false

    /// Default state: mix with (and never interrupt) other apps' audio.
    static func browsing() {
        if ownsAudio {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudio = false
        }
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    }

    /// A video is playing with sound: become the main audio (background play, lock screen, PiP).
    static func takeOver() {
        guard !ownsAudio else { return }
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        ownsAudio = true
    }

    /// Video stopped/closed: let the user's music or podcast resume.
    static func release() { browsing() }

    static var otherAudioPlaying: Bool { session.isOtherAudioPlaying }
}
