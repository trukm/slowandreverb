import UIKit
import AVFoundation
import UniformTypeIdentifiers
import MediaPlayer // Needed for background media controls and now playing info
import SwiftUI // Added for Canvas Preview support
import UserNotifications

// MARK: - 1. Audio Engine Logic

/// Custom errors for the audio export process.
enum ExportError: Error, LocalizedError {
    case noAudioFileLoaded
    case exportInProgress
}

/// Manages the AVAudioEngine and applies real-time audio effects (Tempo and Reverb).
class AudioProcessor {
    // MARK: Audio Graph Components

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch() // Controls playback speed (rate) and pitch
    private let varispeedNode = AVAudioUnitVarispeed() // High quality speed/pitch linking
    private var isVarispeedEnabled = false
    private let reverbNode = AVAudioUnitReverb()       // Applies environmental effects
    private let equalizerNode = AVAudioUnitEQ(numberOfBands: 3) // For Bass, Mids, Treble
    private var isPitchCorrectionEnabled = true
    private var needsReschedule = false
    private var isExporting = false // Flag to prevent concurrent exports
    
    private var audioFile: AVAudioFile?
    private var originalAudioFile: AVAudioFile?
    private var currentTitle: String?
    private var currentArtist: String?
    private var currentArtwork: UIImage?
    private var isPlaying = false
    
    // Properties for progress tracking
    private var audioFileLength: AVAudioFramePosition = 0
    private var audioSampleRate: Double = 0
    private var lastPlaybackPosition: AVAudioFramePosition = 0
    private var pausedPosition: AVAudioFramePosition? // Tracks position when paused
    
    // Property to hold the static Now Playing info
    private var nowPlayingInfo: [String: Any]?
    
    // Source Separation Properties
    private let sourceSeparationProcessor = SourceSeparationProcessor()
    private var isRemoveVocalsEnabled = false
    private var currentVocalLevel: Float = 100.0 // 0-100, where 100 = full vocals, 0 = instrumental
    
    // Closure to notify the UI of external playback changes (e.g., from remote commands)
    var onPlaybackStateChanged: (() -> Void)?
    var onPlaybackRateChanged: ((Float) -> Void)?
    
    // Closures for playlist navigation from remote commands
    var onNextTrack: (() -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onCyclePreset: (() -> Void)?

    // MARK: Initialization

    init() {
        configureAudioSession()
        setupInterruptionObserver() // Add interruption observer
        setupAudioEngine()
    }
    
    
    /// Configures the AVAudioSession for background playback.
    private func configureAudioSession() {
        do {
            // Set the category to .playback so audio continues when the screen is locked
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            print("AVAudioSession configured for background playback.")
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }

    /// Sets up the audio processing chain: Player -> Time/Pitch -> Reverb -> Output.
    private func setupAudioEngine() {
        setupRemoteTransportControls()
        engine.attach(playerNode)
        engine.attach(timePitchNode)
        engine.attach(varispeedNode)
        engine.attach(equalizerNode)
        engine.attach(reverbNode)

        // The audio format for the connection points must be consistent.
        let commonFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        connectNodes(format: commonFormat)

        // Initial setup for effects
        reverbNode.loadFactoryPreset(.mediumHall)
        reverbNode.wetDryMix = 0.0 // 0% wet (no reverb initially)
        timePitchNode.rate = 1.0   // Normal speed initially
        
        // Initial setup for equalizer bands
        // Band 0: Bass (Low Shelf)
        equalizerNode.bands[0].filterType = .lowShelf
        equalizerNode.bands[0].frequency = 250.0 // Hz
        equalizerNode.bands[0].gain = 0.0 // dB
        equalizerNode.bands[0].bypass = false
        // Band 1: Mids (Parametric)
        equalizerNode.bands[1].filterType = .parametric
        equalizerNode.bands[1].frequency = 1000.0 // Hz
        equalizerNode.bands[1].bandwidth = 1.0 // Octaves
        equalizerNode.bands[1].gain = 0.0 // dB
        equalizerNode.bands[1].bypass = false
        // Band 2: Treble (High Shelf)
        equalizerNode.bands[2].filterType = .highShelf
        equalizerNode.bands[2].frequency = 4000.0 // Hz
        equalizerNode.bands[2].gain = 0.0 // dB
        equalizerNode.bands[2].bypass = false

        do {
            try engine.start()
        } catch {
            print("Error starting AVAudioEngine: \(error.localizedDescription)")
        }
    }
    
    /// Connects the audio nodes based on the current mode (TimePitch or Varispeed).
    private func connectNodes(format: AVAudioFormat) {
        // Disconnect inputs to ensure clean reconfiguration
        engine.disconnectNodeInput(equalizerNode)
        
        if isVarispeedEnabled {
            engine.connect(playerNode, to: varispeedNode, format: format)
            engine.connect(varispeedNode, to: equalizerNode, format: format)
        } else {
            engine.connect(playerNode, to: timePitchNode, format: format)
            engine.connect(timePitchNode, to: equalizerNode, format: format)
        }
        
        engine.connect(equalizerNode, to: reverbNode, format: format)
        engine.connect(reverbNode, to: engine.mainMixerNode, format: format)
    }
    
    // MARK: File Loading and Playback

    /// Loads an audio file and extracts its metadata.
    func loadAudioFile(url: URL) -> (title: String, artist: String?, artwork: UIImage?)? {
        // Stop current playback and reset engine
        playerNode.stop()
        engine.stop()
        isPlaying = false
        
        do {
            self.audioFile = try AVAudioFile(forReading: url)
            self.originalAudioFile = self.audioFile
            guard let file = self.audioFile else { return nil }
            
            self.audioFileLength = file.length
            self.audioSampleRate = file.processingFormat.sampleRate
            self.lastPlaybackPosition = 0 // Reset position for new file
            self.pausedPosition = nil
            
            // Reconnect nodes with the audio file's processing format to ensure effects work correctly.
            let fileFormat = file.processingFormat
            // New chain: Player -> Time/Pitch -> EQ -> Reverb -> Output
            connectNodes(format: fileFormat)
            
            // Extract metadata (title and artwork)
            let asset = AVAsset(url: url)
            let metadata = asset.commonMetadata
            var songTitle: String?
            var artistName: String?
            var albumName: String?
            var artworkImage: UIImage?
            
            for item in metadata {
                // FIX: Use the full AVMetadataKey constants to avoid conflicts
                if item.commonKey == AVMetadataKey.commonKeyTitle, let title = item.stringValue {
                    songTitle = title
                } else if item.commonKey == AVMetadataKey.commonKeyArtist, let artist = item.stringValue {
                    artistName = artist
                } else if item.commonKey == AVMetadataKey.commonKeyAlbumName, let album = item.stringValue {
                    albumName = album
                } else if item.commonKey == AVMetadataKey.commonKeyArtwork, let data = item.dataValue {
                    artworkImage = UIImage(data: data)
                }
            }

            // Prepare the static "Now Playing" info once.
            self.nowPlayingInfo = [
                MPMediaItemPropertyTitle: songTitle ?? url.deletingPathExtension().lastPathComponent,
                MPMediaItemPropertyArtist: artistName,
                MPMediaItemPropertyAlbumTitle: albumName,
                MPMediaItemPropertyPlaybackDuration: getAudioDuration(),
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
                MPNowPlayingInfoPropertyPlaybackRate: 0.0  // Initially paused
            ]
            
            if let artwork = artworkImage {
                self.nowPlayingInfo?[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            }

            // Schedule the file to loop and prepare for playback
            playerNode.scheduleFile(file, at: nil) { [weak self] in // Schedule the whole file initially
                // This completion handler is called when the file has finished playing.
                // We need to reschedule it for the next playback.
                self?.needsReschedule = true
            }

            let title = songTitle ?? url.deletingPathExtension().lastPathComponent
            self.currentTitle = title
            self.currentArtist = artistName
            self.currentArtwork = artworkImage
            
            print("Audio file loaded: \(title)")
            
            // Immediately sync the now playing info to the lock screen
            DispatchQueue.main.async { [weak self] in
                self?.syncNowPlayingInfo()
            }
            
            self.isRemoveVocalsEnabled = false
            
            return (title: title, artist: artistName, artwork: artworkImage)
            
        } catch {
            print("Error loading audio file: \(error.localizedDescription)")
            self.audioFile = nil
            self.nowPlayingInfo = nil // Clear info on failure
            self.currentTitle = nil
            self.currentArtist = nil
            self.currentArtwork = nil
            return nil
        }
    }
    
    /// Resumes playback explicitly.
    func play() {
        guard audioFile != nil else { return }
        if isPlaying { return }

        // Activate audio session to ensure playback can resume
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error.localizedDescription)")
        }

        // If the file finished playing, we need to stop, reschedule, and then play.
        if needsReschedule {
            playerNode.stop()
            if !engine.isRunning {
                try? engine.start()
            }
            guard let file = audioFile else { return }
            lastPlaybackPosition = 0
            pausedPosition = nil
            let frameCount = AVAudioFrameCount(audioFileLength - lastPlaybackPosition)
            playerNode.scheduleSegment(file, startingFrame: lastPlaybackPosition, frameCount: frameCount, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
            needsReschedule = false
        }

        // Ensure the engine is running
        if !engine.isRunning {
            try? engine.start()
        }

        pausedPosition = nil
        playerNode.play()
        isPlaying = true
        print("Playback started/resumed. playerNode.isPlaying = \(playerNode.isPlaying)")
        // Update lock screen immediately
        syncNowPlayingInfo()
    }

    /// Starts or stops the playback and handles file rescheduling for looping.
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    /// Pauses playback explicitly.
    func pause() {
        if playerNode.isPlaying {
            pausedPosition = getCurrentFramePosition() // Capture position before pausing
            playerNode.pause()
        }
        isPlaying = false
        print("Playback paused. isPlaying=\(isPlaying), playerNode.isPlaying=\(playerNode.isPlaying)")
        // Update lock screen immediately
        syncNowPlayingInfo()
    }
    
    /// Seeks to a specific time in the audio file.
    /// - Parameter time: The time in seconds to seek to.
    func seek(to time: Double) {
        guard let audioFile = audioFile, audioSampleRate > 0 else { return }

        let wasPlaying = playerNode.isPlaying
        playerNode.stop()

        let startingFrame = AVAudioFramePosition(time * audioSampleRate)
        let frameCount = AVAudioFrameCount(audioFileLength - startingFrame)

        guard frameCount > 0 else {
            print("Seek time is out of bounds.")
            return
        }

        lastPlaybackPosition = startingFrame
        pausedPosition = startingFrame // Update paused position so UI shows correct time if paused
        needsReschedule = false

        playerNode.scheduleSegment(audioFile, startingFrame: startingFrame, frameCount: frameCount, at: nil) { [weak self] in
            self?.needsReschedule = true
        }

        if wasPlaying {
            pausedPosition = nil
            playerNode.play()
        }
        updateNowPlayingInfo(isPaused: !wasPlaying)
    }
    
    func isCurrentlyPlaying() -> Bool {
        return playerNode.isPlaying
    }
    
    /// Returns the total duration of the audio file in seconds.
    func getAudioDuration() -> Double {
        guard audioSampleRate > 0 else { return 0 }
        return Double(audioFileLength) / audioSampleRate
    }

    /// Returns the current playback time in seconds.
    func getCurrentTime() -> Double {
        guard audioSampleRate > 0 else { return 0 }
        if let paused = pausedPosition, !isPlaying {
            return Double(paused) / audioSampleRate
        }
        guard let position = getCurrentFramePosition() else { return Double(lastPlaybackPosition) / audioSampleRate }
        return Double(position) / audioSampleRate
    }
    
    private func getCurrentFramePosition() -> AVAudioFramePosition? {
        guard let nodeTime = playerNode.lastRenderTime, let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return nil }
        return lastPlaybackPosition + playerTime.sampleTime
    }
    
    // MARK: Vocal Removal Control
    
    /// Enables or disables vocal removal processing.
    func setRemoveVocalsEnabled(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        let wasEnabled = isRemoveVocalsEnabled
        isRemoveVocalsEnabled = enabled
        
        if enabled && !wasEnabled && audioFile != nil {
            // Trigger source separation for current audio file
            performSourceSeparation { success in
                if !success { self.isRemoveVocalsEnabled = false }
                completion?(success)
            }
        } else if !enabled && wasEnabled && audioFile != nil {
            // Revert to original audio file playback
            if let original = self.originalAudioFile {
                self.audioFile = original
            }
            
            let wasPlaying = playerNode.isPlaying
            playerNode.stop()
            needsReschedule = false
            lastPlaybackPosition = 0
            pausedPosition = nil
            playerNode.scheduleFile(audioFile!, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
            if wasPlaying {
                if !engine.isRunning { try? engine.start() }
                playerNode.play()
            }
            completion?(true)
        } else {
            completion?(true)
        }
    }
    
    /// Sets the vocal level (0 = instrumental only, 100 = full vocals).
    func setVocalLevel(_ level: Float) {
        currentVocalLevel = max(0, min(100, level))
        UserDefaults.standard.set(currentVocalLevel, forKey: "vocalLevel")
        
        // Apply the new vocal level immediately if vocal removal is enabled and audio is loaded
        if isRemoveVocalsEnabled && audioFile != nil {
            applyVocalLevel()
        }
    }
    
    /// Applies the current vocal level to playback by using the mixed buffer.
    private func applyVocalLevel() {
        guard isRemoveVocalsEnabled && audioFile != nil else {
            print("⚠️ applyVocalLevel skipped: isRemoveVocalsEnabled=\(isRemoveVocalsEnabled), hasAudioFile=\(audioFile != nil)")
            return
        }
        
        // Get the mixed buffer with current vocal level
        let normalizedLevel = currentVocalLevel / 100.0  // Convert 0-100 to 0-1
        guard let mixedBuffer = sourceSeparationProcessor.getMixedBuffer(vocalLevel: normalizedLevel, format: audioFile?.processingFormat) else {
            print("❌ Failed to get mixed buffer for vocal level: \(currentVocalLevel)")
            return
        }
        
        print("✓ Applying vocal level \(currentVocalLevel)%: mixedBuffer=\(mixedBuffer.frameLength) frames")
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("vocals_removed_temp.caf")
        
        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            
            let tempFile = try AVAudioFile(forWriting: tempURL, settings: mixedBuffer.format.settings)
            try tempFile.write(from: mixedBuffer)
            
            if self.originalAudioFile == nil {
                self.originalAudioFile = self.audioFile
            }
            self.audioFile = try AVAudioFile(forReading: tempURL)
            
            // Stop current playback
            let wasPlaying = playerNode.isPlaying
            playerNode.stop()
            
            needsReschedule = false
            lastPlaybackPosition = 0
            pausedPosition = nil
            
            playerNode.scheduleFile(self.audioFile!, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
            
            // Resume playback if it was playing
            if wasPlaying {
                if !engine.isRunning {
                    try? engine.start()
                }
                playerNode.play()
            }
        } catch {
            print("❌ Failed to save separated audio to temp file: \(error.localizedDescription)")
        }
    }
    
    /// Performs source separation on the current audio file.
    private func performSourceSeparation(completion: @escaping (Bool) -> Void) {
        guard let audioFile = audioFile else {
            completion(false)
            return
        }
        
        print("🎵 Starting source separation...")
        
        // Read audio file into a buffer for processing
        do {
            let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: AVAudioFrameCount(audioFile.length))
            guard let buffer = buffer else {
                print("Failed to create buffer for source separation")
                completion(false)
                return
            }
            
            try audioFile.read(into: buffer)
            print("✓ Audio buffer read: \(buffer.frameLength) frames, \(audioFile.processingFormat.channelCount) channels")
            
            sourceSeparationProcessor.separateAudio(audioBuffer: buffer) { [weak self] success in
                if success {
                    print("✓ Source separation completed successfully")
                    // Apply vocal level to playback after separation
                    DispatchQueue.main.async {
                        self?.applyVocalLevel()
                        completion(true)
                    }
                } else {
                    print("✗ Source separation failed")
                    DispatchQueue.main.async {
                        completion(false)
                    }
                }
            }
        } catch {
            print("Error reading audio file for separation: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    /// Returns whether vocal removal is currently enabled.
    func isVocalRemovalEnabled() -> Bool {
        return isRemoveVocalsEnabled
    }
    
    /// Returns the current vocal level (0-100).
    func getVocalLevel() -> Float {
        return currentVocalLevel
    }
    
    // MARK: Now Playing Info & Remote Commands
    
    /// Configures the handlers for remote commands from Control Center and the lock screen.
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Enable commands explicitly - these MUST stay enabled
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        
        print("🔧 Remote commands ENABLED: play, pause, togglePlayPause")

        // Helper to execute on main thread immediately if possible, to ensure UI updates sync with return .success
        func runOnMain(_ block: @escaping () -> Void) {
            if Thread.isMainThread {
                block()
            } else {
                DispatchQueue.main.async(execute: block)
            }
        }

        // Add handler for Play Command
        commandCenter.playCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            print("🔘 LOCK SCREEN: Play button pressed")
            runOnMain {
                self.play()
                self.onPlaybackStateChanged?()
            }
            return .success
        }

        // Add handler for Pause Command
        commandCenter.pauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            print("🔘 LOCK SCREEN: Pause button pressed")
            runOnMain {
                self.pause()
                self.onPlaybackStateChanged?()
            }
            return .success
        }
        
        // Add handler for Toggle Play/Pause Command
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            print("🔘 LOCK SCREEN: Toggle button pressed")
            runOnMain {
                self.togglePlayback()
                self.onPlaybackStateChanged?()
            }
            return .success
        }
        
        // Add handler for seek/scrub
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            runOnMain {
                self.seek(to: event.positionTime)
                self.onPlaybackStateChanged?()
            }
            return .success
        }
        
        // Add handler for Skip Forward Command (Siri)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [] // Empty to hide button but keep Siri
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            runOnMain {
                let currentTime = self.getCurrentTime()
                let duration = self.getAudioDuration()
                let newTime = min(duration, currentTime + event.interval)
                self.seek(to: newTime)
                self.onPlaybackStateChanged?()
            }
            return .success
        }

        // Add handler for Skip Backward Command (Siri)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [] // Empty to hide button but keep Siri
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            runOnMain {
                let currentTime = self.getCurrentTime()
                let newTime = max(0, currentTime - event.interval)
                self.seek(to: newTime)
                self.onPlaybackStateChanged?()
            }
            return .success
        }
        
        // Add handlers for Next/Previous Track
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            runOnMain {
                self.onNextTrack?()
            }
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            runOnMain {
                self.onPreviousTrack?()
            }
            return .success
        }
        
        // Disable Playback Rate Command (User reported it hidden behind menu)
        commandCenter.changePlaybackRateCommand.isEnabled = false
        
        // Add handler for Dislike Command (Mapped to Slow + Reverb)
        commandCenter.dislikeCommand.isEnabled = false
        
        // Add handler for Like Command (Mapped to Cycle Presets)
        if #available(iOS 16.0, *) {
            commandCenter.likeCommand.isEnabled = true
            commandCenter.likeCommand.localizedTitle = "Change Presets"
            commandCenter.likeCommand.addTarget { [weak self] _ in
                runOnMain {
                    self?.onCyclePreset?()
                }
                return .success
            }
        } else {
            commandCenter.likeCommand.isEnabled = false
        }
        
        // Initially disable them; they will be enabled by the view controller
        updatePlaylistRemoteCommands(isEnabled: false)
    }

    /// Updates the Now Playing information on the lock screen and Control Center.
    func updateNowPlayingInfo(isPaused: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, var info = self.nowPlayingInfo else {
                print("⚠️ updateNowPlayingInfo: No nowPlayingInfo available")
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                return
            }
            
            // Use the isPlaying property as the source of truth for playback state
            let isActuallyPlaying = self.isPlaying && self.playerNode.isPlaying
            let playbackRate = !isActuallyPlaying ? 0.0 : (self.isVarispeedEnabled ? self.varispeedNode.rate : self.timePitchNode.rate)
            
            print("🎵 updateNowPlayingInfo: self.isPlaying=\(self.isPlaying), playerNode.isPlaying=\(self.playerNode.isPlaying), isActuallyPlaying=\(isActuallyPlaying), FINAL playbackRate=\(playbackRate)")
            
            // Update only the dynamic properties: elapsed time and playback rate.
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.getCurrentTime()
            info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate

            // Set the updated information.
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            print("✅ Lock screen set to playbackRate: \(playbackRate)")
        }
    }
    
    /// Syncs the now playing info with the current playback state.
    /// Call this whenever playback state might have changed.
    func syncNowPlayingInfo() {
        let isPlaying = playerNode.isPlaying
        updateNowPlayingInfo(isPaused: !isPlaying)
    }
    
    /// Enables or disables the remote commands for playlist navigation.
    func updatePlaylistRemoteCommands(isEnabled: Bool) {
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = isEnabled
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = isEnabled
    }
    
    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    /// Sets up an observer for audio session interruptions.
    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAudioSessionInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
    }
    
    /// Handles audio session interruptions (e.g., phone calls).
    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("Audio session interruption began.")
            // Pause playback if currently playing
            if isPlaying {
                pausedPosition = getCurrentFramePosition()
                playerNode.pause()
                isPlaying = false
                updateNowPlayingInfo(isPaused: true)
                onPlaybackStateChanged?() // Notify UI to update play/pause button
            }
            // The engine might stop automatically. We don't explicitly stop it here
            // as the system often handles it, and we'll restart it if needed on resume.
            
        case .ended:
            print("Audio session interruption ended.")
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            if options.contains(.shouldResume) {
                print("Audio session should resume. Attempting to reactivate.")
                // Reactivate the session. The engine will be restarted by togglePlayback if needed.
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        @unknown default:
            print("Unknown audio session interruption type.")
        }
    }
    
    // MARK: Effect Controls

    /// Adjusts the song's playback rate (speed/tempo).
    /// - Parameter rate: The new playback rate (0.5 to 2.0).
    func setPlaybackRate(rate: Float, linkedPitch: Float?) {
        if isVarispeedEnabled {
            varispeedNode.rate = rate
        } else {
            timePitchNode.rate = rate
            // If a linked pitch value is provided, use it.
            if let pitch = linkedPitch {
                timePitchNode.pitch = pitch
            }
        }
        updateNowPlayingInfo(isPaused: !isPlaying)
        onPlaybackRateChanged?(rate)
    }
    
    /// Enables or disables Varispeed mode (High Quality Link Pitch & Speed).
    func setVarispeedEnabled(_ enabled: Bool) {
        guard isVarispeedEnabled != enabled else { return }
        isVarispeedEnabled = enabled
        
        // Stop playback and reset engine
        playerNode.stop()
        engine.stop()
        isPlaying = false
        
        if let file = audioFile {
            connectNodes(format: file.processingFormat)
            // Reschedule the file
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
        } else {
            let commonFormat = engine.mainMixerNode.outputFormat(forBus: 0)
            connectNodes(format: commonFormat)
        }
        
        do {
            try engine.start()
        } catch {
            print("Error restarting AVAudioEngine: \(error.localizedDescription)")
        }
        
        lastPlaybackPosition = 0
        pausedPosition = nil
        updateNowPlayingInfo(isPaused: true)
    }
    
    /// Adjusts the song's pitch.
    /// - Parameter pitch: The new pitch in cents (-1200 to 1200).
    func setPitch(pitch: Float) {
        // When pitch correction is on, changing the pitch slider should not
        // be affected by the rate's automatic pitch shift. The `pitch` property
        // is an independent adjustment.
        if !isVarispeedEnabled {
            timePitchNode.pitch = pitch
        }
    }
    
    /// Adjusts the amount of reverb applied to the song.
    /// - Parameter mix: The wet/dry mix percentage (0.0 to 100.0).
    func setReverbMix(mix: Float) {
        reverbNode.wetDryMix = mix
    }
    
    /// Adjusts the gain of the bass frequencies.
    /// - Parameter gain: The gain in decibels (-12 to +12).
    func setBassGain(gain: Float) {
        equalizerNode.bands[0].gain = gain
    }
    /// Adjusts the gain of the mid-range frequencies.
    /// - Parameter gain: The gain in decibels (-12 to +12).
    func setMidsGain(gain: Float) {
        equalizerNode.bands[1].gain = gain
    }
    /// Adjusts the gain of the treble frequencies.
    /// - Parameter gain: The gain in decibels (-12 to +12).
    func setTrebleGain(gain: Float) {
        equalizerNode.bands[2].gain = gain
    }
    
    // MARK: Audio Export

    /// Exports the currently loaded audio file with the applied effects to a temporary file.
    /// - Parameters:
    ///   - completion: A closure called when the export is complete, returning the URL of the exported file or an error.
    func exportAudio(bitrate: Int, progress: ((Float) -> Void)? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let sourceFile = self.audioFile else {
            completion(.failure(ExportError.noAudioFileLoaded))
            return
        }
        
        if isExporting {
            completion(.failure(ExportError.exportInProgress))
            return
        }
        
        isExporting = true
        
        // Stop playback to avoid issues with the engine state
        let wasPlaying = playerNode.isPlaying
        playerNode.stop()
        engine.stop()

        do {
            let maxFrames: AVAudioFrameCount = 4096
            try engine.enableManualRenderingMode(.offline, format: sourceFile.processingFormat, maximumFrameCount: maxFrames)
            
            // Create a temporary file URL for the output
            // Construct filename: [Song Name] [Speed] [Pitch] [Reverb].m4a
            let name = self.currentTitle ?? "Exported"
            var filenameComponents = [name]
            
            let currentRate = isVarispeedEnabled ? varispeedNode.rate : timePitchNode.rate
            if abs(currentRate - 1.0) > 0.01 {
                filenameComponents.append(String(format: "Speed %.2fx", currentRate))
            }
            
            if !isVarispeedEnabled {
                let pitchSemitones = Int((timePitchNode.pitch / 100.0).rounded())
                if pitchSemitones != 0 {
                    filenameComponents.append(String(format: "Pitch %dst", pitchSemitones))
                }
            } else {
                filenameComponents.append("HQ")
            }
            
            let reverbAmount = Int(reverbNode.wetDryMix.rounded())
            if reverbAmount > 0 {
                filenameComponents.append(String(format: "Reverb %d%%", reverbAmount))
            }
            
            let fileName = filenameComponents.joined(separator: " ")
            let safeName = fileName.replacingOccurrences(of: "/", with: "_")
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).m4a")
            
            // Define AAC settings
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFile.processingFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFile.processingFormat.channelCount,
                AVEncoderBitRateKey: bitrate,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
            
            // Create the output file using the AAC settings.
            var outputFile: AVAudioFile? = try AVAudioFile(forWriting: outputURL, settings: settings)
            
            // Schedule the entire source file for rendering
            playerNode.scheduleFile(sourceFile, at: nil, completionHandler: nil)
            
            // Start the engine and player for rendering
            try engine.start()
            playerNode.play()
            
            // The buffer to pull rendered audio into
            guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
                isExporting = false
                return
            }

            while engine.manualRenderingSampleTime < sourceFile.length {
                let framesToRender = min(buffer.frameCapacity, AVAudioFrameCount(sourceFile.length - engine.manualRenderingSampleTime))
                let status = try engine.renderOffline(framesToRender, to: buffer)
                
                switch status {
                case .success:
                    try outputFile?.write(from: buffer)
                    let p = Float(engine.manualRenderingSampleTime) / Float(sourceFile.length)
                    progress?(p)
                case .cannotDoInCurrentContext:
                    continue // Try again
                case .error:
                    throw NSError(domain: "AVAudioEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Offline rendering error."])
                @unknown default:
                    break
                }
            }
            
            // Close the file explicitly to ensure it's ready for metadata embedding
            outputFile = nil
            
            // Clean up
            playerNode.stop()
            engine.stop()
            engine.disableManualRenderingMode()
            
            // Reschedule the original file for normal playback
            playerNode.scheduleFile(sourceFile, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
            
            // Restart engine for future playback
            try engine.start()
            
            // Reset playback to beginning and pause
            lastPlaybackPosition = 0
            pausedPosition = nil
            isPlaying = false
            
            if let artwork = self.currentArtwork {
                self.embedMetadata(audioURL: outputURL, title: self.currentTitle, artist: self.currentArtist, artwork: artwork) { resultURL in
                    self.isExporting = false
                    completion(.success(resultURL ?? outputURL))
                }
            } else {
                isExporting = false
                completion(.success(outputURL))
            }
            
        } catch {
            // Ensure we clean up on error
            isExporting = false
            engine.stop()
            engine.disableManualRenderingMode()
            
            // Attempt to restore engine state
            try? engine.start()
            playerNode.scheduleFile(sourceFile, at: nil) { [weak self] in
                self?.needsReschedule = true
            }
            
            completion(.failure(error))
        }
    }
    
    /// Embeds metadata (Artwork, Title, Artist) into the exported audio file.
    private func embedMetadata(audioURL: URL, title: String?, artist: String?, artwork: UIImage, completion: @escaping (URL?) -> Void) {
        let asset = AVAsset(url: audioURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            completion(nil)
            return
        }
        
        let tempID = UUID().uuidString
        let finalURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(tempID).m4a")
        
        exportSession.outputURL = finalURL
        exportSession.outputFileType = .m4a
        
        var metadata = [AVMetadataItem]()
        
        // Artwork
        if let imageData = artwork.pngData() ?? artwork.jpegData(compressionQuality: 1.0) {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = AVMetadataKey.commonKeyArtwork as NSCopying & NSObjectProtocol
            item.value = imageData as NSCopying & NSObjectProtocol
            metadata.append(item)
        }
        
        // Title
        if let title = title {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = AVMetadataKey.commonKeyTitle as NSCopying & NSObjectProtocol
            item.value = title as NSCopying & NSObjectProtocol
            metadata.append(item)
        }
        
        // Artist
        if let artist = artist {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = AVMetadataKey.commonKeyArtist as NSCopying & NSObjectProtocol
            item.value = artist as NSCopying & NSObjectProtocol
            metadata.append(item)
        }
        
        exportSession.metadata = metadata
        
        exportSession.exportAsynchronously {
            if exportSession.status == .completed {
                // Replace the original file with the metadata-embedded file
                do {
                    try FileManager.default.removeItem(at: audioURL)
                    try FileManager.default.moveItem(at: finalURL, to: audioURL)
                    completion(audioURL)
                } catch {
                    print("Error moving metadata file: \(error)")
                    completion(finalURL)
                }
            } else {
                print("Metadata export failed: \(String(describing: exportSession.error))")
                completion(nil)
            }
        }
    }
}

// MARK: - Theme Management

enum ThemeColor: String, CaseIterable {
    case blue, pink, green, red, orange, purple, yellow

    var uiColor: UIColor {
        switch self {
        case .blue: return .systemBlue
        case .pink: return .systemPink
        case .green: return .systemGreen
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .yellow: return .systemYellow
        }
    }

    var capitalized: String {
        return self.rawValue.capitalized
    }
}

class ThemeManager {
    static let shared = ThemeManager()
    private let themeKey = "selectedTheme"

    var currentTheme: ThemeColor {
        get {
            let savedTheme = UserDefaults.standard.string(forKey: themeKey) ?? ThemeColor.blue.rawValue
            return ThemeColor(rawValue: savedTheme) ?? .blue
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeKey)
        }
    }

    private init() {}
}

// MARK: - Preset Management

struct AudioPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var speed: Float
    var pitch: Float
    var reverb: Float
    var bass: Float = 0
    var mids: Float = 0
    var treble: Float = 0
    
    static let defaults: [AudioPreset] = [
        AudioPreset(name: "Default", speed: 1.0, pitch: 0, reverb: 0),
        AudioPreset(name: "Slowed + Reverb", speed: 0.8, pitch: 0, reverb: 40),
        AudioPreset(name: "Sped Up", speed: 1.2, pitch: 0, reverb: 0)
    ]
}

class PresetManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PresetManager()
    private let key = "savedAudioPresets"
    private let notifyKey = "isNotifyPresetsEnabled"
    
    var presets: [AudioPreset] {
        didSet { save() }
    }
    
    override init() {
        self.presets = AudioPreset.defaults
        super.init()
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([AudioPreset].self, from: data) {
            presets = decoded
        }
        
        UNUserNotificationCenter.current().delegate = self
    }
    
    var isNotifyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: notifyKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyKey) }
    }
    
    func save() {
        if let encoded = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    func addPreset(_ preset: AudioPreset) {
        presets.append(preset)
    }
    
    func removePreset(at index: Int) {
        presets.remove(at: index)
    }
    
    func movePreset(from source: Int, to destination: Int) {
        let item = presets.remove(at: source)
        presets.insert(item, at: destination)
    }
    
    func resetToDefaults() {
        presets = AudioPreset.defaults
    }
    
    func requestNotificationPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    func sendPresetNotification(presetName: String) {
        guard isNotifyEnabled else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Preset Changed"
        content.body = "Active Preset: \(presetName)"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "PresetChange", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

class PresetsSettingsViewController: UITableViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Presets"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PresetCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SwitchCell")
        let addButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addPresetTapped))
        navigationItem.rightBarButtonItems = [addButton, editButtonItem]
    }
    
    @objc private func addPresetTapped() {
        let editor = PresetEditorViewController()
        editor.onSave = { [weak self] preset in
            PresetManager.shared.addPreset(preset)
            self?.tableView.reloadData()
        }
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }
    
    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        return PresetManager.shared.presets.count
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? "Settings" : "Saved Presets"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = "Notify of Presets"
            cell.contentConfiguration = content
            
            let switchControl = UISwitch()
            switchControl.isOn = PresetManager.shared.isNotifyEnabled
            switchControl.addTarget(self, action: #selector(notifySwitchChanged(_:)), for: .valueChanged)
            cell.accessoryView = switchControl
            cell.selectionStyle = .none
            return cell
        }
        
        let cell = tableView.dequeueReusableCell(withIdentifier: "PresetCell", for: indexPath)
        let preset = PresetManager.shared.presets[indexPath.row]
        
        var content = cell.defaultContentConfiguration()
        content.text = preset.name
        content.secondaryText = String(format: "Speed: %.2fx | Pitch: %.0f | Reverb: %.0f%%", preset.speed, preset.pitch, preset.reverb)
        cell.contentConfiguration = content
        cell.accessoryView = nil
        
        return cell
    }
    
    @objc private func notifySwitchChanged(_ sender: UISwitch) {
        if sender.isOn {
            PresetManager.shared.requestNotificationPermission { granted in
                if granted {
                    PresetManager.shared.isNotifyEnabled = true
                } else {
                    sender.setOn(false, animated: true)
                    let alert = UIAlertController(title: "Permission Required", message: "Please enable notifications in Settings to use this feature.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        } else {
            PresetManager.shared.isNotifyEnabled = false
        }
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete && indexPath.section == 1 {
            PresetManager.shared.removePreset(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .fade)
        }
    }
    
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 1
    }

    override func tableView(_ tableView: UITableView, moveRowAt fromIndexPath: IndexPath, to: IndexPath) {
        if fromIndexPath.section == 1 && to.section == 1 {
            PresetManager.shared.movePreset(from: fromIndexPath.row, to: to.row)
        }
    }
    
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 1
    }
    
    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        if proposedDestinationIndexPath.section != 1 {
            return sourceIndexPath
        }
        return proposedDestinationIndexPath
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 1 {
            tableView.deselectRow(at: indexPath, animated: true)
            let preset = PresetManager.shared.presets[indexPath.row]
            let editor = PresetEditorViewController(preset: preset)
            editor.onSave = { [weak self] updatedPreset in
                PresetManager.shared.presets[indexPath.row] = updatedPreset
                self?.tableView.reloadData()
            }
            let nav = UINavigationController(rootViewController: editor)
            present(nav, animated: true)
        }
    }
}

class PresetEditorViewController: UIViewController {
    var preset: AudioPreset
    var onSave: ((AudioPreset) -> Void)?
    
    private let nameField = UITextField()
    private let speedSlider = UISlider()
    private let pitchSlider = UISlider()
    private let reverbSlider = UISlider()
    
    private let speedLabel = UILabel()
    private let pitchLabel = UILabel()
    private let reverbLabel = UILabel()
    
    init(preset: AudioPreset = AudioPreset(name: "New Preset", speed: 1.0, pitch: 0, reverb: 0)) {
        self.preset = preset
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Edit Preset"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        
        setupUI()
    }
    
    private func setupUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        
        nameField.borderStyle = .roundedRect
        nameField.placeholder = "Preset Name"
        nameField.text = preset.name
        stack.addArrangedSubview(nameField)
        
        // Speed
        speedSlider.minimumValue = 0.5; speedSlider.maximumValue = 2.0; speedSlider.value = preset.speed
        speedSlider.addTarget(self, action: #selector(updateLabels), for: .valueChanged)
        stack.addArrangedSubview(createControl(label: speedLabel, slider: speedSlider))
        
        // Pitch
        pitchSlider.minimumValue = -1200; pitchSlider.maximumValue = 1200; pitchSlider.value = preset.pitch
        pitchSlider.addTarget(self, action: #selector(updateLabels), for: .valueChanged)
        stack.addArrangedSubview(createControl(label: pitchLabel, slider: pitchSlider))
        
        // Reverb
        reverbSlider.minimumValue = 0; reverbSlider.maximumValue = 100; reverbSlider.value = preset.reverb
        reverbSlider.addTarget(self, action: #selector(updateLabels), for: .valueChanged)
        stack.addArrangedSubview(createControl(label: reverbLabel, slider: reverbSlider))
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        
        updateLabels()
    }
    
    private func createControl(label: UILabel, slider: UISlider) -> UIView {
        let vStack = UIStackView(arrangedSubviews: [label, slider])
        vStack.axis = .vertical
        vStack.spacing = 8
        return vStack
    }
    
    @objc private func updateLabels() {
        speedLabel.text = String(format: "Speed: %.2fx", speedSlider.value)
        pitchLabel.text = String(format: "Pitch: %.0f cents", pitchSlider.value)
        reverbLabel.text = String(format: "Reverb: %.0f%%", reverbSlider.value)
    }
    
    @objc private func saveTapped() {
        guard let name = nameField.text, !name.isEmpty else { return }
        preset.name = name
        preset.speed = speedSlider.value
        preset.pitch = pitchSlider.value
        preset.reverb = reverbSlider.value
        
        onSave?(preset)
        dismiss(animated: true)
    }
    
    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
}

// MARK: - Settings View Controller

/// Protocol to delegate changes from the settings sheet back to the main view controller.
protocol SettingsViewControllerDelegate: AnyObject {
    func settingsViewController(_ controller: SettingsViewController, didChangeLinkPitchState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeDynamicBackgroundState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeAnimatedBackgroundState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeDynamicThemeState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeTheme theme: ThemeColor)
    func settingsViewController(_ controller: SettingsViewController, didChangeReverbSliderState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeResetSlidersOnTapState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeTapArtworkToChangeSongState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangePrecisePitchState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeAccurateSpeedState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeShowAlbumArtState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeShowExportButtonState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeShowEQState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeLoopingState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeRememberSettingsState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeAutoPlayNextState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeStepperState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeAutoLoadAddedSongState isEnabled: Bool)
    func settingsViewController(_ controller: SettingsViewController, didChangeShowPresetsState isEnabled: Bool)
}


/// A simple view controller to display app settings.
class SettingsViewController: UIViewController {
    weak var delegate: SettingsViewControllerDelegate?
    var isPitchLinked: Bool = false
    var isDynamicBackgroundEnabled: Bool = false
    var isAnimatedBackgroundEnabled: Bool = true
    var isDynamicThemeEnabled: Bool = false
    var currentTheme: ThemeColor = .blue
    var isReverbSliderEnabled: Bool = true
    var isResetSlidersOnTapEnabled: Bool = true
    var isTapArtworkToChangeSongEnabled: Bool = true
    var isAccuratePitchEnabled: Bool = false
    var isAccurateSpeedEnabled: Bool = false
    var isExportButtonEnabled: Bool = true
    var isEQEnabled: Bool = false
    var isAlbumArtVisible: Bool = true
    var isLoopingEnabled: Bool = false
    var isRememberSettingsEnabled: Bool = false
    var isAutoPlayNextEnabled: Bool = false
    var isStepperEnabled: Bool = false
    var isAutoLoadAddedSongEnabled: Bool = false
    var isShowPresetsEnabled: Bool = false
    var isRememberSearchEnabled: Bool = false
    private let impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    
    private let scrollView = UIScrollView()

    private let linkPitchSwitch = UISwitch()
    private let linkPitchLabel = UILabel()
    
    private let dynamicBackgroundSwitch = UISwitch()
    private let dynamicBackgroundLabel = UILabel()
    
    private let animatedBackgroundSwitch = UISwitch()
    private let animatedBackgroundLabel = UILabel()
    
    private let dynamicThemeSwitch = UISwitch()
    private let dynamicThemeLabel = UILabel()
    
    private let reverbSliderSwitch = UISwitch()
    private let reverbSliderLabel = UILabel()
    
    private let resetSlidersOnTapSwitch = UISwitch()
    private let resetSlidersOnTapLabel = UILabel()
    
    private let tapArtworkSwitch = UISwitch()
    private let tapArtworkLabel = UILabel()
    
    private let accuratePitchSwitch = UISwitch()
    private let accuratePitchLabel = UILabel()
    private var accuratePitchGroup: UIStackView!
    
    private let accurateSpeedSwitch = UISwitch()
    private let accurateSpeedLabel = UILabel()
    private var preciseSpeedGroup: UIStackView!
    
    private let exportButtonSwitch = UISwitch()
    private let exportButtonLabel = UILabel()
    
    private let eqSwitch = UISwitch()
    private let eqLabel = UILabel()

    private let albumArtSwitch = UISwitch()
    private let albumArtLabel = UILabel()
    
    private let loopingSwitch = UISwitch()
    private let loopingLabel = UILabel()
    
    private let rememberSettingsSwitch = UISwitch()
    private let rememberSettingsLabel = UILabel()
    
    private let autoPlayNextSwitch = UISwitch()
    private let autoPlayNextLabel = UILabel()
    
    private let stepperSwitch = UISwitch()
    private let stepperLabel = UILabel()
    
    private let autoLoadAddedSongSwitch = UISwitch()
    private let autoLoadAddedSongLabel = UILabel()
    
    private let rememberSearchSwitch = UISwitch()
    private let rememberSearchLabel = UILabel()
    
    private let showPresetsSwitch = UISwitch()
    private let showPresetsLabel = UILabel()
    
    private let scanDuplicatesButton = UIButton(type: .system)
    private let scanDuplicatesLabel = UILabel()
    
    private let slowedReverbSpeedSegmentedControl = UISegmentedControl(items: ["0.80x", "0.85x", "0.90x"])
    private let slowedReverbSpeedLabel = UILabel()
    
    private let slowedReverbReverbSegmentedControl = UISegmentedControl(items: ["0%", "20%", "40%"])
    private let slowedReverbReverbLabel = UILabel()
    
    private let spedUpSpeedSegmentedControl = UISegmentedControl(items: ["1.10x", "1.20x", "1.30x"])
    private let spedUpSpeedLabel = UILabel()
    
    private var themeStack: UIStackView!
    
    private var interfaceGroups: [UIView] = []
    private var themeGroups: [UIView] = []
    private var extrasGroups: [UIView] = []
    private var presetsGroups: [UIView] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Load state BEFORE setupUI
        isShowPresetsEnabled = UserDefaults.standard.bool(forKey: "isShowPresetsEnabled", defaultValue: true)
        isRememberSearchEnabled = UserDefaults.standard.bool(forKey: "isRememberSearchEnabled")
        
        setupUI()
        title = "Settings"
        impactFeedbackGenerator.prepare()
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(dismissSettings))
        
        // Apply loaded state to UI
        showPresetsSwitch.isOn = isShowPresetsEnabled
        rememberSearchSwitch.isOn = isRememberSearchEnabled
        
        updateAccurateSpeedToggleState()
    }

    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        // Add scroll view to the main view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Helper to create description labels
        func createDescriptionLabel(with text: String) -> UILabel {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            return label
        }

        // Helper to create header labels
        func createHeaderLabel(with text: String) -> UILabel {
            let label = UILabel()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.label,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            label.attributedText = NSAttributedString(string: text, attributes: attributes)
            label.textAlignment = .center
            return label
        }

        // --- Link Pitch Setting ---
        linkPitchLabel.text = "Link Pitch to Speed"
        linkPitchSwitch.isOn = isPitchLinked
        linkPitchSwitch.addTarget(self, action: #selector(linkPitchSwitchChanged), for: .valueChanged)
        let linkPitchStack = UIStackView(arrangedSubviews: [linkPitchLabel, linkPitchSwitch])
        linkPitchStack.spacing = 20
        let linkPitchDescription = createDescriptionLabel(with: "When enabled, changing the speed will also adjust the pitch, like a record player.")
        let linkPitchGroup = UIStackView(arrangedSubviews: [linkPitchStack, linkPitchDescription])
        linkPitchGroup.axis = .vertical
        linkPitchGroup.spacing = 4

        // --- Dynamic Background Setting ---
        dynamicBackgroundLabel.text = "Dynamic Background"
        dynamicBackgroundSwitch.isOn = isDynamicBackgroundEnabled
        dynamicBackgroundSwitch.addTarget(self, action: #selector(dynamicBackgroundSwitchChanged), for: .valueChanged)
        let dynamicBackgroundStack = UIStackView(arrangedSubviews: [dynamicBackgroundLabel, dynamicBackgroundSwitch])
        dynamicBackgroundStack.spacing = 20
        let dynamicBackgroundDescription = createDescriptionLabel(with: "Uses the song's album art to create a blurred background.")
        let dynamicBackgroundGroup = UIStackView(arrangedSubviews: [dynamicBackgroundStack, dynamicBackgroundDescription])
        dynamicBackgroundGroup.axis = .vertical
        dynamicBackgroundGroup.spacing = 4
        
        // --- Animated Background Setting ---
        animatedBackgroundLabel.text = "Animated Background"
        animatedBackgroundSwitch.isOn = isAnimatedBackgroundEnabled
        animatedBackgroundSwitch.addTarget(self, action: #selector(animatedBackgroundSwitchChanged), for: .valueChanged)
        let animatedBackgroundStack = UIStackView(arrangedSubviews: [animatedBackgroundLabel, animatedBackgroundSwitch])
        animatedBackgroundStack.spacing = 20
        let animatedBackgroundDescription = createDescriptionLabel(with: "Enables a slow zooming animation on the dynamic background.")
        let animatedBackgroundGroup = UIStackView(arrangedSubviews: [animatedBackgroundStack, animatedBackgroundDescription])
        animatedBackgroundGroup.axis = .vertical
        animatedBackgroundGroup.spacing = 4

        // --- Dynamic Theme Setting ---
        dynamicThemeLabel.text = "Dynamic Theme"
        dynamicThemeSwitch.isOn = isDynamicThemeEnabled
        dynamicThemeSwitch.addTarget(self, action: #selector(dynamicThemeSwitchChanged), for: .valueChanged)
        let dynamicThemeStack = UIStackView(arrangedSubviews: [dynamicThemeLabel, dynamicThemeSwitch])
        dynamicThemeStack.spacing = 20
        let dynamicThemeDescription = createDescriptionLabel(with: "Automatically picks a theme color from the song's album art.")
        let dynamicThemeGroup = UIStackView(arrangedSubviews: [dynamicThemeStack, dynamicThemeDescription])
        dynamicThemeGroup.axis = .vertical
        dynamicThemeGroup.spacing = 4

        // --- Reverb Slider Setting ---
        reverbSliderLabel.text = "Show Reverb Slider"
        reverbSliderSwitch.isOn = isReverbSliderEnabled
        reverbSliderSwitch.addTarget(self, action: #selector(reverbSliderSwitchChanged), for: .valueChanged)
        let reverbSliderStack = UIStackView(arrangedSubviews: [reverbSliderLabel, reverbSliderSwitch])
        reverbSliderStack.spacing = 20
        let reverbSliderDescription = createDescriptionLabel(with: "Shows or hides the reverb effect slider on the main screen.")
        let reverbSliderGroup = UIStackView(arrangedSubviews: [reverbSliderStack, reverbSliderDescription])
        reverbSliderGroup.axis = .vertical
        reverbSliderGroup.spacing = 4

        // --- Double-Tap to Reset Setting ---
        resetSlidersOnTapLabel.text = "Double-Tap to Reset Sliders"
        resetSlidersOnTapSwitch.isOn = isResetSlidersOnTapEnabled
        resetSlidersOnTapSwitch.addTarget(self, action: #selector(resetSlidersOnTapSwitchChanged), for: .valueChanged)
        let resetSlidersOnTapStack = UIStackView(arrangedSubviews: [resetSlidersOnTapLabel, resetSlidersOnTapSwitch])
        resetSlidersOnTapStack.spacing = 20
        let resetSlidersOnTapDescription = createDescriptionLabel(with: "Allows you to double-tap on the 'Pitch', 'Speed', or 'Reverb' labels to reset their values.")
        let resetSlidersOnTapGroup = UIStackView(arrangedSubviews: [resetSlidersOnTapStack, resetSlidersOnTapDescription])
        resetSlidersOnTapGroup.axis = .vertical
        resetSlidersOnTapGroup.spacing = 4

        // --- Tap Artwork to Change Song Setting ---
        tapArtworkLabel.text = "Tap Artwork to Change Song"
        tapArtworkSwitch.isOn = isTapArtworkToChangeSongEnabled
        tapArtworkSwitch.addTarget(self, action: #selector(tapArtworkSwitchChanged), for: .valueChanged)
        let tapArtworkStack = UIStackView(arrangedSubviews: [tapArtworkLabel, tapArtworkSwitch])
        tapArtworkStack.spacing = 20
        let tapArtworkDescription = createDescriptionLabel(with: "Allows you to tap the album artwork to open the file picker and choose a new song.")
        let tapArtworkGroup = UIStackView(arrangedSubviews: [tapArtworkStack, tapArtworkDescription])
        tapArtworkGroup.axis = .vertical
        tapArtworkGroup.spacing = 4
        
        // --- Accurate Pitch Setting ---
        accuratePitchLabel.text = "Accurate Pitch"
        accuratePitchSwitch.isOn = isAccuratePitchEnabled
        accuratePitchSwitch.addTarget(self, action: #selector(accuratePitchSwitchChanged), for: .valueChanged)
        let accuratePitchStack = UIStackView(arrangedSubviews: [accuratePitchLabel, accuratePitchSwitch])
        accuratePitchStack.spacing = 20
        let accuratePitchDescription = createDescriptionLabel(with: "When enabled, the pitch slider will snap to whole semitones.")
        let accuratePitchGroup = UIStackView(arrangedSubviews: [accuratePitchStack, accuratePitchDescription])
        accuratePitchGroup.axis = .vertical
        accuratePitchGroup.spacing = 4
        self.accuratePitchGroup = accuratePitchGroup
        
        // --- Accurate Speed Setting ---
        accurateSpeedLabel.text = "Accurate Speed"
        accurateSpeedSwitch.isOn = isAccurateSpeedEnabled
        accurateSpeedSwitch.addTarget(self, action: #selector(accurateSpeedSwitchChanged), for: .valueChanged)
        let accurateSpeedStack = UIStackView(arrangedSubviews: [accurateSpeedLabel, accurateSpeedSwitch])
        accurateSpeedStack.spacing = 20
        let accurateSpeedDescription = createDescriptionLabel(with: "When enabled, the speed slider will snap to 0.05x increments.")
        preciseSpeedGroup = UIStackView(arrangedSubviews: [accurateSpeedStack, accurateSpeedDescription])
        preciseSpeedGroup.axis = .vertical
        preciseSpeedGroup.spacing = 4
        
        // --- Export Button Setting ---
        exportButtonLabel.text = "Show Export Button"
        exportButtonSwitch.isOn = isExportButtonEnabled
        exportButtonSwitch.addTarget(self, action: #selector(exportButtonSwitchChanged), for: .valueChanged)
        let exportButtonStack = UIStackView(arrangedSubviews: [exportButtonLabel, exportButtonSwitch])
        exportButtonStack.spacing = 20
        let exportButtonDescription = createDescriptionLabel(with: "Shows a button to export the audio with all effects applied.")
        let exportButtonGroup = UIStackView(arrangedSubviews: [exportButtonStack, exportButtonDescription])
        exportButtonGroup.axis = .vertical
        exportButtonGroup.spacing = 4
        
        // --- EQ Setting ---
        eqLabel.text = "Show Equalizer"
        eqSwitch.isOn = isEQEnabled
        eqSwitch.addTarget(self, action: #selector(eqSwitchChanged), for: .valueChanged)
        let eqStack = UIStackView(arrangedSubviews: [eqLabel, eqSwitch])
        eqStack.spacing = 20
        let eqDescription = createDescriptionLabel(with: "Shows sliders for Bass, Mids, and Treble control.")
        let eqGroup = UIStackView(arrangedSubviews: [eqStack, eqDescription])
        eqGroup.axis = .vertical
        eqGroup.spacing = 4
        
        // --- Show Album Art Setting ---
        albumArtLabel.text = "Show Album Art"
        albumArtSwitch.isOn = isAlbumArtVisible
        albumArtSwitch.addTarget(self, action: #selector(albumArtSwitchChanged), for: .valueChanged)
        let albumArtStack = UIStackView(arrangedSubviews: [albumArtLabel, albumArtSwitch])
        albumArtStack.spacing = 20
        let albumArtDescription = createDescriptionLabel(with: "Shows or hides the album artwork on the main screen. The dynamic background is not affected.")
        let albumArtGroup = UIStackView(arrangedSubviews: [albumArtStack, albumArtDescription])
        albumArtGroup.axis = .vertical
        albumArtGroup.spacing = 4
        
        // --- Repeat Song Setting ---
        loopingLabel.text = "Repeat Song"
        loopingSwitch.isOn = isLoopingEnabled
        loopingSwitch.addTarget(self, action: #selector(loopingSwitchChanged), for: .valueChanged)
        let loopingStack = UIStackView(arrangedSubviews: [loopingLabel, loopingSwitch])
        loopingStack.spacing = 20
        let loopingDescription = createDescriptionLabel(with: "Automatically restarts the song when it finishes.")
        let loopingGroup = UIStackView(arrangedSubviews: [loopingStack, loopingDescription])
        loopingGroup.axis = .vertical
        loopingGroup.spacing = 4
        
        // --- Auto-Play Next Setting ---
        autoPlayNextLabel.text = "Auto-Play Next"
        autoPlayNextSwitch.isOn = isAutoPlayNextEnabled
        autoPlayNextSwitch.addTarget(self, action: #selector(autoPlayNextSwitchChanged), for: .valueChanged)
        let autoPlayNextStack = UIStackView(arrangedSubviews: [autoPlayNextLabel, autoPlayNextSwitch])
        autoPlayNextStack.spacing = 20
        let autoPlayNextDescription = createDescriptionLabel(with: "Automatically plays the next song in the library when the current one finishes.")
        let autoPlayNextGroup = UIStackView(arrangedSubviews: [autoPlayNextStack, autoPlayNextDescription])
        autoPlayNextGroup.axis = .vertical
        autoPlayNextGroup.spacing = 4
        
        // --- Remember Settings Setting ---
        rememberSettingsLabel.text = "Remember Settings"
        rememberSettingsSwitch.isOn = isRememberSettingsEnabled
        rememberSettingsSwitch.addTarget(self, action: #selector(rememberSettingsSwitchChanged), for: .valueChanged)
        let rememberSettingsStack = UIStackView(arrangedSubviews: [rememberSettingsLabel, rememberSettingsSwitch])
        rememberSettingsStack.spacing = 20
        let rememberSettingsDescription = createDescriptionLabel(with: "Keeps the current pitch, speed, and reverb settings when loading a new song.")
        let rememberSettingsGroup = UIStackView(arrangedSubviews: [rememberSettingsStack, rememberSettingsDescription])
        rememberSettingsGroup.axis = .vertical
        rememberSettingsGroup.spacing = 4
        
        // --- Remember Search Setting ---
        rememberSearchLabel.text = "Remember Search"
        rememberSearchSwitch.isOn = isRememberSearchEnabled
        rememberSearchSwitch.addTarget(self, action: #selector(rememberSearchSwitchChanged), for: .valueChanged)
        let rememberSearchStack = UIStackView(arrangedSubviews: [rememberSearchLabel, rememberSearchSwitch])
        rememberSearchStack.spacing = 20
        let rememberSearchDescription = createDescriptionLabel(with: "Keeps your search term and results active in the library until you clear them.")
        let rememberSearchGroup = UIStackView(arrangedSubviews: [rememberSearchStack, rememberSearchDescription])
        rememberSearchGroup.axis = .vertical
        rememberSearchGroup.spacing = 4
        
        // --- Stepper Buttons Setting ---
        stepperLabel.text = "Show Stepper Buttons"
        stepperSwitch.isOn = isStepperEnabled
        stepperSwitch.addTarget(self, action: #selector(stepperSwitchChanged), for: .valueChanged)
        let stepperStack = UIStackView(arrangedSubviews: [stepperLabel, stepperSwitch])
        stepperStack.spacing = 20
        let stepperDescription = createDescriptionLabel(with: "Shows plus and minus buttons next to sliders for fine adjustments.")
        let stepperGroup = UIStackView(arrangedSubviews: [stepperStack, stepperDescription])
        stepperGroup.axis = .vertical
        stepperGroup.spacing = 4
        
        // --- Auto-Load Added Song Setting ---
        autoLoadAddedSongLabel.text = "Auto-Load Added Song"
        autoLoadAddedSongSwitch.isOn = isAutoLoadAddedSongEnabled
        autoLoadAddedSongSwitch.addTarget(self, action: #selector(autoLoadAddedSongSwitchChanged), for: .valueChanged)
        let autoLoadAddedSongStack = UIStackView(arrangedSubviews: [autoLoadAddedSongLabel, autoLoadAddedSongSwitch])
        autoLoadAddedSongStack.spacing = 20
        let autoLoadAddedSongDescription = createDescriptionLabel(with: "Automatically plays a song when you add it to the library (single file only).")
        let autoLoadAddedSongGroup = UIStackView(arrangedSubviews: [autoLoadAddedSongStack, autoLoadAddedSongDescription])
        autoLoadAddedSongGroup.axis = .vertical
        autoLoadAddedSongGroup.spacing = 4
        
        // --- Show Presets Setting ---
        showPresetsLabel.text = "Show Presets"
        showPresetsSwitch.isOn = isShowPresetsEnabled
        showPresetsSwitch.addTarget(self, action: #selector(showPresetsSwitchChanged), for: .valueChanged)
        let showPresetsStack = UIStackView(arrangedSubviews: [showPresetsLabel, showPresetsSwitch])
        showPresetsStack.spacing = 20
        let showPresetsDescription = createDescriptionLabel(with: "Shows quick preset buttons for 'Slowed + Reverb' and 'Sped Up' audio effects.")
        let showPresetsGroup = UIStackView(arrangedSubviews: [showPresetsStack, showPresetsDescription])
        showPresetsGroup.axis = .vertical
        showPresetsGroup.spacing = 4
        
        // --- Scan Duplicates Setting ---
        scanDuplicatesLabel.text = "Scan for Duplicates"
        
        var scanConfig = UIButton.Configuration.filled()
        scanConfig.title = "Scan"
        scanConfig.baseBackgroundColor = .systemBlue
        scanConfig.baseForegroundColor = .white
        scanConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        scanDuplicatesButton.configuration = scanConfig
        scanDuplicatesButton.addTarget(self, action: #selector(scanDuplicatesTapped), for: .touchUpInside)
        
        let scanDuplicatesStack = UIStackView(arrangedSubviews: [scanDuplicatesLabel, scanDuplicatesButton])
        scanDuplicatesStack.spacing = 20
        let scanDuplicatesDescription = createDescriptionLabel(with: "Finds and removes duplicate songs based on title and artist.")
        let scanDuplicatesGroup = UIStackView(arrangedSubviews: [scanDuplicatesStack, scanDuplicatesDescription])
        scanDuplicatesGroup.axis = .vertical
        scanDuplicatesGroup.spacing = 4
        
        // --- Slowed + Reverb Speed Setting ---
        slowedReverbSpeedLabel.text = "Slowed Preset Speed"
        
        let savedSpeed = UserDefaults.standard.float(forKey: "slowedReverbSpeedPreset")
        let currentSpeed = savedSpeed > 0 ? savedSpeed : 0.8
        
        if abs(currentSpeed - 0.9) < 0.01 {
            slowedReverbSpeedSegmentedControl.selectedSegmentIndex = 2
        } else if abs(currentSpeed - 0.85) < 0.01 {
            slowedReverbSpeedSegmentedControl.selectedSegmentIndex = 1
        } else {
            slowedReverbSpeedSegmentedControl.selectedSegmentIndex = 0
        }
        
        slowedReverbSpeedSegmentedControl.addTarget(self, action: #selector(slowedReverbSpeedChanged), for: .valueChanged)
        
        let slowedReverbSpeedStack = UIStackView(arrangedSubviews: [slowedReverbSpeedLabel, slowedReverbSpeedSegmentedControl])
        slowedReverbSpeedStack.axis = .vertical
        slowedReverbSpeedStack.spacing = 8
        let slowedReverbSpeedDescription = createDescriptionLabel(with: "Select the speed used for the 'Slowed + Reverb' preset.")
        let slowedReverbSpeedGroup = UIStackView(arrangedSubviews: [slowedReverbSpeedStack, slowedReverbSpeedDescription])
        slowedReverbSpeedGroup.axis = .vertical
        slowedReverbSpeedGroup.spacing = 4
        
        // --- Slowed + Reverb Reverb Setting ---
        slowedReverbReverbLabel.text = "Slowed Preset Reverb"
        
        let savedReverb = UserDefaults.standard.float(forKey: "slowedReverbReverbPreset")
        if abs(savedReverb - 40) < 1 {
            slowedReverbReverbSegmentedControl.selectedSegmentIndex = 2
        } else if abs(savedReverb - 20) < 1 {
            slowedReverbReverbSegmentedControl.selectedSegmentIndex = 1
        } else {
            slowedReverbReverbSegmentedControl.selectedSegmentIndex = 0
        }
        
        slowedReverbReverbSegmentedControl.addTarget(self, action: #selector(slowedReverbReverbChanged), for: .valueChanged)
        
        let slowedReverbReverbStack = UIStackView(arrangedSubviews: [slowedReverbReverbLabel, slowedReverbReverbSegmentedControl])
        slowedReverbReverbStack.axis = .vertical
        slowedReverbReverbStack.spacing = 8
        let slowedReverbReverbDescription = createDescriptionLabel(with: "Select the reverb amount used for the 'Slowed + Reverb' preset.")
        let slowedReverbReverbGroup = UIStackView(arrangedSubviews: [slowedReverbReverbStack, slowedReverbReverbDescription])
        slowedReverbReverbGroup.axis = .vertical
        slowedReverbReverbGroup.spacing = 4
        
        // --- Sped Up Speed Setting ---
        spedUpSpeedLabel.text = "Sped Up Preset Speed"
        
        let savedSpedUpSpeed = UserDefaults.standard.float(forKey: "spedUpSpeedPreset")
        if abs(savedSpedUpSpeed - 1.3) < 0.01 {
            spedUpSpeedSegmentedControl.selectedSegmentIndex = 2
        } else if abs(savedSpedUpSpeed - 1.1) < 0.01 {
            spedUpSpeedSegmentedControl.selectedSegmentIndex = 0
        } else {
            spedUpSpeedSegmentedControl.selectedSegmentIndex = 1
        }
        
        spedUpSpeedSegmentedControl.addTarget(self, action: #selector(spedUpSpeedChanged), for: .valueChanged)
        
        let spedUpSpeedStack = UIStackView(arrangedSubviews: [spedUpSpeedLabel, spedUpSpeedSegmentedControl])
        spedUpSpeedStack.axis = .vertical
        spedUpSpeedStack.spacing = 8
        let spedUpSpeedDescription = createDescriptionLabel(with: "Select the speed used for the 'Sped Up' preset.")
        let spedUpSpeedGroup = UIStackView(arrangedSubviews: [spedUpSpeedStack, spedUpSpeedDescription])
        spedUpSpeedGroup.axis = .vertical
        spedUpSpeedGroup.spacing = 4
        
        // --- Theme Color Picker (Moved up for grouping) ---
        let themeTitleLabel = UILabel()
        themeTitleLabel.text = "Theme Color"
        themeTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        
        let colorButtonsStack = UIStackView()
        colorButtonsStack.axis = .horizontal
        colorButtonsStack.distribution = .fillEqually
        colorButtonsStack.spacing = 10
        
        for theme in ThemeColor.allCases {
            let button = UIButton(type: .system)
            button.backgroundColor = theme.uiColor
            button.layer.cornerRadius = 15
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.accessibilityLabel = theme.capitalized
            
            if theme == currentTheme {
                button.layer.borderColor = UIColor.label.cgColor
                button.layer.borderWidth = 2
            }
            
            button.addAction(UIAction { [weak self] _ in
                self?.delegate?.settingsViewController(self!, didChangeTheme: theme)
                self?.dismiss(animated: true)
                self?.impactFeedbackGenerator.impactOccurred()
            }, for: .touchUpInside)
            colorButtonsStack.addArrangedSubview(button)
        }
        
        themeStack = UIStackView(arrangedSubviews: [themeTitleLabel, colorButtonsStack])
        themeStack.axis = .vertical
        themeStack.spacing = 15
        themeStack.isHidden = isDynamicThemeEnabled
        
        // --- Grouping for Folders ---
        interfaceGroups = [
            reverbSliderGroup,
            eqGroup,
            stepperGroup,
            tapArtworkGroup,
            resetSlidersOnTapGroup,
            exportButtonGroup
        ]
        
        themeGroups = [
            dynamicThemeGroup,
            themeStack,
            albumArtGroup,
            dynamicBackgroundGroup,
            animatedBackgroundGroup
        ]
        
        extrasGroups = [
            rememberSettingsGroup,
            rememberSearchGroup,
            autoLoadAddedSongGroup,
            scanDuplicatesGroup
        ]
        
        presetsGroups = [
            showPresetsGroup,
            slowedReverbSpeedGroup,
            slowedReverbReverbGroup,
            spedUpSpeedGroup
        ]
        
        // --- Folder Buttons ---
        func createFolderButton(title: String, action: Selector) -> UIView {
            let container = UIView()
            container.backgroundColor = .secondarySystemGroupedBackground
            container.layer.cornerRadius = 10
            
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
            chevron.tintColor = .tertiaryLabel
            chevron.contentMode = .scaleAspectFit
            
            let stack = UIStackView(arrangedSubviews: [label, UIView(), chevron])
            stack.axis = .horizontal
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.isUserInteractionEnabled = false
            
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
            ])
            
            let tap = UITapGestureRecognizer(target: self, action: action)
            container.addGestureRecognizer(tap)
            
            return container
        }
        
        let interfaceFolder = createFolderButton(title: "Interface", action: #selector(openInterfaceSettings))
        let themeFolder = createFolderButton(title: "Theme", action: #selector(openThemeSettings))
        let extrasFolder = createFolderButton(title: "Extras", action: #selector(openExtrasSettings))
        let presetsFolder = createFolderButton(title: "Presets", action: #selector(openPresetsFolder))
        
        // Add Manage Presets button to presetsGroups
        let managePresetsButton = createFolderButton(title: "Manage Preset Cycle", action: #selector(openPresetsSettings))
        presetsGroups.insert(managePresetsButton, at: 0)

        // --- Main Settings Stack ---
        let settingsOptionsStack = UIStackView(arrangedSubviews: [
            // Modes
            linkPitchGroup,
            
            // Playback
            loopingGroup,
            autoPlayNextGroup,
            
            // Accuracy
            accuratePitchGroup,
            preciseSpeedGroup,
            
            // Folders
            interfaceFolder,
            themeFolder,
            presetsFolder,
            extrasFolder
        ])
        settingsOptionsStack.axis = .vertical
        settingsOptionsStack.spacing = 25
        settingsOptionsStack.translatesAutoresizingMaskIntoConstraints = false
        
        // Create a content view inside the scroll view to hold all elements
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        
        contentView.addSubview(settingsOptionsStack)

        NSLayoutConstraint.activate([
            settingsOptionsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            settingsOptionsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            settingsOptionsStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
        
        NSLayoutConstraint.activate([
            settingsOptionsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20), // Important for contentSize
            
            // Content view constraints to scroll view
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor) // Ensure vertical scrolling only
        ])
    }
    
    @objc private func dismissSettings() {
        dismiss(animated: true, completion: nil)
        impactFeedbackGenerator.impactOccurred()
    }

    private func updateAccurateSpeedToggleState() {
        guard preciseSpeedGroup != nil, accuratePitchGroup != nil else { return }
        let isLinked = linkPitchSwitch.isOn
        preciseSpeedGroup.alpha = 1.0
        accurateSpeedSwitch.isEnabled = true
        accuratePitchGroup.alpha = isLinked ? 0.5 : 1.0
        accuratePitchSwitch.isEnabled = !isLinked
    }

    @objc private func linkPitchSwitchChanged(_ sender: UISwitch) {
        updateAccurateSpeedToggleState()
        let message = sender.isOn
            ? "Changing this setting requires restarting the audio engine. Playback will stop and reset to the beginning."
            : "Unlinking pitch and speed allows for separate control but may impact sound and export quality. Changing this setting requires restarting the audio engine. Playback will stop and reset to the beginning."
        
        let alert = UIAlertController(title: "Change Audio Engine", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in
            sender.setOn(!sender.isOn, animated: true)
            self?.updateAccurateSpeedToggleState()
        }))
        alert.addAction(UIAlertAction(title: "Continue", style: .destructive, handler: { [weak self] _ in
            guard let self = self else { return }
            self.delegate?.settingsViewController(self, didChangeLinkPitchState: sender.isOn)
            self.impactFeedbackGenerator.impactOccurred()
        }))
        present(alert, animated: true)
    }
    
    @objc private func dynamicBackgroundSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeDynamicBackgroundState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func animatedBackgroundSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeAnimatedBackgroundState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func dynamicThemeSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeDynamicThemeState: sender.isOn)
        themeStack.isHidden = sender.isOn
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func reverbSliderSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeReverbSliderState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func resetSlidersOnTapSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeResetSlidersOnTapState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func tapArtworkSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeTapArtworkToChangeSongState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func accuratePitchSwitchChanged(_ sender: UISwitch) {
        impactFeedbackGenerator.impactOccurred()
        delegate?.settingsViewController(self, didChangePrecisePitchState: sender.isOn)
    }
    
    @objc private func accurateSpeedSwitchChanged(_ sender: UISwitch) {
        impactFeedbackGenerator.impactOccurred()
        delegate?.settingsViewController(self, didChangeAccurateSpeedState: sender.isOn)
    }
    
    @objc private func exportButtonSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeShowExportButtonState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func eqSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeShowEQState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func albumArtSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeShowAlbumArtState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func loopingSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeLoopingState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func autoPlayNextSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeAutoPlayNextState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func rememberSettingsSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeRememberSettingsState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func rememberSearchSwitchChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "isRememberSearchEnabled")
        if !sender.isOn {
            UserDefaults.standard.removeObject(forKey: "savedLibrarySearchTerm")
        }
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func stepperSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeStepperState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func autoLoadAddedSongSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeAutoLoadAddedSongState: sender.isOn)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func showPresetsSwitchChanged(_ sender: UISwitch) {
        delegate?.settingsViewController(self, didChangeShowPresetsState: sender.isOn)
        UserDefaults.standard.set(sender.isOn, forKey: "isShowPresetsEnabled")
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func slowedReverbSpeedChanged(_ sender: UISegmentedControl) {
        let speed: Float
        switch sender.selectedSegmentIndex {
        case 1: speed = 0.85
        case 2: speed = 0.90
        default: speed = 0.80
        }
        UserDefaults.standard.set(speed, forKey: "slowedReverbSpeedPreset")
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func slowedReverbReverbChanged(_ sender: UISegmentedControl) {
        let reverb: Float
        switch sender.selectedSegmentIndex {
        case 1: reverb = 20.0
        case 2: reverb = 40.0
        default: reverb = 0.0
        }
        UserDefaults.standard.set(reverb, forKey: "slowedReverbReverbPreset")
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func spedUpSpeedChanged(_ sender: UISegmentedControl) {
        let speed: Float
        switch sender.selectedSegmentIndex {
        case 0: speed = 1.10
        case 2: speed = 1.30
        default: speed = 1.20
        }
        UserDefaults.standard.set(speed, forKey: "spedUpSpeedPreset")
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func scanDuplicatesTapped() {
        let songs = LibraryManager.shared.songs
        var duplicates: [Song] = []
        var seen: Set<String> = []
        
        for song in songs {
            let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let artist = (song.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let key = "\(title)|\(artist)"
            
            if seen.contains(key) {
                duplicates.append(song)
            } else {
                seen.insert(key)
            }
        }
        
        guard !duplicates.isEmpty else {
            let alert = UIAlertController(title: "No Duplicates", message: "Your library is clean.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        showDuplicateActionSheet(duplicates: duplicates)
    }
    
    private func showDuplicateActionSheet(duplicates: [Song]) {
        let message = "Found \(duplicates.count) duplicate song(s)."
        let alert = UIAlertController(title: "Duplicates Found", message: message, preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "Delete All Duplicates", style: .destructive, handler: { [weak self] _ in
            self?.deleteAllDuplicates(duplicates)
        }))
        
        alert.addAction(UIAlertAction(title: "Review One by One", style: .default, handler: { [weak self] _ in
            self?.reviewDuplicates(duplicates)
        }))
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = scanDuplicatesButton
            popover.sourceRect = scanDuplicatesButton.bounds
        }
        
        present(alert, animated: true)
    }
    
    private func deleteAllDuplicates(_ duplicates: [Song]) {
        let ids = duplicates.map { $0.id }
        LibraryManager.shared.deleteSongs(withIDs: ids)
        
        let alert = UIAlertController(title: "Success", message: "Deleted \(duplicates.count) duplicates.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    private func reviewDuplicates(_ duplicates: [Song], index: Int = 0) {
        guard index < duplicates.count else {
            let alert = UIAlertController(title: "Review Complete", message: "All duplicates processed.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        let song = duplicates[index]
        let message = "Title: \(song.title)\nArtist: \(song.artist ?? "Unknown")"
        
        let alert = UIAlertController(title: "Duplicate (\(index + 1)/\(duplicates.count))", message: message, preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { [weak self] _ in
            LibraryManager.shared.deleteSongs(withIDs: [song.id])
            self?.reviewDuplicates(duplicates, index: index + 1)
        }))
        
        alert.addAction(UIAlertAction(title: "Skip", style: .default, handler: { [weak self] _ in
            self?.reviewDuplicates(duplicates, index: index + 1)
        }))
        
        alert.addAction(UIAlertAction(title: "Delete All Remaining", style: .destructive, handler: { [weak self] _ in
            let remaining = Array(duplicates[index...])
            self?.deleteAllDuplicates(remaining)
        }))
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
    
    @objc private func openInterfaceSettings() {
        let vc = SubSettingsViewController()
        vc.title = "Interface"
        vc.contentViews = interfaceGroups
        navigationController?.pushViewController(vc, animated: true)
    }
    
    @objc private func openThemeSettings() {
        let vc = SubSettingsViewController()
        vc.title = "Theme"
        vc.contentViews = themeGroups
        navigationController?.pushViewController(vc, animated: true)
    }
    
    @objc private func openExtrasSettings() {
        let vc = SubSettingsViewController()
        vc.title = "Extras"
        vc.contentViews = extrasGroups
        navigationController?.pushViewController(vc, animated: true)
    }
    
    @objc private func openPresetsFolder() {
        let vc = SubSettingsViewController()
        vc.title = "Presets"
        vc.contentViews = presetsGroups
        navigationController?.pushViewController(vc, animated: true)
    }
    
    @objc private func openPresetsSettings() {
        let vc = PresetsSettingsViewController()
        navigationController?.pushViewController(vc, animated: true)
    }
}

class SubSettingsViewController: UIViewController {
    var contentViews: [UIView] = []
    private let scrollView = UIScrollView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        
        let stackView = UIStackView(arrangedSubviews: contentViews)
        stackView.axis = .vertical
        stackView.spacing = 25
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        scrollView.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }
}

// MARK: - Library Management

struct Song: Codable, Identifiable, Equatable {
    var id = UUID()
    let title: String
    let artist: String?
    let album: String?
    let fileName: String
    var savedPitch: Float?
    var savedSpeed: Float?
    var savedReverb: Float?
    var isFavorite: Bool?
    var dateAdded: Date?
    var lastPlayedDate: Date?
    
    var url: URL? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths.first?.appendingPathComponent(fileName)
    }
}

class LibraryManager {
    static let shared = LibraryManager()
    private let libraryKey = "musicLibrary"
    var songs: [Song] = []
    
    init() {
        loadLibrary()
    }
    
    func loadLibrary() {
        if let data = UserDefaults.standard.data(forKey: libraryKey),
           let decoded = try? JSONDecoder().decode([Song].self, from: data) {
            songs = decoded
        }
    }
    
    func saveLibrary() {
        if let encoded = try? JSONEncoder().encode(songs) {
            UserDefaults.standard.set(encoded, forKey: libraryKey)
        }
    }
    
    func addSong(from url: URL) {
        // Copy file to Documents
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
        
        // If file exists, generate a unique name
        var finalDestinationURL = destinationURL
        var counter = 1
        while fileManager.fileExists(atPath: finalDestinationURL.path) {
            let fileName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            finalDestinationURL = documentsURL.appendingPathComponent("\(fileName)_\(counter).\(ext)")
            counter += 1
        }
        
        do {
            if url.startAccessingSecurityScopedResource() {
                try fileManager.copyItem(at: url, to: finalDestinationURL)
                url.stopAccessingSecurityScopedResource()
            } else {
                try fileManager.copyItem(at: url, to: finalDestinationURL)
            }
            
            // Extract Metadata
            let asset = AVAsset(url: finalDestinationURL)
            let metadata = asset.commonMetadata
            let title = metadata.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue ?? url.deletingPathExtension().lastPathComponent
            let artist = metadata.first(where: { $0.commonKey == .commonKeyArtist })?.stringValue
            let album = metadata.first(where: { $0.commonKey == .commonKeyAlbumName })?.stringValue
            
            let newSong = Song(title: title, artist: artist, album: album, fileName: finalDestinationURL.lastPathComponent, savedPitch: nil, savedSpeed: nil, savedReverb: nil, isFavorite: nil, dateAdded: Date(), lastPlayedDate: nil)
            songs.append(newSong)
            saveLibrary()
            
        } catch {
            print("Error adding song to library: \(error)")
        }
    }
    
    func updateSong(_ song: Song) {
        if let index = songs.firstIndex(where: { $0.id == song.id }) {
            songs[index] = song
            saveLibrary()
        }
    }
    
    func deleteSong(at index: Int) {
        let song = songs[index]
        if let url = song.url {
            try? FileManager.default.removeItem(at: url)
        }
        songs.remove(at: index)
        saveLibrary()
    }
    
    func toggleFavorite(for songID: UUID) {
        if let index = songs.firstIndex(where: { $0.id == songID }) {
            var song = songs[index]
            song.isFavorite = !(song.isFavorite ?? false)
            songs[index] = song
            saveLibrary()
        }
    }
    
    func deleteSongs(withIDs ids: [UUID]) {
        let idsSet = Set(ids)
        songs.filter { idsSet.contains($0.id) }.forEach { song in
            if let url = song.url {
                try? FileManager.default.removeItem(at: url)
            }
        }
        songs.removeAll { idsSet.contains($0.id) }
        saveLibrary()
    }
}

// MARK: - Library View Controller

protocol LibraryViewControllerDelegate: AnyObject {
    func libraryViewController(_ controller: LibraryViewController, didSelectSong song: Song, in songs: [Song])
    func libraryViewController(_ controller: LibraryViewController, didTapShuffleWith songs: [Song])
    func libraryViewController(_ controller: LibraryViewController, didRequestPlayNext song: Song)
}

private enum LibrarySortOption: Int, CaseIterable {
    case title, artist, album, recentlyAdded, recentlyPlayed

    var description: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        }
    }

    func areInIncreasingOrder(_ song1: Song, _ song2: Song) -> Bool {
        switch self {
        case .title:
            let titleComp = song1.title.localizedCaseInsensitiveCompare(song2.title)
            if titleComp != .orderedSame { return titleComp == .orderedAscending }
            return (song1.artist ?? "").localizedCaseInsensitiveCompare(song2.artist ?? "") == .orderedAscending
        case .artist:
            let artistComp = (song1.artist ?? "").localizedCaseInsensitiveCompare(song2.artist ?? "")
            if artistComp != .orderedSame { return artistComp == .orderedAscending }
            let albumComp = (song1.album ?? "").localizedCaseInsensitiveCompare(song2.album ?? "")
            if albumComp != .orderedSame { return albumComp == .orderedAscending }
            return song1.title.localizedCaseInsensitiveCompare(song2.title) == .orderedAscending
        case .album:
            let albumComp = (song1.album ?? "").localizedCaseInsensitiveCompare(song2.album ?? "")
            if albumComp != .orderedSame { return albumComp == .orderedAscending }
            return song1.title.localizedCaseInsensitiveCompare(song2.title) == .orderedAscending
        case .recentlyAdded:
            return (song1.dateAdded ?? Date.distantPast) > (song2.dateAdded ?? Date.distantPast)
        case .recentlyPlayed:
            return (song1.lastPlayedDate ?? Date.distantPast) > (song2.lastPlayedDate ?? Date.distantPast)
        }
    }
}

class LibraryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDataSourcePrefetching, UIDocumentPickerDelegate, UISearchResultsUpdating {
    
    weak var delegate: LibraryViewControllerDelegate?
    var currentSongID: UUID?
    var initialSearchQuery: String?
    var showFavoritesOnly = false
    private var hasScrolledToCurrentSong = false
    
    private let tableView = UITableView()
    private var displayedSongs: [Song] = []
    
    private struct Section {
        let title: String
        var songs: [Song]
    }
    private var sections: [Section] = []
    private let searchController = UISearchController(searchResultsController: nil)
    
    private let sortOptionKey = "librarySortOption"
    
    private var deleteButton: UIBarButtonItem?
    private let artworkCache = NSCache<NSString, UIImage>()
    var exactSearchFilter: (field: String, value: String)?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupSearch()
        
        // Pre-populate search text to avoid flash of full content
        if let query = initialSearchQuery {
            searchController.searchBar.text = query
        } else if UserDefaults.standard.bool(forKey: "isRememberSearchEnabled"),
                  let savedQuery = UserDefaults.standard.string(forKey: "savedLibrarySearchTerm"),
                  !savedQuery.isEmpty {
            searchController.searchBar.text = savedQuery
        }
        
        loadSongs()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !hasScrolledToCurrentSong {
            view.layoutIfNeeded()
            scrollToCurrentSong()
            hasScrolledToCurrentSong = true
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Activate search controller if text is present
        if let text = searchController.searchBar.text, !text.isEmpty {
            if !searchController.isActive {
                searchController.isActive = true
                searchController.searchBar.text = text
            }
            initialSearchQuery = nil
        }
        
        if !hasScrolledToCurrentSong {
            scrollToCurrentSong()
            hasScrolledToCurrentSong = true
        }
    }
    
    private func setupUI() {
        view.backgroundColor = .systemGroupedBackground
        
        title = showFavoritesOnly ? "Favorites" : "Library"
        
        if !showFavoritesOnly || navigationController?.viewControllers.first == self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(dismissView))
        }
        updateRightBarButtons()
        
        navigationController?.navigationBar.prefersLargeTitles = true

        let headerView = UIView()
        headerView.backgroundColor = .systemGroupedBackground
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)
        
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(stackView)
        
        let shuffleButton = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Shuffle"
        config.image = UIImage(systemName: "shuffle")
        config.imagePadding = 8
        config.baseBackgroundColor = .systemGray
        config.baseForegroundColor = .white
        shuffleButton.configuration = config
        shuffleButton.addTarget(self, action: #selector(shuffleTapped), for: .touchUpInside)
        stackView.addArrangedSubview(shuffleButton)
        
        if !showFavoritesOnly {
            let favoritesButton = UIButton(type: .system)
            var favConfig = UIButton.Configuration.filled()
            favConfig.title = "Favorites"
            favConfig.image = UIImage(systemName: "heart.fill")
            favConfig.imagePadding = 8
            favConfig.baseBackgroundColor = .systemPink
            favConfig.baseForegroundColor = .white
            favoritesButton.configuration = favConfig
            favoritesButton.addTarget(self, action: #selector(favoritesTapped), for: .touchUpInside)
            stackView.addArrangedSubview(favoritesButton)
        } else if navigationController?.viewControllers.first == self {
            let libraryButton = UIButton(type: .system)
            var libConfig = UIButton.Configuration.filled()
            libConfig.title = "Library"
            libConfig.image = UIImage(systemName: "music.note.list")
            libConfig.imagePadding = 8
            libConfig.baseBackgroundColor = .systemBlue
            libConfig.baseForegroundColor = .white
            libraryButton.configuration = libConfig
            libraryButton.addTarget(self, action: #selector(allSongsTapped), for: .touchUpInside)
            stackView.addArrangedSubview(libraryButton)
        }
        
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            
            stackView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 10),
            stackView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -10),
            shuffleButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.register(SongTableViewCell.self, forCellReuseIdentifier: SongTableViewCell.reuseIdentifier)
        tableView.rowHeight = 60
        // Disable prefetch during search for better performance
        tableView.isPrefetchingEnabled = true
        tableView.backgroundColor = .clear
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        tableView.allowsMultipleSelectionDuringEditing = true
    }
    
    private func scrollToCurrentSong() {
        guard let currentID = currentSongID else { return }
        
        for (sectionIndex, section) in sections.enumerated() {
            if let rowIndex = section.songs.firstIndex(where: { $0.id == currentID }) {
                let indexPath = IndexPath(row: rowIndex, section: sectionIndex)
                if tableView.numberOfSections > sectionIndex && tableView.numberOfRows(inSection: sectionIndex) > rowIndex {
                    tableView.scrollToRow(at: indexPath, at: .top, animated: false)
                }
                return
            }
        }
    }
    
    private func setupSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.placeholder = "Search Songs"
        navigationItem.searchController = searchController
        definesPresentationContext = true
    }
    
    func updateSearchResults(for searchController: UISearchController) {
        let searchBar = searchController.searchBar
        
        if UserDefaults.standard.bool(forKey: "isRememberSearchEnabled") {
            let text = searchBar.text ?? ""
            if text.isEmpty {
                UserDefaults.standard.removeObject(forKey: "savedLibrarySearchTerm")
            } else {
                UserDefaults.standard.set(text, forKey: "savedLibrarySearchTerm")
            }
        }
        
        if let exactFilter = exactSearchFilter, searchBar.text == exactFilter.value {
            filterContentForExactMatch(field: exactFilter.field, value: exactFilter.value)
        } else {
            if exactSearchFilter != nil { exactSearchFilter = nil }
            filterContentForSearchText(searchBar.text!)
        }
    }
    
    private func filterContentForExactMatch(field: String, value: String) {
        let sourceSongs = showFavoritesOnly ? LibraryManager.shared.songs.filter { $0.isFavorite ?? false } : LibraryManager.shared.songs
        displayedSongs = sourceSongs.filter { song in
            if field == "artist" {
                return (song.artist ?? "").localizedCaseInsensitiveCompare(value) == .orderedSame
            } else if field == "album" {
                return (song.album ?? "").localizedCaseInsensitiveCompare(value) == .orderedSame
            }
            return false
        }
        sortSongs()
        tableView.reloadData()
    }
    
    private func filterContentForSearchText(_ searchText: String) {
        let sourceSongs = showFavoritesOnly ? LibraryManager.shared.songs.filter { $0.isFavorite ?? false } : LibraryManager.shared.songs
        if searchText.isEmpty {
            displayedSongs = sourceSongs
        } else {
            let searchTerms = searchText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            displayedSongs = sourceSongs.filter { (song: Song) -> Bool in
                if searchTerms.isEmpty { return true }
                return searchTerms.allSatisfy { term in
                    let titleMatch = song.title.range(of: term, options: .caseInsensitive) != nil
                    let artistMatch = (song.artist ?? "").range(of: term, options: .caseInsensitive) != nil
                    let albumMatch = (song.album ?? "").range(of: term, options: .caseInsensitive) != nil
                    return titleMatch || artistMatch || albumMatch
                }
            }
        }
        sortSongs()
        tableView.reloadData()
    }
    
    @objc private func dismissView() {
        dismiss(animated: true)
    }
    
    @objc private func favoritesTapped() {
        let favoritesVC = LibraryViewController()
        favoritesVC.showFavoritesOnly = true
        favoritesVC.delegate = delegate
        favoritesVC.currentSongID = currentSongID
        navigationController?.pushViewController(favoritesVC, animated: true)
    }
    
    @objc private func allSongsTapped() {
        let libraryVC = LibraryViewController()
        libraryVC.showFavoritesOnly = false
        libraryVC.delegate = delegate
        libraryVC.currentSongID = currentSongID
        navigationController?.pushViewController(libraryVC, animated: true)
    }
    
    @objc private func shuffleTapped() {
        delegate?.libraryViewController(self, didTapShuffleWith: displayedSongs)
        dismiss(animated: true)
    }
    
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        navigationController?.setToolbarHidden(!editing, animated: animated)
        
        if editing {
            navigationItem.rightBarButtonItems = [editButtonItem]
            let actionBtn: UIBarButtonItem
            if showFavoritesOnly {
                actionBtn = UIBarButtonItem(image: UIImage(systemName: "heart.slash"), style: .plain, target: self, action: #selector(unfavoriteSelectedSongs))
                actionBtn.tintColor = .systemPink
            } else {
                actionBtn = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(deleteSelectedSongs))
                actionBtn.tintColor = .systemRed
            }
            actionBtn.isEnabled = false
            self.deleteButton = actionBtn
            let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            toolbarItems = [spacer, actionBtn]
        } else {
            updateRightBarButtons()
            toolbarItems = nil
        }
    }
    
    @objc private func deleteSelectedSongs() {
        guard let selectedIndexPaths = tableView.indexPathsForSelectedRows else { return }
        let songsToDelete = selectedIndexPaths.map { sections[$0.section].songs[$0.row] }
        let idsToDelete = songsToDelete.map { $0.id }
        
        let alert = UIAlertController(title: "Delete Songs", message: "Are you sure you want to delete \(songsToDelete.count) songs?", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { [weak self] _ in
            LibraryManager.shared.deleteSongs(withIDs: idsToDelete)
            self?.loadSongs()
            self?.setEditing(false, animated: true)
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = deleteButton
        }
        
        present(alert, animated: true)
    }
    
    @objc private func unfavoriteSelectedSongs() {
        guard let selectedIndexPaths = tableView.indexPathsForSelectedRows else { return }
        let songsToUnfavorite = selectedIndexPaths.map { sections[$0.section].songs[$0.row] }
        
        for song in songsToUnfavorite {
            LibraryManager.shared.toggleFavorite(for: song.id)
        }
        loadSongs()
        setEditing(false, animated: true)
    }
    
    private func updateRightBarButtons() {
        let currentSortIndex = UserDefaults.standard.integer(forKey: sortOptionKey)
        let currentSort = LibrarySortOption(rawValue: currentSortIndex) ?? .title
        
        let sortMenu = UIMenu(title: "Sort By", children: LibrarySortOption.allCases.map { option in
            UIAction(title: option.description, state: option == currentSort ? .on : .off) { [weak self] _ in
                UserDefaults.standard.set(option.rawValue, forKey: self?.sortOptionKey ?? "")
                self?.sortSongs()
                self?.tableView.reloadData()
                self?.updateRightBarButtons()
            }
        })
        
        let sortButton = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down.circle"), menu: sortMenu)
        
        if showFavoritesOnly {
            navigationItem.rightBarButtonItems = [sortButton, editButtonItem]
        } else {
            let addButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addSongTapped))
            navigationItem.rightBarButtonItems = [addButton, sortButton, editButtonItem]
        }
    }
    
    @objc private func addSongTapped() {
        let alert = UIAlertController(title: "Import", message: "What would you like to import?", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Audio Files", style: .default, handler: { [weak self] _ in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
            picker.delegate = self
            picker.allowsMultipleSelection = true
            picker.overrideUserInterfaceStyle = .dark
            self?.present(picker, animated: true)
        }))
        alert.addAction(UIAlertAction(title: "Entire Folder", style: .default, handler: { [weak self] _ in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            picker.delegate = self
            picker.allowsMultipleSelection = false
            picker.overrideUserInterfaceStyle = .dark
            self?.present(picker, animated: true)
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(alert, animated: true)
    }
    
    private func loadSongs() {
        let searchText = searchController.searchBar.text ?? ""
        if let exactFilter = exactSearchFilter, searchText == exactFilter.value {
            filterContentForExactMatch(field: exactFilter.field, value: exactFilter.value)
        } else if !searchText.isEmpty {
            filterContentForSearchText(searchText)
        } else {
            if showFavoritesOnly {
                displayedSongs = LibraryManager.shared.songs.filter { $0.isFavorite ?? false }
            } else {
                displayedSongs = LibraryManager.shared.songs
            }
            sortSongs()
            tableView.reloadData()
        }
    }
    
    private func sortSongs() {
        let sortIndex = UserDefaults.standard.integer(forKey: sortOptionKey)
        guard let sortOption = LibrarySortOption(rawValue: sortIndex) else { return }
        
        displayedSongs.sort(by: sortOption.areInIncreasingOrder)
        updateSections()
    }
    
    private func updateSections() {
        let sortIndex = UserDefaults.standard.integer(forKey: sortOptionKey)
        let sortOption = LibrarySortOption(rawValue: sortIndex) ?? .title
        
        if sortOption == .recentlyAdded || sortOption == .recentlyPlayed {
            self.sections = [Section(title: sortOption.description, songs: displayedSongs)]
            return
        }
        
        var newSections: [Section] = []
        
        for song in displayedSongs {
            let keyString: String
            switch sortOption {
            case .title: keyString = song.title
            case .artist: keyString = song.artist ?? ""
            case .album: keyString = song.album ?? ""
            default: keyString = song.title
            }
            
            let firstChar = keyString.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "#"
            let sectionTitle = firstChar.rangeOfCharacter(from: .letters) != nil ? firstChar : "#"
            
            if let lastIndex = newSections.indices.last, newSections[lastIndex].title == sectionTitle {
                newSections[lastIndex].songs.append(song)
            } else {
                newSections.append(Section(title: sectionTitle, songs: [song]))
            }
        }
        self.sections = newSections
    }
    
    // MARK: - UITableViewDataSource
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].songs.count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }
    
    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        let sortIndex = UserDefaults.standard.integer(forKey: sortOptionKey)
        let sortOption = LibrarySortOption(rawValue: sortIndex) ?? .title
        if sortOption == .recentlyAdded || sortOption == .recentlyPlayed {
            return nil
        }
        return sections.map { $0.title }
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: SongTableViewCell.reuseIdentifier, for: indexPath) as? SongTableViewCell else {
            // Return a properly configured fallback cell
            let fallbackCell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            return fallbackCell
        }
        
        // Bounds checking: ensure indexPath is valid
        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].songs.count else {
            return cell
        }
        
        let song = sections[indexPath.section].songs[indexPath.row]
        cell.songID = song.id
        
        // Configure with title and artist
        cell.configure(with: nil, title: song.title, artist: song.artist)
        
        // Highlight the currently playing song
        if song.id == currentSongID {
            cell.accessoryType = .checkmark
            cell.tintColor = view.tintColor
        } else {
            cell.accessoryType = .none
            cell.tintColor = .systemBlue
        }
        
        // Load artwork asynchronously with caching
        let cacheKey = song.id.uuidString as NSString
        if let cachedImage = artworkCache.object(forKey: cacheKey) {
            // Use cached image immediately
            cell.setArtwork(cachedImage)
        } else if let url = song.url {
            // Load artwork asynchronously
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                
                let asset = AVAsset(url: url)
                var artwork: UIImage?
                
                if let artworkItem = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork }),
                   let data = artworkItem.dataValue {
                    artwork = UIImage(data: data)
                }
                
                if let image = artwork {
                    self.artworkCache.setObject(image, forKey: cacheKey)
                    
                    // Only update cell if it's still visible and shows the same song
                    DispatchQueue.main.async {
                        // Check if the cell is still visible and hasn't been reused
                        if cell.songID == song.id,
                           let visibleCell = tableView.cellForRow(at: indexPath) as? SongTableViewCell,
                           visibleCell === cell {
                            cell.setArtwork(image)
                        }
                    }
                }
            }
        }
        
        return cell
    }
    
    // MARK: - UITableViewDataSourcePrefetching
    
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        // Prefetch artwork for upcoming cells to ensure smooth scrolling
        for indexPath in indexPaths {
            guard indexPath.section < sections.count,
                  indexPath.row < sections[indexPath.section].songs.count else { continue }
            
            let song = sections[indexPath.section].songs[indexPath.row]
            let cacheKey = song.id.uuidString as NSString
            
            // Skip if already cached
            if artworkCache.object(forKey: cacheKey) != nil { continue }
            
            // Prefetch artwork asynchronously
            if let url = song.url {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    
                    let asset = AVAsset(url: url)
                    if let artworkItem = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork }),
                       let data = artworkItem.dataValue,
                       let image = UIImage(data: data) {
                        self.artworkCache.setObject(image, forKey: cacheKey)
                    }
                }
            }
        }
    }
    
    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        // Optional: handle cancellation if needed
    }
    
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Ensure cell configuration is complete before display
        guard let songCell = cell as? SongTableViewCell else { return }
        
        // Bounds check
        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].songs.count else { return }
        
        let song = sections[indexPath.section].songs[indexPath.row]
        
        // If artwork is cached, display it immediately
        let cacheKey = song.id.uuidString as NSString
        if let cachedImage = artworkCache.object(forKey: cacheKey) {
            songCell.setArtwork(cachedImage)
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateDeleteButtonState()
            return
        }
        let selectedSong = sections[indexPath.section].songs[indexPath.row]
        delegate?.libraryViewController(self, didSelectSong: selectedSong, in: displayedSongs)
        dismiss(animated: true)
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let songToDelete = sections[indexPath.section].songs[indexPath.row]
            if let index = LibraryManager.shared.songs.firstIndex(where: { $0.id == songToDelete.id }) {
                LibraryManager.shared.deleteSong(at: index)
                loadSongs() // Reload data
            }
        }
    }
    
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        return nil
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        
        let infoAction = UIContextualAction(style: .normal, title: "Info") { [weak self] _, _, completion in
            guard let self = self else { completion(false); return }
            
            let song = self.sections[indexPath.section].songs[indexPath.row]
            self.showSongInfo(song)
            completion(true)
        }
        infoAction.backgroundColor = .systemBlue
        infoAction.image = UIImage(systemName: "info.circle")
        
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self = self else { completion(false); return }
            
            let songToDelete = self.sections[indexPath.section].songs[indexPath.row]
            
            let alert = UIAlertController(title: "Delete Song", message: "Are you sure you want to delete \"\(songToDelete.title)\"?", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
                completion(false)
            }))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { [weak self] _ in
                if let index = LibraryManager.shared.songs.firstIndex(where: { $0.id == songToDelete.id }) {
                    LibraryManager.shared.deleteSong(at: index)
                }
                self?.loadSongs()
                completion(true)
            }))
            
            self.present(alert, animated: true)
        }
        deleteAction.image = UIImage(systemName: "trash")
        
        let favoriteAction = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
            guard let self = self else { completion(false); return }
            let song = self.sections[indexPath.section].songs[indexPath.row]
            LibraryManager.shared.toggleFavorite(for: song.id)
            self.loadSongs()
            completion(true)
        }
        let isFav = self.sections[indexPath.section].songs[indexPath.row].isFavorite ?? false
        favoriteAction.image = UIImage(systemName: isFav ? "heart.slash.fill" : "heart.fill")
        favoriteAction.backgroundColor = isFav ? .systemGray : .systemPink
        
        if showFavoritesOnly {
            return UISwipeActionsConfiguration(actions: [favoriteAction, infoAction])
        } else {
            return UISwipeActionsConfiguration(actions: [deleteAction, favoriteAction, infoAction])
        }
    }
    
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].songs.count else { return nil }
        
        let song = sections[indexPath.section].songs[indexPath.row]
        
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            
            let infoAction = UIAction(title: "Info", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.showSongInfo(song)
            }
            
            let playNextAction = UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { [weak self] _ in
                guard let self = self else { return }
                self.delegate?.libraryViewController(self, didRequestPlayNext: song)
            }
            
            let isFav = song.isFavorite ?? false
            let favTitle = isFav ? "Unfavorite" : "Favorite"
            let favImage = UIImage(systemName: isFav ? "heart.slash.fill" : "heart.fill")
            let favoriteAction = UIAction(title: favTitle, image: favImage) { [weak self] _ in
                guard let self = self else { return }
                LibraryManager.shared.toggleFavorite(for: song.id)
                self.loadSongs()
            }
            
            var menuItems: [UIMenuElement] = [playNextAction, infoAction, favoriteAction]
            
            if let artist = song.artist, !artist.isEmpty {
                let searchArtistAction = UIAction(title: "Search Artist", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                    guard let self = self else { return }
                    self.exactSearchFilter = ("artist", artist)
                    self.searchController.isActive = true
                    self.searchController.searchBar.text = artist
                    self.updateSearchResults(for: self.searchController)
                }
                menuItems.append(searchArtistAction)
            }
            
            if let album = song.album, !album.isEmpty {
                let searchAlbumAction = UIAction(title: "Search Album", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                    guard let self = self else { return }
                    self.exactSearchFilter = ("album", album)
                    self.searchController.isActive = true
                    self.searchController.searchBar.text = album
                    self.updateSearchResults(for: self.searchController)
                }
                menuItems.append(searchAlbumAction)
            }
            
            let deleteAction = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self = self else { return }
                let alert = UIAlertController(title: "Delete Song", message: "Are you sure you want to delete \"\(song.title)\"?", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { [weak self] _ in
                    if let index = LibraryManager.shared.songs.firstIndex(where: { $0.id == song.id }) {
                        LibraryManager.shared.deleteSong(at: index)
                    }
                    self?.loadSongs()
                }))
                self.present(alert, animated: true)
            }
            
            menuItems.append(deleteAction)
            
            return UIMenu(title: "", children: menuItems)
        }
    }
    
    private func showSongInfo(_ song: Song) {
        var message = "Title: \(song.title)\nArtist: \(song.artist ?? "Unknown")\nAlbum: \(song.album ?? "Unknown")\n\nSaved Settings:\n"
        message += "Pitch: \(song.savedPitch.map { "\(Int($0)) cents" } ?? "Default (0)")\n"
        message += "Speed: \(song.savedSpeed.map { String(format: "%.2fx", $0) } ?? "Default (1.0x)")\n"
        message += "Reverb: \(song.savedReverb.map { "\(Int($0))%" } ?? "Default (0%)")"
        
        let alert = UIAlertController(title: "Song Details", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateDeleteButtonState()
        }
    }
    
    private func updateDeleteButtonState() {
        let count = tableView.indexPathsForSelectedRows?.count ?? 0
        deleteButton?.isEnabled = count > 0
    }
    
    // MARK: - UIDocumentPickerDelegate
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        processImport(urls: urls)
    }
    
    private func processImport(urls: [URL], index: Int = 0) {
        guard index < urls.count else {
            loadSongs()
            return
        }
        
        let url = urls[index]
        let fileName = url.lastPathComponent
        
        // Check if we should auto-load (only for single file import)
        // We also check if it's a directory to avoid auto-playing a random song from a folder import
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let shouldAutoLoad = urls.count == 1 && !isDirectory && UserDefaults.standard.bool(forKey: "isAutoLoadAddedSongEnabled")
        
        // Check for duplicates by filename
        if LibraryManager.shared.songs.contains(where: { $0.fileName == fileName }) {
            let alert = UIAlertController(title: "Duplicate Song", message: "The song \"\(fileName)\" is already in your library. Do you want to add it again?", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in
                self?.processImport(urls: urls, index: index + 1)
            }))
            alert.addAction(UIAlertAction(title: "Add", style: .default, handler: { [weak self] _ in
                self?.addSongInternal(url: url)
                
                if shouldAutoLoad, let newSong = LibraryManager.shared.songs.last {
                    self?.delegate?.libraryViewController(self!, didSelectSong: newSong, in: LibraryManager.shared.songs)
                    self?.dismiss(animated: true)
                } else {
                    self?.processImport(urls: urls, index: index + 1)
                }
            }))
            present(alert, animated: true)
        } else {
            addSongInternal(url: url)
            
            if shouldAutoLoad, let newSong = LibraryManager.shared.songs.last {
                delegate?.libraryViewController(self, didSelectSong: newSong, in: LibraryManager.shared.songs)
                dismiss(animated: true)
            } else {
                processImport(urls: urls, index: index + 1)
            }
        }
    }
    
    private func addSongInternal(url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        
        if isDirectory {
            let fileManager = FileManager.default
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey], options: [.skipsHiddenFiles]) else { return }
            
            for case let fileURL as URL in enumerator {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
                    if resourceValues.isDirectory == true { continue }
                    
                    var isAudio = false
                    if let contentType = resourceValues.contentType, contentType.conforms(to: .audio) {
                        isAudio = true
                    } else {
                        let ext = fileURL.pathExtension.lowercased()
                        if ["mp3", "m4a", "wav", "aif", "aiff", "aac", "flac", "m4b"].contains(ext) {
                            isAudio = true
                        }
                    }
                    
                    if isAudio {
                        LibraryManager.shared.addSong(from: fileURL)
                    }
                } catch {
                    print("Error processing file in folder: \(error)")
                }
            }
        } else {
            LibraryManager.shared.addSong(from: url)
        }
    }
}

/// A custom table view cell to display song information.
class SongTableViewCell: UITableViewCell {
    static let reuseIdentifier = "SongTableViewCell"
    
    var songID: UUID?
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private var isConfigured = false
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCellUI()
        setupBackgroundConfiguration()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupBackgroundConfiguration() {
        // Set explicit background configuration to prevent nil configuration errors during rapid scrolling
        var defaultConfig = UIBackgroundConfiguration.clear()
        backgroundConfiguration = defaultConfig
        backgroundColor = .clear
    }
    
    private func setupCellUI() {
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.layer.cornerRadius = 4
        artworkImageView.clipsToBounds = true
        artworkImageView.backgroundColor = .secondarySystemBackground
        contentView.addSubview(artworkImageView)
        
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.text = nil  // Initialize with nil
        artistLabel.font = .systemFont(ofSize: 14)
        artistLabel.textColor = .secondaryLabel
        artistLabel.text = nil  // Initialize with nil
        
        let textStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        contentView.addSubview(textStack)
        
        NSLayoutConstraint.activate([
            artworkImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            artworkImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: 44),
            artworkImageView.heightAnchor.constraint(equalToConstant: 44),
            
            textStack.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    
    func configure(with artwork: UIImage?, title: String, artist: String?) {
        // Guard against nil or empty values
        guard !title.isEmpty else { return }
        
        titleLabel.text = title
        artistLabel.text = artist
        artistLabel.isHidden = (artist?.isEmpty ?? true)
        artworkImageView.image = artwork ?? UIImage(systemName: "music.note")
        isConfigured = true
    }
    
    func setArtwork(_ image: UIImage?) {
        artworkImageView.image = image ?? UIImage(systemName: "music.note")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        // Cancel any pending operations
        artworkImageView.layer.removeAllAnimations()
        
        // Reset all UI elements to initial state
        artworkImageView.image = nil
        titleLabel.text = nil
        artistLabel.text = nil
        artistLabel.isHidden = true
        accessoryType = .none
        tintColor = .systemBlue  // Reset to default
        
        // Reset state flags
        songID = nil
        isConfigured = false
        
        // Re-establish background configuration
        setupBackgroundConfiguration()
    }
}

// MARK: - 2. User Interface and File Picker

class QueueViewController: UITableViewController {
    var songs: [Song] = []
    var currentIndex: Int = 0
    var onSelect: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onReorder: (([Song], Int) -> Void)?
    var onLoadMore: (() -> Void)?
    private let artworkCache = NSCache<NSString, UIImage>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Up Next"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "QueueCell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissSelf))
        navigationItem.leftBarButtonItem = editButtonItem
        
        // Scroll to current song
        DispatchQueue.main.async {
            if self.songs.indices.contains(self.currentIndex) {
                let indexPath = IndexPath(row: self.currentIndex, section: 0)
                self.tableView.scrollToRow(at: indexPath, at: .top, animated: false)
            }
        }
        setupLoadMoreFooter()
    }

    func setupLoadMoreFooter() {
        if onLoadMore != nil {
            let footerView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.frame.width, height: 60))
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = "Load More"
            button.configuration = config
            button.addTarget(self, action: #selector(loadMoreTapped), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            footerView.addSubview(button)
            
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: footerView.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: footerView.centerYAnchor)
            ])
            
            tableView.tableFooterView = footerView
        } else {
            tableView.tableFooterView = nil
        }
    }

    @objc private func loadMoreTapped() {
        onLoadMore?()
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return songs.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "QueueCell", for: indexPath)
        let song = songs[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = song.title
        content.secondaryText = song.artist
        
        // Album Art
        let cacheKey = song.id.uuidString as NSString
        if let cachedImage = artworkCache.object(forKey: cacheKey) {
            content.image = cachedImage
        } else {
            content.image = UIImage(systemName: "music.note")
            if let url = song.url {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let asset = AVAsset(url: url)
                    var image: UIImage?
                    if let artworkItem = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork }),
                       let data = artworkItem.dataValue {
                        image = UIImage(data: data)
                    }
                    if let art = image {
                        self?.artworkCache.setObject(art, forKey: cacheKey)
                        DispatchQueue.main.async {
                            if let visibleCell = tableView.cellForRow(at: indexPath) {
                                tableView.reloadRows(at: [indexPath], with: .none)
                            }
                        }
                    }
                }
            }
        }
        content.imageProperties.cornerRadius = 4
        content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        
        if indexPath.row == currentIndex {
            content.textProperties.color = .systemBlue
            let speaker = UIImageView(image: UIImage(systemName: "speaker.wave.3.fill"))
            speaker.tintColor = .systemBlue
            cell.accessoryView = speaker
        } else if indexPath.row < currentIndex {
            content.textProperties.color = .secondaryLabel
            content.secondaryTextProperties.color = .tertiaryLabel
            cell.accessoryView = nil
        } else {
            content.textProperties.color = .label
            cell.accessoryView = nil
        }
        
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(indexPath.row)
        dismiss(animated: true)
    }
    
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.row != currentIndex
    }
    
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            onDelete?(indexPath.row)
            songs.remove(at: indexPath.row)
            if indexPath.row < currentIndex {
                currentIndex -= 1
            }
            tableView.deleteRows(at: [indexPath], with: .fade)
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        if !editing {
            onReorder?(songs, currentIndex)
        }
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let movedSong = songs.remove(at: sourceIndexPath.row)
        songs.insert(movedSong, at: destinationIndexPath.row)

        if currentIndex == sourceIndexPath.row {
            currentIndex = destinationIndexPath.row
        } else if sourceIndexPath.row < currentIndex && destinationIndexPath.row >= currentIndex {
            currentIndex -= 1
        } else if sourceIndexPath.row > currentIndex && destinationIndexPath.row <= currentIndex {
            currentIndex += 1
        }
        onReorder?(songs, currentIndex)
    }
}

protocol WelcomeViewControllerDelegate: AnyObject {
    func welcomeViewControllerDidTapImport(_ controller: WelcomeViewController)
    func welcomeViewControllerDidTapDemo(_ controller: WelcomeViewController)
}

class WelcomeViewController: UIViewController {
    weak var delegate: WelcomeViewControllerDelegate?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }
    
    private func setupUI() {
        let titleLabel = UILabel()
        titleLabel.text = "Welcome to Slow + Reverb"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        
        let descriptionLabel = UILabel()
        descriptionLabel.text = "To get started, add some songs to your library.\nSupports MP3 and M4A files."
        descriptionLabel.font = .systemFont(ofSize: 17)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.textAlignment = .center
        descriptionLabel.numberOfLines = 0
        
        var importConfig = UIButton.Configuration.filled()
        importConfig.title = "Import Songs"
        importConfig.image = UIImage(systemName: "square.and.arrow.down")
        importConfig.imagePadding = 8
        importConfig.cornerStyle = .capsule
        importConfig.baseBackgroundColor = .systemBlue
        
        let importButton = UIButton(configuration: importConfig)
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        
        var demoConfig = UIButton.Configuration.tinted()
        demoConfig.title = "Try Demo Song"
        demoConfig.image = UIImage(systemName: "play.circle")
        demoConfig.imagePadding = 8
        demoConfig.cornerStyle = .capsule
        
        let demoButton = UIButton(configuration: demoConfig)
        demoButton.addTarget(self, action: #selector(demoTapped), for: .touchUpInside)
        
        let stack = UIStackView(arrangedSubviews: [titleLabel, descriptionLabel, importButton, demoButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            
            importButton.widthAnchor.constraint(equalToConstant: 200),
            importButton.heightAnchor.constraint(equalToConstant: 50),
            
            demoButton.widthAnchor.constraint(equalToConstant: 200),
            demoButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    @objc private func importTapped() {
        delegate?.welcomeViewControllerDidTapImport(self)
    }
    
    @objc private func demoTapped() {
        delegate?.welcomeViewControllerDidTapDemo(self)
    }
}

class AudioEffectsViewController: UIViewController, SettingsViewControllerDelegate, LibraryViewControllerDelegate, UIDocumentPickerDelegate, WelcomeViewControllerDelegate {

    // MARK: Properties
    
    private let audioProcessor = AudioProcessor()
    private let impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedbackGenerator = UISelectionFeedbackGenerator()
    
    // Background Image View
    private let backgroundImageView = UIImageView()
    private let blurEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .prominent))

    // UI Components
    private let albumArtImageView = UIImageView()
    private let songTitleLabel = UILabel()
    private let artistNameLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let libraryButton = UIButton(type: .system)
    private let removeVocalsButton = UIButton(type: .system)
    private let generateSpectrogramButton = UIButton(type: .system)
    private let saveValuesButton = UIButton(type: .system)
    private let favoriteButton = UIButton(type: .system)
    private let repeatButton = UIButton(type: .system)
    private let queueButton = UIButton(type: .system)
    private let settingsIconButton = UIButton(type: .system)
    
    private let progressSlider = UISlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private var progressUpdateTimer: Timer?
    
    private let pitchLabel = UILabel()
    private let pitchSlider = UISlider()
    private var pitchControlStack: UIStackView!
    
    private let speedLabel = UILabel()
    private let speedSlider = UISlider()
    
    private let reverbLabel = UILabel()
    private let reverbSlider = UISlider()
    
    // EQ Components
    private let bassLabel = UILabel()
    private let bassSlider = UISlider()
    
    private let midsLabel = UILabel()
    private let midsSlider = UISlider()
    
    private let trebleLabel = UILabel()
    private let trebleSlider = UISlider()
    
    // Stepper Buttons
    private let pitchMinusButton = UIButton(type: .system)
    private let pitchPlusButton = UIButton(type: .system)
    private let speedMinusButton = UIButton(type: .system)
    private let speedPlusButton = UIButton(type: .system)
    private let reverbMinusButton = UIButton(type: .system)
    private let reverbPlusButton = UIButton(type: .system)
    private let bassMinusButton = UIButton(type: .system)
    private let bassPlusButton = UIButton(type: .system)
    private let midsMinusButton = UIButton(type: .system)
    private let midsPlusButton = UIButton(type: .system)
    private let trebleMinusButton = UIButton(type: .system)
    private let treblePlusButton = UIButton(type: .system)
    
    private let resetButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    
    // Preset Buttons
    private let slowedReverbButton = UIButton(type: .system)
    private let spedUpButton = UIButton(type: .system)
    private var presetsStack: UIStackView!
    
    // New buttons for rewind and skip
    private let rewindButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)
    
    // New buttons for playlist navigation
    private let previousTrackButton = UIButton(type: .system)
    private let nextTrackButton = UIButton(type: .system)
    
    // Scroll View for main content
    private let scrollView = UIScrollView()
    
    // Gesture Recognizers
    private let albumArtTapGesture = UITapGestureRecognizer()
    
    // Settings state
    private var isAccuratePitchEnabled = false
    private var isAccurateSpeedEnabled = false
    private var lastSnappedPitchValue: Float = 0.0 // To track discrete pitch changes for haptics
    private var lastSnappedSpeedValue: Float = 1.0 // To track discrete speed changes for haptics
    private var isLoopingEnabled = false
    private var isRememberSettingsEnabled = false
    private var isAutoPlayNextEnabled = false
    private var isStepperEnabled = false
    private var isShowPresetsEnabled = true
    
    // Library state
    private var currentSong: Song?
    private var accumulatedPlaybackTime: TimeInterval = 0
    private var hasRecordedRecentlyPlayed = false
    private var isShuffling = false
    private var isPlayingFromFavorites = false
    private var playbackQueue: [Song] = [] {
        didSet {
            if #available(iOS 14.0, *) { } else {
                MPPlayableContentManager.shared().reloadData()
            }
        }
    }
    private var currentQueueIndex: Int = -1
    private var currentPresetIndex: Int?
    
    // Cached initial values
    private var initialSavedPitch: Float = 0
    private var initialSavedSpeed: Float = 1.0
    private var initialSavedReverb: Float = 0
    private var initialSavedBass: Float = 0
    private var initialSavedMids: Float = 0
    private var initialSavedTreble: Float = 0

    // MARK: View Lifecycle
    
    private var hasLoadedInitialState = false

    override func viewDidLoad() {
        // Cache initial slider values before any UI initialization can overwrite them
        self.initialSavedPitch = UserDefaults.standard.float(forKey: "pitchValue")
        let savedSpeedObj = UserDefaults.standard.object(forKey: "speedValue")
        self.initialSavedSpeed = savedSpeedObj != nil ? UserDefaults.standard.float(forKey: "speedValue") : 1.0
        self.initialSavedReverb = UserDefaults.standard.float(forKey: "reverbValue")
        self.initialSavedBass = UserDefaults.standard.float(forKey: "bassValue")
        self.initialSavedMids = UserDefaults.standard.float(forKey: "midsValue")
        self.initialSavedTreble = UserDefaults.standard.float(forKey: "trebleValue")
        
        self.isAccurateSpeedEnabled = UserDefaults.standard.bool(forKey: "isAccurateSpeedEnabled")
        self.isAccuratePitchEnabled = UserDefaults.standard.bool(forKey: "isAccuratePitchEnabled")
        self.isLoopingEnabled = UserDefaults.standard.bool(forKey: "isLoopingEnabled")
        self.isRememberSettingsEnabled = UserDefaults.standard.bool(forKey: "isRememberSettingsEnabled")
        self.isAutoPlayNextEnabled = UserDefaults.standard.bool(forKey: "isAutoPlayNextEnabled")
        self.isStepperEnabled = UserDefaults.standard.bool(forKey: "isStepperEnabled")
        self.isShowPresetsEnabled = UserDefaults.standard.bool(forKey: "isShowPresetsEnabled", defaultValue: true)
        
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark // Lock the app in dark mode
        setupUI()
        setupQuickActions()
        resetControlsState(isHidden: true)
        setupAudioProcessorHandler()
        setupStatePersistence()
        setupProgressUpdater()
        setupSliderLabelTapGestures(isEnabled: UserDefaults.standard.bool(forKey: "isResetSlidersOnTapEnabled"))
        impactFeedbackGenerator.prepare()
        selectionFeedbackGenerator.prepare()
        setupCarPlay()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // We load state here because it's the first point where `view.window` is guaranteed
        // to be non-nil, which is required for applying the theme's tint color.
        if !hasLoadedInitialState {
            loadSavedState()
            hasLoadedInitialState = true
            updateBackgroundAnimation()
            checkForEmptyLibrary()
        }
    }

    // MARK: UI Setup
    
    private func applyTheme(color: UIColor) {
        view.window?.tintColor = color
        resetButton.setTitleColor(color, for: .normal)
    }
    
    private func checkForEmptyLibrary() {
        if LibraryManager.shared.songs.isEmpty {
            let welcomeVC = WelcomeViewController()
            welcomeVC.delegate = self
            welcomeVC.isModalInPresentation = true
            present(welcomeVC, animated: true)
        }
    }
    
    // MARK: - WelcomeViewControllerDelegate
    
    func welcomeViewControllerDidTapImport(_ controller: WelcomeViewController) {
        controller.dismiss(animated: true) {
            let alert = UIAlertController(title: "Import", message: "What would you like to import?", preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "Audio Files", style: .default, handler: { _ in
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
                picker.delegate = self
                picker.allowsMultipleSelection = true
                picker.overrideUserInterfaceStyle = .dark
                self.present(picker, animated: true)
            }))
            alert.addAction(UIAlertAction(title: "Entire Folder", style: .default, handler: { _ in
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
                picker.delegate = self
                picker.allowsMultipleSelection = false
                picker.overrideUserInterfaceStyle = .dark
                self.present(picker, animated: true)
            }))
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            
            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            self.present(alert, animated: true)
        }
    }
    
    func welcomeViewControllerDidTapDemo(_ controller: WelcomeViewController) {
        controller.dismiss(animated: true) {
            self.loadDemoSong()
        }
    }
    
    // MARK: - UIDocumentPickerDelegate
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            LibraryManager.shared.addSong(from: url)
        }
        if let song = LibraryManager.shared.songs.first {
            self.loadSong(song, andPlay: true)
        }
    }
    
    private func loadDemoSong() {
        guard let url = Bundle.main.url(forResource: "song", withExtension: "mp3") else {
            let alert = UIAlertController(title: "Error", message: "Demo file 'song.mp3' not found in bundle.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        self.currentSong = nil
        UserDefaults.standard.removeObject(forKey: "lastSongID")
        
        if let metadata = audioProcessor.loadAudioFile(url: url) {
            songTitleLabel.text = metadata.title
            artistNameLabel.text = metadata.artist ?? "Demo Artist"
            artistNameLabel.isHidden = false
            
            let image = metadata.artwork ?? UIImage(systemName: "music.note")
            albumArtImageView.image = image
            updateBackground(with: image)
            
            let isDynamicThemeEnabled = UserDefaults.standard.bool(forKey: "isDynamicThemeEnabled")
            applyDynamicTheme(isEnabled: isDynamicThemeEnabled, image: image)
            
            resetControlsState(isHidden: false)
            resetButton.isHidden = false
            saveValuesButton.isHidden = true
            favoriteButton.isHidden = true
            
            // Update progress slider and labels for the new song
            let duration = audioProcessor.getAudioDuration()
            progressSlider.maximumValue = Float(duration)
            durationLabel.text = formatTime(seconds: duration)
            
            togglePlayback()
        }
    }
    
    private func setupAudioProcessorHandler() {
        audioProcessor.onPlaybackStateChanged = { [weak self] in
            self?.updatePlayPauseButtonState()
            self?.audioProcessor.syncNowPlayingInfo()
        }
        audioProcessor.onNextTrack = { [weak self] in self?.playNextSong() }
        audioProcessor.onPreviousTrack = { [weak self] in self?.playPreviousSong() }
        audioProcessor.onCyclePreset = { [weak self] in
            DispatchQueue.main.async {
                self?.cycleToNextPreset()
            }
        }
        
        // Restore rate change handler
        audioProcessor.onPlaybackRateChanged = { [weak self] rate in
            guard let self = self else { return }
            self.speedSlider.setValue(rate, animated: true)
            self.speedLabel.text = String(format: "Speed (%.2fx)", rate)
            UserDefaults.standard.set(rate, forKey: "speedValue")
        }
    }

    private func setupUI() {
        // Background Image and Blur
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backgroundImageView)
        
        // The blur effect view should be a subview of the background image view to fade in together.
        blurEffectView.translatesAutoresizingMaskIntoConstraints = false
        backgroundImageView.addSubview(blurEffectView) // Add blur as a subview
        NSLayoutConstraint.activate([
            blurEffectView.topAnchor.constraint(equalTo: backgroundImageView.topAnchor),
            blurEffectView.bottomAnchor.constraint(equalTo: backgroundImageView.bottomAnchor),
            blurEffectView.leadingAnchor.constraint(equalTo: backgroundImageView.leadingAnchor),
            blurEffectView.trailingAnchor.constraint(equalTo: backgroundImageView.trailingAnchor)
        ])
        blurEffectView.alpha = 1.0 // Always visible when parent is visible
        
        // Set the default background color
        backgroundImageView.alpha = 0 // Parent view is initially hidden
        updateBackground(with: nil, isDynamicEnabled: UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled"))
        
        // The main view background should be clear to see the image behind it
        view.backgroundColor = .black
        
        // Library Button (Top Left)
        libraryButton.setImage(UIImage(systemName: "line.3.horizontal"), for: .normal)
        libraryButton.addTarget(self, action: #selector(openLibrary), for: .touchUpInside)
        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        
        // 1. Album Art Setup
        albumArtImageView.contentMode = .scaleAspectFit
        albumArtImageView.layer.cornerRadius = 12
        albumArtImageView.clipsToBounds = true
        albumArtImageView.backgroundColor = .secondarySystemBackground
        albumArtImageView.image = UIImage(systemName: "music.note")
        albumArtImageView.tintColor = .systemGray
        
        // Enable user interaction and add tap gesture to open file picker
        // CHANGED: Just bounce animation, no action
        albumArtImageView.isUserInteractionEnabled = true
        albumArtTapGesture.addTarget(self, action: #selector(animateAlbumArtBounce))
        albumArtImageView.addGestureRecognizer(albumArtTapGesture)
        
        // 2. Song Title Setup
        songTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        songTitleLabel.textAlignment = .center
        songTitleLabel.numberOfLines = 0 // Allow title to wrap if long
        songTitleLabel.isUserInteractionEnabled = true
        songTitleLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showSearchMenu(_:))))
        
        // Artist Name Setup
        artistNameLabel.font = .italicSystemFont(ofSize: 16) // Increased font size
        artistNameLabel.textColor = .secondaryLabel
        artistNameLabel.textAlignment = .center
        artistNameLabel.numberOfLines = 0
        artistNameLabel.isUserInteractionEnabled = true
        artistNameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showSearchMenu(_:))))
        
        let songInfoStack = UIStackView(arrangedSubviews: [songTitleLabel, artistNameLabel])
        songInfoStack.axis = .vertical
        songInfoStack.spacing = 4

        // Center text for labels
        speedLabel.textAlignment = .center
        pitchLabel.textAlignment = .center
        reverbLabel.textAlignment = .center
        bassLabel.textAlignment = .center
        midsLabel.textAlignment = .center
        trebleLabel.textAlignment = .center
        songTitleLabel.text = "No File Loaded"

        // 3. Play/Pause Button
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        // Make play/pause button larger and square
        playPauseButton.imageView?.contentMode = .scaleAspectFit
        playPauseButton.contentVerticalAlignment = .fill
        playPauseButton.contentHorizontalAlignment = .fill
        playPauseButton.imageEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10) // Add some padding

        // Rewind 10s button
        rewindButton.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        rewindButton.addTarget(self, action: #selector(rewind10Seconds), for: .touchUpInside)

        // Skip 10s button
        skipButton.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        skipButton.addTarget(self, action: #selector(skip10Seconds), for: .touchUpInside)
        
        // Previous Track button
        previousTrackButton.setImage(UIImage(systemName: "backward.end.fill"), for: .normal)
        previousTrackButton.addTarget(self, action: #selector(playPreviousSong), for: .touchUpInside)
        
        // Next Track button
        nextTrackButton.setImage(UIImage(systemName: "forward.end.fill"), for: .normal)
        nextTrackButton.addTarget(self, action: #selector(playNextSong), for: .touchUpInside)

        // Progress Slider & Labels
        progressSlider.minimumValue = 0
        progressSlider.addTarget(self, action: #selector(progressSliderScrubbing), for: .valueChanged)
        
        currentTimeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        currentTimeLabel.text = "0:00"
        
        durationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        durationLabel.text = "0:00"
        
        // Create a horizontal stack view for the slider and its time labels
        let progressStack = UIStackView(arrangedSubviews: [currentTimeLabel, progressSlider, durationLabel])
        progressStack.axis = .horizontal
        progressStack.spacing = 10
        progressStack.alignment = .center

        // Give the labels a fixed width so the slider can fill the remaining space
        currentTimeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        durationLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        // Horizontal stack for playback controls (rewind, play/pause, skip)
        let playbackControlsStack = UIStackView(arrangedSubviews: [previousTrackButton, rewindButton, playPauseButton, skipButton, nextTrackButton])
        playbackControlsStack.axis = .horizontal
        playbackControlsStack.alignment = .center
        playbackControlsStack.distribution = .equalSpacing // Distribute space evenly

        // Pitch Slider Setup (Pitch: -12 semitones to +12 semitones)
        pitchLabel.text = "Pitch (0 st)"
        pitchSlider.minimumValue = -1200 // -12 semitones in cents
        pitchSlider.maximumValue = 1200  // +12 semitones in cents
        pitchSlider.value = 0
        pitchSlider.addTarget(self, action: #selector(pitchSliderChanged), for: .valueChanged)

        // 4. Speed Slider Setup (Rate: 0.5 to 2.0)
        speedLabel.text = "Speed (1.0x)"
        speedSlider.minimumValue = 0.5
        speedSlider.maximumValue = 2.0
        speedSlider.value = 1.0
        speedSlider.addTarget(self, action: #selector(speedSliderChanged), for: .valueChanged)

        // 5. Reverb Slider Setup (Mix: 0.0 to 100.0)
        reverbLabel.text = "Reverb (0%)"
        reverbSlider.minimumValue = 0.0
        reverbSlider.maximumValue = 100.0
        reverbSlider.value = 0.0
        reverbSlider.addTarget(self, action: #selector(reverbSliderChanged), for: .valueChanged)
        // Initialize reverb slider visibility based on saved settings
        let isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
        reverbLabel.isHidden = !isReverbSliderEnabled
        reverbSlider.isHidden = !isReverbSliderEnabled
        
        // EQ Sliders Setup (Gain: -12dB to +12dB)
        bassLabel.text = "Bass (0 dB)"
        bassSlider.minimumValue = -12
        bassSlider.maximumValue = 12
        bassSlider.value = 0
        bassSlider.addTarget(self, action: #selector(bassSliderChanged), for: .valueChanged)
        
        midsLabel.text = "Mids (0 dB)"
        midsSlider.minimumValue = -12
        midsSlider.maximumValue = 12
        midsSlider.value = 0
        midsSlider.addTarget(self, action: #selector(midsSliderChanged), for: .valueChanged)
        
        trebleLabel.text = "Treble (0 dB)"
        trebleSlider.minimumValue = -12
        trebleSlider.maximumValue = 12
        trebleSlider.value = 0
        trebleSlider.addTarget(self, action: #selector(trebleSliderChanged), for: .valueChanged)
        
        // Initialize EQ slider visibility based on saved settings
        let isEQEnabled = UserDefaults.standard.bool(forKey: "isEQEnabled")
        [bassLabel, bassSlider, midsLabel, midsSlider, trebleLabel, trebleSlider].forEach {
            $0.isHidden = !isEQEnabled
        }
        
        // 6. Reset Button Setup (replaces File Picker button)
        // Group the effect sliders with their labels for consistent spacing
        setupStepperButton(pitchMinusButton, imageName: "minus", action: #selector(decrementPitch))
        setupStepperButton(pitchPlusButton, imageName: "plus", action: #selector(incrementPitch))
        pitchControlStack = createControlStack(label: pitchLabel, slider: pitchSlider, minusButton: pitchMinusButton, plusButton: pitchPlusButton)
        
        setupStepperButton(speedMinusButton, imageName: "minus", action: #selector(decrementSpeed))
        setupStepperButton(speedPlusButton, imageName: "plus", action: #selector(incrementSpeed))
        let speedControlStack = createControlStack(label: speedLabel, slider: speedSlider, minusButton: speedMinusButton, plusButton: speedPlusButton)
        
        setupStepperButton(reverbMinusButton, imageName: "minus", action: #selector(decrementReverb))
        setupStepperButton(reverbPlusButton, imageName: "plus", action: #selector(incrementReverb))
        let reverbControlStack = createControlStack(label: reverbLabel, slider: reverbSlider, minusButton: reverbMinusButton, plusButton: reverbPlusButton)
        
        setupStepperButton(bassMinusButton, imageName: "minus", action: #selector(decrementBass))
        setupStepperButton(bassPlusButton, imageName: "plus", action: #selector(incrementBass))
        let bassControlStack = createControlStack(label: bassLabel, slider: bassSlider, minusButton: bassMinusButton, plusButton: bassPlusButton)
        
        setupStepperButton(midsMinusButton, imageName: "minus", action: #selector(decrementMids))
        setupStepperButton(midsPlusButton, imageName: "plus", action: #selector(incrementMids))
        let midsControlStack = createControlStack(label: midsLabel, slider: midsSlider, minusButton: midsMinusButton, plusButton: midsPlusButton)
        
        setupStepperButton(trebleMinusButton, imageName: "minus", action: #selector(decrementTreble))
        setupStepperButton(treblePlusButton, imageName: "plus", action: #selector(incrementTreble))
        let trebleControlStack = createControlStack(label: trebleLabel, slider: trebleSlider, minusButton: trebleMinusButton, plusButton: treblePlusButton)
        
        // Save Values Button
        var saveValuesConfig = UIButton.Configuration.filled()
        saveValuesConfig.title = "Save Values"
        saveValuesConfig.baseBackgroundColor = .secondarySystemFill
        saveValuesConfig.baseForegroundColor = .label
        saveValuesConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        saveValuesConfig.titleLineBreakMode = .byTruncatingTail
        saveValuesButton.configuration = saveValuesConfig
        saveValuesButton.titleLabel?.adjustsFontSizeToFitWidth = true
        saveValuesButton.titleLabel?.minimumScaleFactor = 0.5
        saveValuesButton.addTarget(self, action: #selector(saveValuesTapped), for: .touchUpInside)
        
        // Remove Vocals Button
        var removeVocalsConfig = UIButton.Configuration.filled()
        removeVocalsConfig.title = "Reduce Vocals"
        removeVocalsConfig.baseBackgroundColor = .secondarySystemFill
        removeVocalsConfig.baseForegroundColor = .label
        removeVocalsConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        removeVocalsConfig.titleLineBreakMode = .byTruncatingTail
        removeVocalsButton.configuration = removeVocalsConfig
        removeVocalsButton.titleLabel?.adjustsFontSizeToFitWidth = true
        removeVocalsButton.titleLabel?.minimumScaleFactor = 0.5
        removeVocalsButton.addTarget(self, action: #selector(removeVocalsTapped), for: .touchUpInside)
        
        // Generate Spectrogram Button
        var spectrogramConfig = UIButton.Configuration.filled()
        spectrogramConfig.title = "Convert to Spectrogram"
        spectrogramConfig.baseBackgroundColor = .secondarySystemFill
        spectrogramConfig.baseForegroundColor = .label
        spectrogramConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        spectrogramConfig.titleLineBreakMode = .byTruncatingTail
        generateSpectrogramButton.configuration = spectrogramConfig
        generateSpectrogramButton.titleLabel?.adjustsFontSizeToFitWidth = true
        generateSpectrogramButton.titleLabel?.minimumScaleFactor = 0.5
        generateSpectrogramButton.addTarget(self, action: #selector(generateSpectrogramTapped), for: .touchUpInside)
        
        // Favorite Button
        var favConfig = UIButton.Configuration.filled()
        favConfig.title = "Favorite"
        favConfig.image = UIImage(systemName: "heart")
        favConfig.imagePadding = 8
        favConfig.baseBackgroundColor = .secondarySystemFill
        favConfig.baseForegroundColor = .label
        favConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        favConfig.titleLineBreakMode = .byTruncatingTail
        favoriteButton.configuration = favConfig
        favoriteButton.titleLabel?.adjustsFontSizeToFitWidth = true
        favoriteButton.titleLabel?.minimumScaleFactor = 0.5
        favoriteButton.addTarget(self, action: #selector(toggleFavoriteTapped), for: .touchUpInside)
        
        // Repeat Button
        var repeatConfig = UIButton.Configuration.filled()
        repeatConfig.title = "Repeat"
        repeatConfig.image = UIImage(systemName: "repeat")
        repeatConfig.imagePadding = 8
        repeatConfig.baseBackgroundColor = .secondarySystemFill
        repeatConfig.baseForegroundColor = .label
        repeatConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        repeatConfig.titleLineBreakMode = .byTruncatingTail
        repeatButton.configuration = repeatConfig
        repeatButton.titleLabel?.adjustsFontSizeToFitWidth = true
        repeatButton.titleLabel?.minimumScaleFactor = 0.5
        repeatButton.addTarget(self, action: #selector(toggleRepeatTapped), for: .touchUpInside)
        
        // Queue Button
        var queueConfig = UIButton.Configuration.filled()
        queueConfig.title = "Queue"
        queueConfig.image = UIImage(systemName: "list.bullet")
        queueConfig.imagePadding = 8
        queueConfig.baseBackgroundColor = .secondarySystemFill
        queueConfig.baseForegroundColor = .label
        queueConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        queueConfig.titleLineBreakMode = .byTruncatingTail
        queueButton.configuration = queueConfig
        queueButton.titleLabel?.adjustsFontSizeToFitWidth = true
        queueButton.titleLabel?.minimumScaleFactor = 0.5
        queueButton.addTarget(self, action: #selector(openQueue), for: .touchUpInside)
        
        let favRepeatStack = UIStackView(arrangedSubviews: [favoriteButton, repeatButton])
        favRepeatStack.axis = .horizontal
        favRepeatStack.spacing = 20
        favRepeatStack.distribution = .fillEqually
        
        let extraActionsStack = UIStackView(arrangedSubviews: [favRepeatStack, queueButton])
        extraActionsStack.axis = .vertical
        extraActionsStack.spacing = 12
        extraActionsStack.distribution = .fill
        
        // Settings Icon Button (Top Right)
        settingsIconButton.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        settingsIconButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        settingsIconButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsIconButton)
        
        var resetButtonConfig = UIButton.Configuration.filled()
        resetButtonConfig.title = "Reset Values"
        resetButtonConfig.baseBackgroundColor = .secondarySystemFill
        resetButtonConfig.baseForegroundColor = .label
        resetButtonConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        resetButtonConfig.titleLineBreakMode = .byTruncatingTail
        resetButton.configuration = resetButtonConfig
        resetButton.titleLabel?.adjustsFontSizeToFitWidth = true
        resetButton.titleLabel?.minimumScaleFactor = 0.5
        resetButton.addTarget(self, action: #selector(resetSliders), for: .touchUpInside)

        // Export Button Setup
        var exportButtonConfig = UIButton.Configuration.filled()
        exportButtonConfig.title = "Export"
        exportButtonConfig.baseBackgroundColor = .secondarySystemFill
        exportButtonConfig.baseForegroundColor = .label
        exportButtonConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        exportButtonConfig.titleLineBreakMode = .byTruncatingTail
        exportButton.configuration = exportButtonConfig
        exportButton.titleLabel?.adjustsFontSizeToFitWidth = true
        exportButton.titleLabel?.minimumScaleFactor = 0.5
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
        
        // Preset Buttons Setup
        var slowedReverbConfig = UIButton.Configuration.filled()
        slowedReverbConfig.title = "Slowed + Reverb"
        slowedReverbConfig.baseBackgroundColor = .secondarySystemFill
        slowedReverbConfig.baseForegroundColor = .label
        slowedReverbConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        slowedReverbConfig.titleLineBreakMode = .byTruncatingTail
        slowedReverbButton.configuration = slowedReverbConfig
        slowedReverbButton.titleLabel?.adjustsFontSizeToFitWidth = true
        slowedReverbButton.titleLabel?.minimumScaleFactor = 0.5
        slowedReverbButton.addTarget(self, action: #selector(applySlowedReverbPreset), for: .touchUpInside)
        
        var spedUpConfig = UIButton.Configuration.filled()
        spedUpConfig.title = "Sped Up"
        spedUpConfig.baseBackgroundColor = .secondarySystemFill
        spedUpConfig.baseForegroundColor = .label
        spedUpConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10)
        spedUpConfig.titleLineBreakMode = .byTruncatingTail
        spedUpButton.configuration = spedUpConfig
        spedUpButton.titleLabel?.adjustsFontSizeToFitWidth = true
        spedUpButton.titleLabel?.minimumScaleFactor = 0.5
        spedUpButton.addTarget(self, action: #selector(applySpedUpPreset), for: .touchUpInside)
        
        // Horizontal stack for Preset buttons
        presetsStack = UIStackView(arrangedSubviews: [slowedReverbButton, spedUpButton])
        presetsStack.axis = .horizontal
        presetsStack.spacing = 20
        presetsStack.distribution = .fillEqually
        presetsStack.isHidden = !isShowPresetsEnabled

        let saveAndResetStack = UIStackView(arrangedSubviews: [saveValuesButton, resetButton])
        saveAndResetStack.axis = .horizontal
        saveAndResetStack.spacing = 20
        saveAndResetStack.distribution = .fillEqually
        
        let bottomActionsStack = UIStackView(arrangedSubviews: [saveAndResetStack, generateSpectrogramButton, removeVocalsButton, exportButton])
        bottomActionsStack.axis = .vertical
        bottomActionsStack.spacing = 50
        bottomActionsStack.distribution = .fill

        // 7. Stack View for Layout
        let stackView = UIStackView(arrangedSubviews: [
            albumArtImageView,
            songInfoStack,
            progressStack, // Keep progress stack above playback controls
            playbackControlsStack, // Use the new playback controls stack here
            pitchControlStack,
            speedControlStack,
            reverbControlStack,
            bassControlStack,
            midsControlStack,
            trebleControlStack,
            UIView(), // Spacer
            presetsStack,
            extraActionsStack,
            bottomActionsStack
        ])
        
        stackView.axis = .vertical
        stackView.spacing = 20
        // Set custom spacing to create groups of controls
        stackView.setCustomSpacing(30, after: playbackControlsStack)
        stackView.setCustomSpacing(12, after: pitchControlStack)
        stackView.setCustomSpacing(12, after: speedControlStack)
        stackView.setCustomSpacing(12, after: reverbControlStack)
        stackView.setCustomSpacing(12, after: bassControlStack)
        stackView.setCustomSpacing(12, after: midsControlStack)
        stackView.setCustomSpacing(20, after: trebleControlStack)
        stackView.setCustomSpacing(50, after: presetsStack)
        stackView.setCustomSpacing(50, after: extraActionsStack)
        
        // The spacer view should have a low-priority constraint to allow it to shrink
        if let spacer = stackView.arrangedSubviews[7] as? UIView {
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        }
        
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(libraryButton)
        view.addSubview(stackView)
        
        // Setup ScrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        
        // Set alignment for grouped controls
        pitchControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        speedControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        reverbControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        bassControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        midsControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        trebleControlStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        
        // Bring buttons to the front so they don't get scrolled over
        view.bringSubviewToFront(libraryButton)
        view.bringSubviewToFront(settingsIconButton)
        // Auto Layout Constraints
        NSLayoutConstraint.activate([
            // Background constraints
            backgroundImageView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            
            // Library button in top left
            libraryButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            libraryButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            libraryButton.widthAnchor.constraint(equalToConstant: 30),
            libraryButton.heightAnchor.constraint(equalToConstant: 30),
            
            // Settings button in top right
            settingsIconButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            settingsIconButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            settingsIconButton.widthAnchor.constraint(equalToConstant: 30),
            settingsIconButton.heightAnchor.constraint(equalToConstant: 30),
            
            // ScrollView constraints
            scrollView.topAnchor.constraint(equalTo: libraryButton.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            // StackView constraints inside ScrollView
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 30),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -30),
            
            // This is crucial: make the stackView's width equal to the scrollView's frame width (minus padding)
            // to enable vertical-only scrolling.
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -60),
            
            // Album Art size constraint
            albumArtImageView.heightAnchor.constraint(equalTo: albumArtImageView.widthAnchor, multiplier: 1.0),
            albumArtImageView.widthAnchor.constraint(equalTo: stackView.widthAnchor, multiplier: 0.7), // 70% width
            
            // Make sliders and button take up more width
            progressStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            bottomActionsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            extraActionsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            presetsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
        
        // Constraints for the new playback control buttons
        playbackControlsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true // Ensure the stack fills the width
        
        playPauseButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: 0.22).isActive = true
        playPauseButton.heightAnchor.constraint(equalTo: playPauseButton.widthAnchor).isActive = true
        
        let secondaryButtonMultiplier = 0.13
        
        rewindButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: secondaryButtonMultiplier).isActive = true
        rewindButton.heightAnchor.constraint(equalTo: rewindButton.widthAnchor).isActive = true
        previousTrackButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: secondaryButtonMultiplier).isActive = true
        previousTrackButton.heightAnchor.constraint(equalTo: previousTrackButton.widthAnchor).isActive = true
        skipButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: secondaryButtonMultiplier).isActive = true
        skipButton.heightAnchor.constraint(equalTo: skipButton.widthAnchor).isActive = true
        nextTrackButton.widthAnchor.constraint(equalTo: playbackControlsStack.widthAnchor, multiplier: secondaryButtonMultiplier).isActive = true
        nextTrackButton.heightAnchor.constraint(equalTo: nextTrackButton.widthAnchor).isActive = true
    }
    
    private func setupStepperButton(_ button: UIButton, imageName: String, action: Selector) {
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    
    private func createControlStack(label: UILabel, slider: UISlider, minusButton: UIButton, plusButton: UIButton) -> UIStackView {
        let hStack = UIStackView(arrangedSubviews: [minusButton, slider, plusButton])
        hStack.axis = .horizontal
        hStack.spacing = 10
        hStack.alignment = .center
        
        let vStack = UIStackView(arrangedSubviews: [label, hStack])
        vStack.axis = .vertical
        vStack.spacing = 8
        return vStack
    }
    
    private func updateBackgroundAnimation() {
        let isAnimated = UserDefaults.standard.bool(forKey: "isAnimatedBackgroundEnabled", defaultValue: true)
        
        // Always remove existing animations to avoid conflicts
        backgroundImageView.layer.removeAllAnimations()
        
        if isAnimated {
            UIView.animate(withDuration: 20, delay: 0, options: [.allowUserInteraction, .autoreverse, .repeat], animations: {
                self.backgroundImageView.transform = CGAffineTransform(scaleX: 1.8, y: 1.8)
            })
        } else {
            // Reset transform if animation is disabled
            backgroundImageView.transform = .identity
        }
    }
    
    /// Hides/shows the controls until a file is loaded.
    private func resetControlsState(isHidden: Bool) {
        // Enable/Disable Lock Screen Next/Prev buttons based on whether a file is loaded
        audioProcessor.updatePlaylistRemoteCommands(isEnabled: !isHidden)
        
        playPauseButton.isHidden = isHidden
        rewindButton.isHidden = isHidden
        skipButton.isHidden = isHidden
        previousTrackButton.isHidden = isHidden
        nextTrackButton.isHidden = isHidden
        resetButton.isHidden = isHidden
        generateSpectrogramButton.isHidden = isHidden
        removeVocalsButton.isHidden = isHidden
        saveValuesButton.isHidden = isHidden
        favoriteButton.isHidden = isHidden
        repeatButton.isHidden = isHidden
        queueButton.isHidden = isHidden
        exportButton.isHidden = isHidden
        progressSlider.isHidden = isHidden
        currentTimeLabel.isHidden = isHidden
        durationLabel.isHidden = isHidden
        
        pitchLabel.isHidden = isHidden
        pitchSlider.isHidden = isHidden
        speedLabel.isHidden = isHidden
        speedSlider.isHidden = isHidden
        reverbLabel.isHidden = isHidden
        reverbSlider.isHidden = isHidden
        
        bassLabel.isHidden = isHidden
        bassSlider.isHidden = isHidden
        midsLabel.isHidden = isHidden
        midsSlider.isHidden = isHidden
        trebleLabel.isHidden = isHidden
        trebleSlider.isHidden = isHidden
        
        // Handle stepper visibility based on global hidden state, user preference, and individual slider visibility
        updateStepperVisibility()

        // When controls are being hidden, also hide the artist label.
        // When controls are shown, its visibility will be determined by `loadAudioFile`.
        artistNameLabel.isHidden = isHidden
        
        // Reset to initial values
        if isHidden || !isRememberSettingsEnabled {
            if hasLoadedInitialState {
                resetSliders()
            }
        }
        
        playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
    }
    
    private func updateStepperVisibility() {
        // If global stepper setting is off, or no song is loaded (playPauseButton is hidden), hide all.
        guard isStepperEnabled, !playPauseButton.isHidden else {
            [pitchMinusButton, pitchPlusButton, speedMinusButton, speedPlusButton,
             reverbMinusButton, reverbPlusButton, bassMinusButton, bassPlusButton,
             midsMinusButton, midsPlusButton, trebleMinusButton, treblePlusButton]
                .forEach { $0.isHidden = true }
            return
        }

        // Pitch and Speed are always visible when file is loaded
        pitchMinusButton.isHidden = false
        pitchPlusButton.isHidden = false
        speedMinusButton.isHidden = false
        speedPlusButton.isHidden = false

        // Reverb
        let isReverbOn = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
        reverbMinusButton.isHidden = !isReverbOn
        reverbPlusButton.isHidden = !isReverbOn

        // EQ
        let isEQOn = UserDefaults.standard.bool(forKey: "isEQEnabled")
        [bassMinusButton, bassPlusButton,
         midsMinusButton, midsPlusButton,
         trebleMinusButton, treblePlusButton].forEach { $0.isHidden = !isEQOn }
    }
    
    /// Resets only the effect sliders to their default values.
    @objc private func resetSliders() {
        speedSlider.value = 1.0
        pitchSlider.value = 0.0
        lastSnappedSpeedValue = 1.0 // Reset for haptics
        lastSnappedPitchValue = 0.0 // Reset for haptics
        reverbSlider.value = 0.0
        bassSlider.value = 0.0
        midsSlider.value = 0.0
        trebleSlider.value = 0.0

        // Trigger the change handlers to update labels and the audio processor
        speedSliderChanged(speedSlider)
        pitchSliderChanged(pitchSlider)
        reverbSliderChanged(reverbSlider)
        bassSliderChanged(bassSlider)
        midsSliderChanged(midsSlider)
        trebleSliderChanged(trebleSlider)
        impactFeedbackGenerator.impactOccurred() // Add haptic feedback for the global reset button
    }
    
    @objc private func resetPitchSlider() {
        pitchSlider.value = 0.0
        lastSnappedPitchValue = 0.0 // Reset for haptics
        pitchSliderChanged(pitchSlider)
        impactFeedbackGenerator.impactOccurred()
    }

    @objc private func resetSpeedSlider() {
        speedSlider.value = 1.0
        speedSliderChanged(speedSlider)
        lastSnappedSpeedValue = 1.0 // Reset for haptics
        impactFeedbackGenerator.impactOccurred()
    }


    @objc private func resetReverbSlider() {
        reverbSlider.value = 0.0
        reverbSliderChanged(reverbSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func resetBassSlider() {
        bassSlider.value = 0.0
        bassSliderChanged(bassSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func resetMidsSlider() {
        midsSlider.value = 0.0
        midsSliderChanged(midsSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func resetTrebleSlider() {
        trebleSlider.value = 0.0
        trebleSliderChanged(trebleSlider)
        impactFeedbackGenerator.impactOccurred()
    }

    // MARK: State Persistence
    
    private func setupStatePersistence() {
        NotificationCenter.default.addObserver(self, selector: #selector(savePlaybackPosition), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(savePlaybackPosition), name: UIApplication.willTerminateNotification, object: nil)
        if #available(iOS 13.0, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(savePlaybackPosition), name: UIScene.didDisconnectNotification, object: nil)
        }
    }
    
    @objc private func savePlaybackPosition() {
        UserDefaults.standard.set(audioProcessor.getCurrentTime(), forKey: "lastPlaybackPosition")
        
        // Save Queue State
        let queueIDs = playbackQueue.map { $0.id.uuidString }
        UserDefaults.standard.set(queueIDs, forKey: "savedPlaybackQueue")
        UserDefaults.standard.set(currentQueueIndex, forKey: "savedQueueIndex")
        UserDefaults.standard.set(isShuffling, forKey: "savedIsShuffling")
        UserDefaults.standard.set(isPlayingFromFavorites, forKey: "savedIsPlayingFromFavorites")
    }
    
    private func loadSavedState() {
        // Restore settings regardless of whether a file is loaded
        let isPitchLinked = UserDefaults.standard.bool(forKey: "isPitchLinked")
        settingsViewController(SettingsViewController(), didChangeLinkPitchState: isPitchLinked)
        
        let isDynamicBackgroundEnabled = UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled")
        let isAnimatedBackgroundEnabled = UserDefaults.standard.bool(forKey: "isAnimatedBackgroundEnabled", defaultValue: true)
        let isDynamicThemeEnabled = UserDefaults.standard.bool(forKey: "isDynamicThemeEnabled")
        let isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
        let isResetSlidersOnTapEnabled = UserDefaults.standard.bool(forKey: "isResetSlidersOnTapEnabled")
        let isTapArtworkToChangeSongEnabled = UserDefaults.standard.bool(forKey: "isTapArtworkToChangeSongEnabled")
        let isAccuratePitchEnabled = UserDefaults.standard.bool(forKey: "isAccuratePitchEnabled")
        let isAccurateSpeedEnabled = UserDefaults.standard.bool(forKey: "isAccurateSpeedEnabled")
        let isExportButtonEnabled = UserDefaults.standard.bool(forKey: "isExportButtonEnabled", defaultValue: true)
        let isEQEnabled = UserDefaults.standard.bool(forKey: "isEQEnabled")
        let isAlbumArtVisible = UserDefaults.standard.bool(forKey: "isAlbumArtVisible", defaultValue: true)
        let isLoopingEnabled = UserDefaults.standard.bool(forKey: "isLoopingEnabled")
        let isRememberSettingsEnabled = UserDefaults.standard.bool(forKey: "isRememberSettingsEnabled")
        let isStepperEnabled = UserDefaults.standard.bool(forKey: "isStepperEnabled")
        
        settingsViewController(SettingsViewController(), didChangeReverbSliderState: isReverbSliderEnabled)
        settingsViewController(SettingsViewController(), didChangeAnimatedBackgroundState: isAnimatedBackgroundEnabled)
        settingsViewController(SettingsViewController(), didChangeDynamicBackgroundState: isDynamicBackgroundEnabled)
        settingsViewController(SettingsViewController(), didChangeDynamicThemeState: isDynamicThemeEnabled)
        settingsViewController(SettingsViewController(), didChangeResetSlidersOnTapState: isResetSlidersOnTapEnabled)
        settingsViewController(SettingsViewController(), didChangeTapArtworkToChangeSongState: isTapArtworkToChangeSongEnabled)
        settingsViewController(SettingsViewController(), didChangePrecisePitchState: isAccuratePitchEnabled)
        settingsViewController(SettingsViewController(), didChangeAccurateSpeedState: isAccurateSpeedEnabled)
        settingsViewController(SettingsViewController(), didChangeShowExportButtonState: isExportButtonEnabled)
        settingsViewController(SettingsViewController(), didChangeShowEQState: isEQEnabled)
        settingsViewController(SettingsViewController(), didChangeShowAlbumArtState: isAlbumArtVisible)
        settingsViewController(SettingsViewController(), didChangeLoopingState: isLoopingEnabled)
        settingsViewController(SettingsViewController(), didChangeRememberSettingsState: isRememberSettingsEnabled)
        settingsViewController(SettingsViewController(), didChangeAutoPlayNextState: isAutoPlayNextEnabled)
        settingsViewController(SettingsViewController(), didChangeStepperState: isStepperEnabled)
        
        // Restore Queue
        if let queueIDs = UserDefaults.standard.stringArray(forKey: "savedPlaybackQueue") {
            let allSongs = LibraryManager.shared.songs
            let songMap = Dictionary(allSongs.map { ($0.id, $0) }, uniquingKeysWith: { (first, _) in first })
            
            var restoredQueue: [Song] = []
            for idString in queueIDs {
                if let uuid = UUID(uuidString: idString), let song = songMap[uuid] {
                    restoredQueue.append(song)
                }
            }
            
            self.playbackQueue = restoredQueue
            self.currentQueueIndex = UserDefaults.standard.integer(forKey: "savedQueueIndex")
            self.isShuffling = UserDefaults.standard.bool(forKey: "savedIsShuffling")
            self.isPlayingFromFavorites = UserDefaults.standard.bool(forKey: "savedIsPlayingFromFavorites")
            
            // Validate index
            if !self.playbackQueue.isEmpty {
                if self.currentQueueIndex < 0 || self.currentQueueIndex >= self.playbackQueue.count {
                    self.currentQueueIndex = 0
                }
            } else {
                self.currentQueueIndex = -1
            }
        }
        
        // Restore the last audio file
        // Restore the last audio file first, as it provides the artwork for dynamic theming.
        guard let lastSongIDString = UserDefaults.standard.string(forKey: "lastSongID"),
              let lastSongID = UUID(uuidString: lastSongIDString),
              let song = LibraryManager.shared.songs.first(where: { $0.id == lastSongID }) else {
            return
        }
        
        do {
                // Load the file but don't auto-play
                loadSong(song, andPlay: false)
            
                // Restore slider values AFTER loading the song so they aren't reset to defaults
                pitchSlider.value = initialSavedPitch
                pitchSliderChanged(pitchSlider)
                
                speedSlider.value = initialSavedSpeed != 0 ? initialSavedSpeed : 1.0 // Default to 1.0 if not set
                speedSliderChanged(speedSlider)
                
                reverbSlider.value = initialSavedReverb
                reverbSliderChanged(reverbSlider)
                
                bassSlider.value = initialSavedBass
                bassSliderChanged(bassSlider)
                
                midsSlider.value = initialSavedMids
                midsSliderChanged(midsSlider)
                
                trebleSlider.value = initialSavedTreble
                trebleSliderChanged(trebleSlider)
                
                // Restore playback position after the file is loaded
                let lastPosition = UserDefaults.standard.double(forKey: "lastPlaybackPosition")
                if lastPosition > 0 {
                    audioProcessor.seek(to: lastPosition)
                    progressSlider.value = Float(lastPosition)
                    currentTimeLabel.text = formatTime(seconds: lastPosition)
                }
        }
    }
    
    @objc private func clearState() {
        audioProcessor.togglePlayback() // Stop playback if active
        
        // Clear only file-related UserDefaults
        UserDefaults.standard.removeObject(forKey: "lastSongID")
        UserDefaults.standard.removeObject(forKey: "lastPlaybackPosition")
        
        // Clear Queue State
        UserDefaults.standard.removeObject(forKey: "savedPlaybackQueue")
        UserDefaults.standard.removeObject(forKey: "savedQueueIndex")
        UserDefaults.standard.removeObject(forKey: "savedIsShuffling")
        UserDefaults.standard.removeObject(forKey: "savedIsPlayingFromFavorites")
        
        UserDefaults.standard.synchronize()
        
        // Reset UI to initial state
        resetControlsState(isHidden: true)
        songTitleLabel.text = "No File Loaded"
        albumArtImageView.image = UIImage(systemName: "music.note")
        artistNameLabel.text = nil
        updateBackground(with: nil)
        print("State cleared and UI reset.")
        audioProcessor.clearNowPlayingInfo() // Clear lock screen info
    }

    // MARK: Progress Tracking
    
    private func setupProgressUpdater() {
        progressUpdateTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(updateProgress), userInfo: nil, repeats: true)
    }
    
    @objc private func updateProgress() {
        let currentTime = audioProcessor.getCurrentTime()
        let duration = audioProcessor.getAudioDuration()
        
        progressSlider.value = Float(currentTime)
        currentTimeLabel.text = formatTime(seconds: currentTime)
        
        // Update lock screen elapsed time only when actually playing
        if audioProcessor.isCurrentlyPlaying() {
            audioProcessor.syncNowPlayingInfo()
        }
        
        guard audioProcessor.isCurrentlyPlaying() else { return }
        
        accumulatedPlaybackTime += 0.1
        if !hasRecordedRecentlyPlayed && accumulatedPlaybackTime >= 30.0 {
            if var song = currentSong {
                song.lastPlayedDate = Date()
                LibraryManager.shared.updateSong(song)
                currentSong = song
                hasRecordedRecentlyPlayed = true
            }
        }
        
        // If song finishes, update play button icon
        if currentTime >= duration {
            if isLoopingEnabled {
                audioProcessor.seek(to: 0)
                progressSlider.value = 0
                currentTimeLabel.text = formatTime(seconds: 0)
            } else if isAutoPlayNextEnabled {
                playNextSong()
            } else {
                audioProcessor.pause()
                audioProcessor.seek(to: 0)
                playPauseButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
                progressSlider.value = 0 // Reset slider to beginning
                currentTimeLabel.text = formatTime(seconds: 0)
            }
        }
    }
    
    private func formatTime(seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "0:00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    // MARK: Actions

    @objc func togglePlayback() {
        audioProcessor.togglePlayback()
        updatePlayPauseButtonState()
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func openLibrary() {
        presentLibrary(withSearch: nil)
    }
    
    private func presentLibrary(withSearch query: String?, exactField: String? = nil) {
        let libraryVC = LibraryViewController()
        libraryVC.showFavoritesOnly = false
        libraryVC.delegate = self
        libraryVC.currentSongID = self.currentSong?.id
        libraryVC.initialSearchQuery = query
        if let query = query, let field = exactField {
            libraryVC.exactSearchFilter = (field, query)
        }
        
        let navController = UINavigationController(rootViewController: libraryVC)
        
        if self.isPlayingFromFavorites && query == nil {
            let favoritesVC = LibraryViewController()
            favoritesVC.showFavoritesOnly = true
            favoritesVC.delegate = self
            favoritesVC.currentSongID = self.currentSong?.id
            navController.viewControllers = [libraryVC, favoritesVC]
        }
        
        if let sheet = navController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.selectedDetentIdentifier = .large
        }
        
        present(navController, animated: true)
    }
    
    @objc private func openQueue() {
        let queueVC = QueueViewController()
        let allSongs = getEffectiveQueue()
        
        // Calculate global index
        var globalIndex = 0
        if !playbackQueue.isEmpty {
            globalIndex = currentQueueIndex
        } else if let current = currentSong {
            globalIndex = allSongs.firstIndex(where: { $0.id == current.id }) ?? 0
        }
        
        // Filter: Current + Next 20
        let startIndex = globalIndex
        var currentEndIndex = min(startIndex + 21, allSongs.count)
        
        let slice: [Song]
        if startIndex < allSongs.count {
            slice = Array(allSongs[startIndex..<currentEndIndex])
        } else {
            slice = []
        }
        
        queueVC.songs = slice
        queueVC.currentIndex = 0 // Start at current
        
        if currentEndIndex < allSongs.count {
            queueVC.onLoadMore = { [weak queueVC] in
                guard let queueVC = queueVC else { return }
                let nextEndIndex = min(currentEndIndex + 20, allSongs.count)
                let newSongs = Array(allSongs[currentEndIndex..<nextEndIndex])
                queueVC.songs.append(contentsOf: newSongs)
                queueVC.tableView.reloadData()
                currentEndIndex = nextEndIndex
                
                if currentEndIndex >= allSongs.count {
                    queueVC.onLoadMore = nil
                    queueVC.setupLoadMoreFooter()
                }
            }
        }
        
        queueVC.onSelect = { [weak self] index in
            guard let self = self else { return }
            let realIndex = startIndex + index
            if self.playbackQueue.isEmpty {
                self.playbackQueue = allSongs
            }
            if realIndex < self.playbackQueue.count {
                self.currentQueueIndex = realIndex
                self.loadSong(self.playbackQueue[realIndex], andPlay: true)
            }
        }
        
        queueVC.onDelete = { [weak self] index in
            guard let self = self else { return }
            let realIndex = startIndex + index
            
            if self.playbackQueue.isEmpty {
                self.playbackQueue = allSongs
                self.currentQueueIndex = globalIndex
            }
            
            if self.playbackQueue.indices.contains(realIndex) {
                self.playbackQueue.remove(at: realIndex)
                if realIndex < self.currentQueueIndex {
                    self.currentQueueIndex -= 1
                }
            }
        }
        
        queueVC.onReorder = { [weak self] reorderedSlice, newLocalIndex in
            guard let self = self else { return }
            
            if self.playbackQueue.isEmpty {
                self.playbackQueue = allSongs
                self.currentQueueIndex = globalIndex
            }
            
            let rangeStart = startIndex
            let rangeEnd = rangeStart + reorderedSlice.count
            
            if rangeEnd <= self.playbackQueue.count {
                self.playbackQueue.replaceSubrange(rangeStart..<rangeEnd, with: reorderedSlice)
                self.currentQueueIndex = rangeStart + newLocalIndex
            }
        }
        
        let nav = UINavigationController(rootViewController: queueVC)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func showSearchMenu(_ sender: UITapGestureRecognizer) {
        guard let song = currentSong else { return }
        
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        var hasAction = false
        
        if let artist = song.artist, !artist.isEmpty {
            let action = UIAlertAction(title: "Search Artist", style: .default) { [weak self] _ in
                self?.presentLibrary(withSearch: artist, exactField: "artist")
            }
            action.setValue(UIImage(systemName: "person.fill"), forKey: "image")
            alert.addAction(action)
            hasAction = true
        }
        
        if let album = song.album, !album.isEmpty {
            let action = UIAlertAction(title: "Search Album", style: .default) { [weak self] _ in
                self?.presentLibrary(withSearch: album, exactField: "album")
            }
            action.setValue(UIImage(systemName: "opticaldisc"), forKey: "image")
            alert.addAction(action)
            hasAction = true
        }
        
        if let artist = song.artist, !artist.isEmpty {
            let action = UIAlertAction(title: "Shuffle Artist", style: .default) { [weak self] _ in
                guard let self = self else { return }
                let artistSongs = LibraryManager.shared.songs.filter { ($0.artist ?? "").localizedCaseInsensitiveCompare(artist) == .orderedSame }
                self.playShuffled(songs: artistSongs)
            }
            action.setValue(UIImage(systemName: "shuffle"), forKey: "image")
            alert.addAction(action)
            hasAction = true
        }
        
        if let album = song.album, !album.isEmpty {
            let action = UIAlertAction(title: "Shuffle Album", style: .default) { [weak self] _ in
                guard let self = self else { return }
                let albumSongs = LibraryManager.shared.songs.filter { ($0.album ?? "").localizedCaseInsensitiveCompare(album) == .orderedSame }
                self.playShuffled(songs: albumSongs)
            }
            action.setValue(UIImage(systemName: "shuffle"), forKey: "image")
            alert.addAction(action)
            hasAction = true
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sender.view ?? songTitleLabel
            popover.sourceRect = sender.view?.bounds ?? songTitleLabel.bounds
        }
        
        if hasAction {
            present(alert, animated: true)
            impactFeedbackGenerator.impactOccurred()
        }
    }
    
    private func playShuffled(songs: [Song]) {
        guard !songs.isEmpty else { return }
        
        isShuffling = true
        playbackQueue = songs.shuffled()
        currentQueueIndex = 0
        
        // Turn on auto play next and turn off repeat song
        settingsViewController(SettingsViewController(), didChangeAutoPlayNextState: true)
        settingsViewController(SettingsViewController(), didChangeLoopingState: false)
        loadSong(playbackQueue[currentQueueIndex], andPlay: true)
    }
    
    @objc private func toggleFavoriteTapped() {
        guard var song = currentSong else { return }
        LibraryManager.shared.toggleFavorite(for: song.id)
        song.isFavorite = !(song.isFavorite ?? false)
        currentSong = song
        updateFavoriteButtonState()
        impactFeedbackGenerator.impactOccurred()
    }
    
    private func updateFavoriteButtonState() {
        guard let song = currentSong else { return }
        let isFav = song.isFavorite ?? false
        let imageName = isFav ? "heart.fill" : "heart"
        favoriteButton.configuration?.image = UIImage(systemName: imageName)
        favoriteButton.configuration?.baseForegroundColor = isFav ? .systemPink : .label
    }
    
    @objc private func toggleRepeatTapped() {
        isLoopingEnabled.toggle()
        UserDefaults.standard.set(isLoopingEnabled, forKey: "isLoopingEnabled")
        updateRepeatButtonState()
        impactFeedbackGenerator.impactOccurred()
    }
    
    private func updateRepeatButtonState() {
        let imageName = isLoopingEnabled ? "repeat.1" : "repeat"
        repeatButton.configuration?.image = UIImage(systemName: imageName)
        repeatButton.configuration?.baseBackgroundColor = isLoopingEnabled ? .systemBlue : .secondarySystemFill
        repeatButton.configuration?.baseForegroundColor = isLoopingEnabled ? .white : .label
    }
    
    @objc private func animateAlbumArtBounce() {
        UIView.animate(withDuration: 0.1, animations: {
            self.albumArtImageView.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                self.albumArtImageView.transform = .identity
            } completion: { _ in
                self.openLibrary()
            }
        }
        impactFeedbackGenerator.impactOccurred()
    }
    
    private func updatePlayPauseButtonState() {
        let isPlaying = audioProcessor.isCurrentlyPlaying()
        let imageName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName), for: .normal)
        
        // Animate the album art based on playback state
        let targetTransform = isPlaying ? .identity : CGAffineTransform(scaleX: 0.85, y: 0.85)
        
        UIView.animate(withDuration: 0.6,
                       delay: 0,
                       usingSpringWithDamping: 0.6,
                       initialSpringVelocity: 0.8,
                       options: [.allowUserInteraction, .beginFromCurrentState],
                       animations: {
            self.albumArtImageView.transform = targetTransform
        }, completion: nil)
    }
    
    
    @objc func progressSliderScrubbing(_ sender: UISlider) {
        audioProcessor.seek(to: Double(sender.value))
        audioProcessor.updateNowPlayingInfo(isPaused: !audioProcessor.isCurrentlyPlaying())
    }
    
    @objc func openSettings() {
        let settingsVC = SettingsViewController()
        settingsVC.delegate = self
        settingsVC.currentTheme = ThemeManager.shared.currentTheme
        settingsVC.isPitchLinked = UserDefaults.standard.bool(forKey: "isPitchLinked")
        settingsVC.isAnimatedBackgroundEnabled = UserDefaults.standard.bool(forKey: "isAnimatedBackgroundEnabled", defaultValue: true)
        settingsVC.isDynamicBackgroundEnabled = UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled")
        settingsVC.isDynamicThemeEnabled = UserDefaults.standard.bool(forKey: "isDynamicThemeEnabled")
        settingsVC.isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
        settingsVC.isResetSlidersOnTapEnabled = UserDefaults.standard.bool(forKey: "isResetSlidersOnTapEnabled")
        settingsVC.isTapArtworkToChangeSongEnabled = UserDefaults.standard.bool(forKey: "isTapArtworkToChangeSongEnabled")
        settingsVC.isAccuratePitchEnabled = self.isAccuratePitchEnabled
        settingsVC.isAccurateSpeedEnabled = self.isAccurateSpeedEnabled
        settingsVC.isExportButtonEnabled = UserDefaults.standard.bool(forKey: "isExportButtonEnabled", defaultValue: true)
        settingsVC.isEQEnabled = UserDefaults.standard.bool(forKey: "isEQEnabled")
        settingsVC.isAlbumArtVisible = UserDefaults.standard.bool(forKey: "isAlbumArtVisible", defaultValue: true)
        settingsVC.isLoopingEnabled = self.isLoopingEnabled
        settingsVC.isRememberSettingsEnabled = self.isRememberSettingsEnabled
        settingsVC.isAutoPlayNextEnabled = self.isAutoPlayNextEnabled
        settingsVC.isStepperEnabled = self.isStepperEnabled
        settingsVC.isAutoLoadAddedSongEnabled = UserDefaults.standard.bool(forKey: "isAutoLoadAddedSongEnabled")
        
        // Embed the SettingsViewController in a UINavigationController to display a navigation bar
        let navController = UINavigationController(rootViewController: settingsVC)
        
        // Present as a sheet
        if let sheet = navController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            impactFeedbackGenerator.impactOccurred()
        }
        present(navController, animated: true)
    }
    
    // MARK: SettingsViewControllerDelegate
    
    func settingsViewController(_ controller: SettingsViewController, didChangeLinkPitchState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isPitchLinked")
        pitchControlStack.isHidden = isEnabled
        audioProcessor.setVarispeedEnabled(isEnabled)
        speedSliderChanged(speedSlider) // Re-apply speed/pitch logic
        updatePlayPauseButtonState()
        progressSlider.value = 0
        currentTimeLabel.text = formatTime(seconds: 0)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeDynamicBackgroundState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isDynamicBackgroundEnabled")
        updateBackground(with: albumArtImageView.image, isDynamicEnabled: isEnabled)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeAnimatedBackgroundState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isAnimatedBackgroundEnabled")
        updateBackgroundAnimation()
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeDynamicThemeState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isDynamicThemeEnabled")
        
        // If dynamic theme is enabled, try to apply color from current artwork.
        // Otherwise, apply the saved manual theme.
        applyDynamicTheme(isEnabled: isEnabled, image: albumArtImageView.image)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeReverbSliderState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isReverbSliderEnabled")
        reverbLabel.isHidden = !isEnabled
        reverbSlider.isHidden = !isEnabled
        updateStepperVisibility()
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeResetSlidersOnTapState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isResetSlidersOnTapEnabled")
        setupSliderLabelTapGestures(isEnabled: isEnabled)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeTapArtworkToChangeSongState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isTapArtworkToChangeSongEnabled")
        albumArtTapGesture.isEnabled = isEnabled
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangePrecisePitchState isEnabled: Bool) {
        self.isAccuratePitchEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isAccuratePitchEnabled")
        pitchSliderChanged(pitchSlider) // Re-evaluate current pitch value
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeAccurateSpeedState isEnabled: Bool) {
        self.isAccurateSpeedEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isAccurateSpeedEnabled")
        speedSliderChanged(speedSlider) // Re-evaluate current speed value
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeShowExportButtonState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isExportButtonEnabled")
        exportButton.isHidden = !isEnabled
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeShowEQState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isEQEnabled")
        let views = [bassLabel, bassSlider, midsLabel, midsSlider, trebleLabel, trebleSlider]
        views.forEach { $0.isHidden = !isEnabled }
        updateStepperVisibility()
        // Re-apply reverb slider visibility based on user settings
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeShowAlbumArtState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isAlbumArtVisible")
        albumArtImageView.isHidden = !isEnabled
        let isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
        settingsViewController(SettingsViewController(), didChangeReverbSliderState: isReverbSliderEnabled)
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeLoopingState isEnabled: Bool) {
        self.isLoopingEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isLoopingEnabled")
        updateRepeatButtonState()
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeRememberSettingsState isEnabled: Bool) {
        self.isRememberSettingsEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isRememberSettingsEnabled")
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeAutoPlayNextState isEnabled: Bool) {
        self.isAutoPlayNextEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isAutoPlayNextEnabled")
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeStepperState isEnabled: Bool) {
        self.isStepperEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "isStepperEnabled")
        updateStepperVisibility()
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeAutoLoadAddedSongState isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "isAutoLoadAddedSongEnabled")
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeShowPresetsState isEnabled: Bool) {
        self.isShowPresetsEnabled = isEnabled
        presetsStack.isHidden = !isEnabled
    }
    
    @objc private func removeVocalsTapped() {
        let currentlyEnabled = audioProcessor.isVocalRemovalEnabled()
        if !currentlyEnabled {
            let alert = UIAlertController(title: "Process Audio?", message: "This will take a moment to process. Do you want to continue?", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
            alert.addAction(UIAlertAction(title: "Continue", style: .default, handler: { [weak self] _ in
                self?.processVocalRemoval(enable: true)
            }))
            present(alert, animated: true)
        } else {
            processVocalRemoval(enable: false)
        }
    }
    
    private func processVocalRemoval(enable: Bool) {
        audioProcessor.setVocalLevel(0.0)
        removeVocalsButton.isEnabled = false
        
        if enable {
            let overlay = createLoadingHUD(in: self.view, message: "Reducing Vocals...")
            self.view.isUserInteractionEnabled = false
            
            audioProcessor.setRemoveVocalsEnabled(true) { [weak self] success in
                DispatchQueue.main.async {
                    overlay.removeFromSuperview()
                    self?.view.isUserInteractionEnabled = true
                    self?.removeVocalsButton.isEnabled = true
                    self?.updateRemoveVocalsButtonState()
                    if success { self?.impactFeedbackGenerator.impactOccurred() }
                }
            }
        } else {
            audioProcessor.setRemoveVocalsEnabled(false) { [weak self] success in
                DispatchQueue.main.async {
                    self?.removeVocalsButton.isEnabled = true
                    self?.updateRemoveVocalsButtonState()
                    if success { self?.impactFeedbackGenerator.impactOccurred() }
                }
            }
        }
    }
    
    @objc private func generateSpectrogramTapped() {
        guard let song = currentSong, let url = song.url else { return }
        
        let alert = UIAlertController(title: "Generate Spectrogram", message: "This will pause the current music playback and may take a moment. Do you want to continue?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "Continue", style: .default, handler: { [weak self] _ in
            guard let self = self else { return }
            
            if self.audioProcessor.isCurrentlyPlaying() {
                self.togglePlayback()
            }
            
            let overlay = self.createLoadingHUD(in: self.view, message: "Generating Spectrogram...")
            self.view.isUserInteractionEnabled = false
            
            SpectrogramProcessor.extractData(from: url) { [weak self] data in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    overlay.removeFromSuperview()
                    self.view.isUserInteractionEnabled = true
                    
                    if let data = data {
                        self.impactFeedbackGenerator.impactOccurred()
                        let previewVC = SpectrogramPreviewViewController(data: data)
                        let nav = UINavigationController(rootViewController: previewVC)
                        self.present(nav, animated: true)
                    } else {
                        let errorAlert = UIAlertController(title: "Error", message: "Failed to generate spectrogram.", preferredStyle: .alert)
                        errorAlert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                        self.present(errorAlert, animated: true)
                    }
                }
            }
        }))
        self.present(alert, animated: true)
    }
    
    private func updateRemoveVocalsButtonState() {
        let isEnabled = audioProcessor.isVocalRemovalEnabled()
        removeVocalsButton.configuration?.baseBackgroundColor = isEnabled ? .systemBlue : .secondarySystemFill
        removeVocalsButton.configuration?.baseForegroundColor = isEnabled ? .white : .label
    }
    
    private func createLoadingHUD(in parentView: UIView, message: String) -> UIView {
        let overlayView = UIView(frame: parentView.bounds)
        overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        let containerView = UIView()
        containerView.backgroundColor = .secondarySystemGroupedBackground
        containerView.layer.cornerRadius = 12
        containerView.translatesAutoresizingMaskIntoConstraints = false
        
        let titleLabel = UILabel()
        titleLabel.text = message
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        
        containerView.addSubview(spinner)
        containerView.addSubview(titleLabel)
        overlayView.addSubview(containerView)
        parentView.addSubview(overlayView)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 260),
            containerView.heightAnchor.constraint(equalToConstant: 120),
            
            spinner.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: containerView.centerYAnchor, constant: -10),
            
            titleLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 15),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -15)
        ])
        
        return overlayView
    }
    
    /// Stops playback and resets the UI to the "No File Loaded" state.
    private func clearCurrentSongAndStopPlayback() {
        if audioProcessor.isCurrentlyPlaying() {
            audioProcessor.togglePlayback() // This will stop playback and update the Now Playing info
        }
        
        // Reset UI elements
        resetControlsState(isHidden: true)
        songTitleLabel.text = "No File Loaded"
        artistNameLabel.text = nil
        albumArtImageView.image = UIImage(systemName: "music.note")
        updateBackground(with: nil)
        
        // Clear state variables and saved data for the last song
        currentSong = nil
        isPlayingFromFavorites = false
        UserDefaults.standard.removeObject(forKey: "lastSongID")
        UserDefaults.standard.removeObject(forKey: "lastPlaybackPosition")
    }
    
    
    private func updateBackground(with image: UIImage?, isDynamicEnabled: Bool? = nil) {
        let useDynamic = isDynamicEnabled ?? UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled")
        let shouldShowDynamicBackground = useDynamic && image != nil && image != UIImage(systemName: "music.note") && image != UIImage(systemName: "music.note.list")

        // Always update the image, even if it's about to be faded out
        if image != backgroundImageView.image {
            backgroundImageView.image = image
        }
        
        UIView.animate(withDuration: 0.5) {
            let targetAlpha: CGFloat = shouldShowDynamicBackground ? 1.0 : 0.0
            self.backgroundImageView.alpha = targetAlpha // Only animate the parent view
        }
    }
    
    func settingsViewController(_ controller: SettingsViewController, didChangeTheme theme: ThemeColor) {
        ThemeManager.shared.currentTheme = theme
        applyTheme(color: theme.uiColor)
    }
    
    private func applyDynamicTheme(isEnabled: Bool, image: UIImage?) {
        if isEnabled {
            if let artwork = image,
               artwork.cgImage != nil, // Ensure it's a real image
               let dominantColor = getDominantColor(from: artwork),
               let vibrantColor = makeVibrant(color: dominantColor) {
                applyTheme(color: vibrantColor)
            } else {
                // Fallback to default theme if no artwork or color can be extracted
                applyTheme(color: ThemeManager.shared.currentTheme.uiColor)
            }
        } else {
            // Dynamic theme is off, use the manually selected theme
            applyTheme(color: ThemeManager.shared.currentTheme.uiColor)
        }
    }
    
    /// Takes a UIColor and returns a brighter, more vibrant version suitable for a theme.
    private func makeVibrant(color: UIColor) -> UIColor? {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return nil
        }

        // Increase brightness to make it stand out, but cap at 1.0
        // Also ensure a minimum brightness to avoid very dark, unusable colors.
        brightness = max(min(brightness * 1.8, 1.0), 0.7)
        
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
    
    /// Extracts the dominant color from an image by scaling it down to 1x1 and sampling the pixel.
    private func getDominantColor(from image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        let width = 1
        let height = 1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData: [UInt8] = [0, 0, 0, 0]

        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return UIColor(red: CGFloat(pixelData[0]) / 255.0, green: CGFloat(pixelData[1]) / 255.0, blue: CGFloat(pixelData[2]) / 255.0, alpha: 1.0)
    }
    @objc func pitchSliderChanged(_ sender: UISlider) {
        let pitchInCents = sender.value
        
        var finalPitch = pitchInCents
        
        if isAccuratePitchEnabled {
            let roundedPitch = (pitchInCents / 100.0).rounded() * 100.0
            
            if roundedPitch != lastSnappedPitchValue {
                selectionFeedbackGenerator.selectionChanged()
                lastSnappedPitchValue = roundedPitch
            }
            
            sender.value = roundedPitch // Snap the slider's visual position
            finalPitch = roundedPitch
        }
        audioProcessor.setPitch(pitch: finalPitch)
        UserDefaults.standard.set(pitchInCents, forKey: "pitchValue")
        currentPresetIndex = nil // Invalidate preset
        let semitones = Int((pitchInCents / 100.0).rounded())
        pitchLabel.text = String(format: "Pitch (%d st)", semitones)
    }
    
    private func setupSliderLabelTapGestures(isEnabled: Bool) {
        // Remove any existing gestures to avoid duplicates
        pitchLabel.gestureRecognizers?.forEach(pitchLabel.removeGestureRecognizer)
        speedLabel.gestureRecognizers?.forEach(speedLabel.removeGestureRecognizer)
        reverbLabel.gestureRecognizers?.forEach(reverbLabel.removeGestureRecognizer)
        bassLabel.gestureRecognizers?.forEach(bassLabel.removeGestureRecognizer)
        midsLabel.gestureRecognizers?.forEach(midsLabel.removeGestureRecognizer)
        trebleLabel.gestureRecognizers?.forEach(trebleLabel.removeGestureRecognizer)
        
        pitchLabel.isUserInteractionEnabled = isEnabled
        speedLabel.isUserInteractionEnabled = isEnabled
        reverbLabel.isUserInteractionEnabled = isEnabled
        bassLabel.isUserInteractionEnabled = isEnabled
        midsLabel.isUserInteractionEnabled = isEnabled
        trebleLabel.isUserInteractionEnabled = isEnabled
        
        if isEnabled {
            let pitchTap = UITapGestureRecognizer(target: self, action: #selector(resetPitchSlider))
            pitchTap.numberOfTapsRequired = 2
            pitchLabel.addGestureRecognizer(pitchTap)

            let speedTap = UITapGestureRecognizer(target: self, action: #selector(resetSpeedSlider))
            speedTap.numberOfTapsRequired = 2
            speedLabel.addGestureRecognizer(speedTap)

            let reverbTap = UITapGestureRecognizer(target: self, action: #selector(resetReverbSlider))
            reverbTap.numberOfTapsRequired = 2
            reverbLabel.addGestureRecognizer(reverbTap)
            
            let bassTap = UITapGestureRecognizer(target: self, action: #selector(resetBassSlider))
            bassTap.numberOfTapsRequired = 2
            bassLabel.addGestureRecognizer(bassTap)
            
            let midsTap = UITapGestureRecognizer(target: self, action: #selector(resetMidsSlider))
            midsTap.numberOfTapsRequired = 2
            midsLabel.addGestureRecognizer(midsTap)
            
            let trebleTap = UITapGestureRecognizer(target: self, action: #selector(resetTrebleSlider))
            trebleTap.numberOfTapsRequired = 2
            trebleLabel.addGestureRecognizer(trebleTap)
        }
    }
    
    @objc func speedSliderChanged(_ sender: UISlider) {
        let rawRate = sender.value // The actual slider position
        UserDefaults.standard.set(rawRate, forKey: "speedValue")
        currentPresetIndex = nil // Invalidate preset

        var finalRate = rawRate
        if isAccurateSpeedEnabled {
            // Snap to 0.05 increments (e.g., 0.50, 0.55, 0.60...)
            let roundedRate = (rawRate * 20).rounded() / 20
            
            if roundedRate != lastSnappedSpeedValue {
                selectionFeedbackGenerator.selectionChanged()
                lastSnappedSpeedValue = roundedRate
            }
            sender.value = roundedRate // Snap the slider's visual position
            finalRate = roundedRate
        }

        speedLabel.text = String(format: "Speed (%.2fx)", finalRate) // Display the potentially snapped value
        
        // Check if pitch control is hidden (linked pitch is ON)
        if pitchControlStack.isHidden {
            // When using Varispeed, we just set the rate. The engine handles the pitch linking.
            // We pass nil for linkedPitch because Varispeed doesn't use the TimePitch node's pitch property.
            audioProcessor.setPlaybackRate(rate: finalRate, linkedPitch: nil)
            // We don't update pitchSlider.value here because it's hidden and irrelevant in Varispeed mode.
        } else {
            audioProcessor.setPlaybackRate(rate: finalRate, linkedPitch: nil)
        }
    }
    
    @objc func reverbSliderChanged(_ sender: UISlider) {
        let mix = sender.value
        audioProcessor.setReverbMix(mix: mix)
        UserDefaults.standard.set(mix, forKey: "reverbValue")
        currentPresetIndex = nil // Invalidate preset
        reverbLabel.text = String(format: "Reverb (%d%%)", Int(mix.rounded()))
    }
    
    @objc func bassSliderChanged(_ sender: UISlider) {
        let gain = sender.value
        audioProcessor.setBassGain(gain: gain)
        UserDefaults.standard.set(gain, forKey: "bassValue")
        currentPresetIndex = nil // Invalidate preset
        bassLabel.text = String(format: "Bass (%.1f dB)", gain)
    }
    
    @objc func midsSliderChanged(_ sender: UISlider) {
        let gain = sender.value
        audioProcessor.setMidsGain(gain: gain)
        UserDefaults.standard.set(gain, forKey: "midsValue")
        currentPresetIndex = nil // Invalidate preset
        midsLabel.text = String(format: "Mids (%.1f dB)", gain)
    }
    
    @objc func trebleSliderChanged(_ sender: UISlider) {
        let gain = sender.value
        audioProcessor.setTrebleGain(gain: gain)
        UserDefaults.standard.set(gain, forKey: "trebleValue")
        currentPresetIndex = nil // Invalidate preset
        trebleLabel.text = String(format: "Treble (%.1f dB)", gain)
    }
    
    // MARK: - Stepper Actions
    
    @objc private func incrementPitch() {
        let step: Float = isAccuratePitchEnabled ? 100 : 10
        let newValue = min(pitchSlider.maximumValue, pitchSlider.value + step)
        pitchSlider.setValue(newValue, animated: true)
        pitchSliderChanged(pitchSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func decrementPitch() {
        let step: Float = isAccuratePitchEnabled ? 100 : 10
        let newValue = max(pitchSlider.minimumValue, pitchSlider.value - step)
        pitchSlider.setValue(newValue, animated: true)
        pitchSliderChanged(pitchSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func incrementSpeed() {
        let step: Float = isAccurateSpeedEnabled ? 0.05 : 0.01
        let newValue = min(speedSlider.maximumValue, speedSlider.value + step)
        speedSlider.setValue(newValue, animated: true)
        speedSliderChanged(speedSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func decrementSpeed() {
        let step: Float = isAccurateSpeedEnabled ? 0.05 : 0.01
        let newValue = max(speedSlider.minimumValue, speedSlider.value - step)
        speedSlider.setValue(newValue, animated: true)
        speedSliderChanged(speedSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func incrementReverb() {
        let step: Float = 5.0
        let newValue = min(reverbSlider.maximumValue, reverbSlider.value + step)
        reverbSlider.setValue(newValue, animated: true)
        reverbSliderChanged(reverbSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func decrementReverb() {
        let step: Float = 5.0
        let newValue = max(reverbSlider.minimumValue, reverbSlider.value - step)
        reverbSlider.setValue(newValue, animated: true)
        reverbSliderChanged(reverbSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func incrementBass() {
        let newValue = min(bassSlider.maximumValue, bassSlider.value + 1)
        bassSlider.setValue(newValue, animated: true)
        bassSliderChanged(bassSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func decrementBass() {
        let newValue = max(bassSlider.minimumValue, bassSlider.value - 1)
        bassSlider.setValue(newValue, animated: true)
        bassSliderChanged(bassSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func incrementMids() {
        let newValue = min(midsSlider.maximumValue, midsSlider.value + 1)
        midsSlider.setValue(newValue, animated: true)
        midsSliderChanged(midsSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func decrementMids() {
        let newValue = max(midsSlider.minimumValue, midsSlider.value - 1)
        midsSlider.setValue(newValue, animated: true)
        midsSliderChanged(midsSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func incrementTreble() {
        let newValue = min(trebleSlider.maximumValue, trebleSlider.value + 1)
        trebleSlider.setValue(newValue, animated: true)
        trebleSliderChanged(trebleSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func decrementTreble() {
        let newValue = max(trebleSlider.minimumValue, trebleSlider.value - 1)
        trebleSlider.setValue(newValue, animated: true)
        trebleSliderChanged(trebleSlider)
        impactFeedbackGenerator.impactOccurred()
    }
    
    func getSortedLibrarySongs() -> [Song] {
        var songs = LibraryManager.shared.songs
        let sortOptionKey = "librarySortOption"
        let sortIndex = UserDefaults.standard.integer(forKey: sortOptionKey)
        guard let sortOption = LibrarySortOption(rawValue: sortIndex) else { return songs }
        
        songs.sort(by: sortOption.areInIncreasingOrder)
        return songs
    }
    
    private func loadSong(_ song: Song, andPlay: Bool) {
        guard let url = song.url else { return }
        
        self.currentSong = song
        self.accumulatedPlaybackTime = 0
        self.hasRecordedRecentlyPlayed = false
        
        UserDefaults.standard.set(song.id.uuidString, forKey: "lastSongID")
        
        // Load the audio file and get its metadata
        if let metadata = audioProcessor.loadAudioFile(url: url) {
            // Update UI with file information
            songTitleLabel.text = metadata.title
            artistNameLabel.text = metadata.artist
            artistNameLabel.isHidden = metadata.artist == nil
            
            let newImage: UIImage

            if let artwork = metadata.artwork {
                newImage = artwork.cgImage != nil ? artwork : UIImage(systemName: "music.note.list")!
            } else {
                newImage = UIImage(systemName: "music.note.list")!
            }
            UIView.transition(with: self.albumArtImageView,
                              duration: 0.4,
                              options: .transitionCrossDissolve,
                              animations: { self.albumArtImageView.image = newImage },
                              completion: nil)
            // Update dynamic background
            let isDynamicEnabled = UserDefaults.standard.bool(forKey: "isDynamicBackgroundEnabled")
            updateBackground(with: metadata.artwork, isDynamicEnabled: isDynamicEnabled)
            
            // Update dynamic theme
            let isDynamicThemeEnabled = UserDefaults.standard.bool(forKey: "isDynamicThemeEnabled")
            applyDynamicTheme(isEnabled: isDynamicThemeEnabled, image: metadata.artwork)
            
            // Reset and show controls
            resetControlsState(isHidden: false)
            resetButton.isHidden = false
            saveValuesButton.isHidden = false
            updateRemoveVocalsButtonState()
            updateFavoriteButtonState()
            updateRepeatButtonState()
            exportButton.isHidden = !UserDefaults.standard.bool(forKey: "isExportButtonEnabled", defaultValue: true)

            // Re-apply reverb slider visibility based on user settings
            let isReverbSliderEnabled = UserDefaults.standard.bool(forKey: "isReverbSliderEnabled")
            settingsViewController(SettingsViewController(), didChangeReverbSliderState: isReverbSliderEnabled)
            
            // Re-apply EQ slider visibility based on user settings
            let isEQEnabled = UserDefaults.standard.bool(forKey: "isEQEnabled")
            settingsViewController(SettingsViewController(), didChangeShowEQState: isEQEnabled)

            // Apply saved values if they exist, AFTER resetting controls state so they aren't overwritten
            if let savedPitch = song.savedPitch {
                pitchSlider.value = savedPitch
                pitchSliderChanged(pitchSlider)
            }
            if let savedSpeed = song.savedSpeed {
                speedSlider.value = savedSpeed
                speedSliderChanged(speedSlider)
            }
            if let savedReverb = song.savedReverb {
                reverbSlider.value = savedReverb
                reverbSliderChanged(reverbSlider)
            }

            // Update progress slider and labels for the new song
            let duration = audioProcessor.getAudioDuration()
            progressSlider.maximumValue = Float(duration)
            durationLabel.text = formatTime(seconds: duration)
            
            audioProcessor.updateNowPlayingInfo(isPaused: true)
            if andPlay {
                // Automatically start playing
                togglePlayback()
            } else {
                // If not playing, update the button state (and album art size)
                updatePlayPauseButtonState()
            }
        } else {
            // Handle error (e.g., failed to load)
            songTitleLabel.text = "Error Loading File"
            resetControlsState(isHidden: true)
            updateBackground(with: nil)
            audioProcessor.clearNowPlayingInfo() // Clear lock screen info
        }
    }

    // MARK: LibraryViewControllerDelegate
    
    func libraryViewController(_ controller: LibraryViewController, didSelectSong song: Song, in songs: [Song]) {
        isShuffling = false
        isPlayingFromFavorites = controller.showFavoritesOnly
        playbackQueue = songs
        currentQueueIndex = songs.firstIndex(where: { $0.id == song.id }) ?? 0
        loadSong(song, andPlay: true)
    }
    
    func libraryViewController(_ controller: LibraryViewController, didTapShuffleWith songs: [Song]) {
        isPlayingFromFavorites = controller.showFavoritesOnly
        playShuffled(songs: songs)
    }
    
    func libraryViewController(_ controller: LibraryViewController, didRequestPlayNext song: Song) {
        if playbackQueue.isEmpty {
            if let current = currentSong {
                playbackQueue = [current, song]
                currentQueueIndex = 0
            } else {
                loadSong(song, andPlay: true)
                playbackQueue = [song]
                currentQueueIndex = 0
                return
            }
        } else {
            let insertIndex = currentQueueIndex + 1
            if insertIndex <= playbackQueue.count {
                playbackQueue.insert(song, at: insertIndex)
            } else {
                playbackQueue.append(song)
            }
        }
        impactFeedbackGenerator.impactOccurred()
        
        let toast = UIAlertController(title: nil, message: "Playing Next", preferredStyle: .alert)
        controller.present(toast, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            toast.dismiss(animated: true)
        }
    }
    
    @objc private func saveValuesTapped() {
        guard var song = currentSong else { return }
        song.savedPitch = pitchSlider.value
        song.savedSpeed = speedSlider.value
        song.savedReverb = reverbSlider.value
        LibraryManager.shared.updateSong(song)
        impactFeedbackGenerator.impactOccurred()
    }
    
    func cycleToNextPreset() {
        let presets = PresetManager.shared.presets
        guard !presets.isEmpty else { return }
        
        let nextIndex: Int
        if let current = currentPresetIndex {
            nextIndex = (current + 1) % presets.count
        } else {
            nextIndex = 0
        }
        
        applyPreset(presets[nextIndex], index: nextIndex)
        PresetManager.shared.sendPresetNotification(presetName: presets[nextIndex].name)
    }
    
    func applyPreset(_ preset: AudioPreset, index: Int?) {
        currentPresetIndex = index
        
        speedSlider.setValue(preset.speed, animated: true)
        speedSliderChanged(speedSlider)
        
        pitchSlider.setValue(preset.pitch, animated: true)
        pitchSliderChanged(pitchSlider)
        
        reverbSlider.setValue(preset.reverb, animated: true)
        reverbSliderChanged(reverbSlider)
        
        bassSlider.setValue(preset.bass, animated: true)
        bassSliderChanged(bassSlider)
        midsSlider.setValue(preset.mids, animated: true)
        midsSliderChanged(midsSlider)
        trebleSlider.setValue(preset.treble, animated: true)
        trebleSliderChanged(trebleSlider)
        
        // Re-establish index because slider changes invalidated it
        currentPresetIndex = index
        impactFeedbackGenerator.impactOccurred()
    }

    @objc private func applySlowedReverbPreset() {
        let savedSpeed = UserDefaults.standard.float(forKey: "slowedReverbSpeedPreset")
        let targetSpeed = savedSpeed > 0 ? savedSpeed : 0.8
        
        speedSlider.setValue(targetSpeed, animated: true)
        speedSliderChanged(speedSlider)
        
        let savedReverb = UserDefaults.standard.float(forKey: "slowedReverbReverbPreset")
        reverbSlider.setValue(savedReverb, animated: true)
        reverbSliderChanged(reverbSlider)
        
        impactFeedbackGenerator.impactOccurred()
    }

    @objc private func applySpedUpPreset() {
        let savedSpeed = UserDefaults.standard.float(forKey: "spedUpSpeedPreset")
        speedSlider.setValue(savedSpeed > 0 ? savedSpeed : 1.2, animated: true)
        speedSliderChanged(speedSlider)
        
        reverbSlider.setValue(0.0, animated: true)
        reverbSliderChanged(reverbSlider)
        
        impactFeedbackGenerator.impactOccurred()
    }

    // MARK: New Rewind/Skip Actions
    @objc private func rewind10Seconds() {
        let currentTime = audioProcessor.getCurrentTime()
        let newTime = max(0, currentTime - 10)
        audioProcessor.seek(to: newTime)
        progressSlider.value = Float(newTime)
        currentTimeLabel.text = formatTime(seconds: newTime)
        impactFeedbackGenerator.impactOccurred()
        audioProcessor.updateNowPlayingInfo(isPaused: !audioProcessor.isCurrentlyPlaying())
    }

    @objc private func skip10Seconds() {
        let currentTime = audioProcessor.getCurrentTime()
        let duration = audioProcessor.getAudioDuration()
        impactFeedbackGenerator.impactOccurred()
        let newTime = min(duration, currentTime + 10)
        audioProcessor.seek(to: newTime)
        progressSlider.value = Float(newTime)
        currentTimeLabel.text = formatTime(seconds: newTime)
        audioProcessor.updateNowPlayingInfo(isPaused: !audioProcessor.isCurrentlyPlaying())
    }
    
    // MARK: Playlist Navigation
    
    @objc private func playNextSong() {
        if !playbackQueue.isEmpty {
            currentQueueIndex = (currentQueueIndex + 1) % playbackQueue.count
            loadSong(playbackQueue[currentQueueIndex], andPlay: true)
        } else {
            let songs = getSortedLibrarySongs()
            guard !songs.isEmpty, let current = currentSong, let index = songs.firstIndex(where: { $0.id == current.id }) else {
                if !songs.isEmpty { loadSong(songs[0], andPlay: true) }
                return
            }
            let nextIndex = (index + 1) % songs.count
            loadSong(songs[nextIndex], andPlay: true)
        }
        impactFeedbackGenerator.impactOccurred()
    }
    
    @objc private func playPreviousSong() {
        if audioProcessor.getCurrentTime() > 5.0 {
            audioProcessor.seek(to: 0)
            progressSlider.value = 0
            currentTimeLabel.text = formatTime(seconds: 0)
            impactFeedbackGenerator.impactOccurred()
            return
        }
        
        if !playbackQueue.isEmpty {
            currentQueueIndex -= 1
            if currentQueueIndex < 0 { currentQueueIndex = playbackQueue.count - 1 }
            loadSong(playbackQueue[currentQueueIndex], andPlay: true)
        } else {
            let songs = getSortedLibrarySongs()
            guard !songs.isEmpty, let current = currentSong, let index = songs.firstIndex(where: { $0.id == current.id }) else {
                if !songs.isEmpty { loadSong(songs[0], andPlay: true) }
                return
            }
            var prevIndex = index - 1
            if prevIndex < 0 { prevIndex = songs.count - 1 }
            loadSong(songs[prevIndex], andPlay: true)
        }
        impactFeedbackGenerator.impactOccurred()
    }
    
    // MARK: Export Action
    
    @objc private func exportTapped() {
        let alert = UIAlertController(title: "Export Quality", message: "Select the audio quality for export.", preferredStyle: .actionSheet)
        
        let options: [(title: String, bitrate: Int)] = [
            ("Low (128 kbps)", 128000),
            ("Medium (192 kbps)", 192000),
            ("High (256 kbps)", 256000),
            ("Best (320 kbps)", 320000)
        ]
        
        for option in options {
            alert.addAction(UIAlertAction(title: option.title, style: .default) { [weak self] _ in
                self?.startExportProcess(bitrate: option.bitrate)
            })
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = exportButton
            popover.sourceRect = exportButton.bounds
        }
        
        present(alert, animated: true)
    }
    
    private func startExportProcess(bitrate: Int) {
        // Create a custom overlay view for progress
        let overlayView = UIView(frame: view.bounds)
        overlayView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        let containerView = UIView()
        containerView.backgroundColor = .secondarySystemGroupedBackground
        containerView.layer.cornerRadius = 12
        containerView.translatesAutoresizingMaskIntoConstraints = false
        
        let titleLabel = UILabel()
        titleLabel.text = "Exporting..."
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let progressBar = UIProgressView(progressViewStyle: .default)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        
        containerView.addSubview(titleLabel)
        containerView.addSubview(progressBar)
        overlayView.addSubview(containerView)
        view.addSubview(overlayView)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 220),
            containerView.heightAnchor.constraint(equalToConstant: 100),
            
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            
            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            progressBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20)
        ])
        
        view.isUserInteractionEnabled = false // Prevent user interaction during export
        
        audioProcessor.exportAudio(bitrate: bitrate, progress: { progress in
            DispatchQueue.main.async {
                progressBar.setProgress(progress, animated: true)
            }
        }) { [weak self] result in
            DispatchQueue.main.async {
                // Remove overlay
                overlayView.removeFromSuperview()
                self?.view.isUserInteractionEnabled = true
                
                // Update UI to reflect paused state at beginning
                self?.updatePlayPauseButtonState()
                self?.progressSlider.value = 0
                self?.currentTimeLabel.text = self?.formatTime(seconds: 0)
                self?.audioProcessor.updateNowPlayingInfo(isPaused: true)
                
                switch result {
                case .success(let url):
                    // Present the share sheet
                    let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    self?.present(activityVC, animated: true, completion: nil)
                    
                case .failure(let error):
                    // Show an error alert
                    let errorAlert = UIAlertController(title: "Export Failed", message: error.localizedDescription, preferredStyle: .alert)
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
                    self?.present(errorAlert, animated: true)
                }
            }
        }
    }
    
    // MARK: - Quick Actions
    
    private func setupQuickActions() {
        let shuffleLibrary = UIApplicationShortcutItem(
            type: "com.slowedandreverb.shuffleLibrary",
            localizedTitle: "Shuffle Library",
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "shuffle"),
            userInfo: nil
        )
        
        let shuffleFavorites = UIApplicationShortcutItem(
            type: "com.slowedandreverb.shuffleFavorites",
            localizedTitle: "Shuffle Favorites",
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "heart.fill"),
            userInfo: nil
        )
        
        UIApplication.shared.shortcutItems = [shuffleLibrary, shuffleFavorites]
    }
    
    func handleShortcutItem(_ item: UIApplicationShortcutItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if item.type == "com.slowedandreverb.shuffleLibrary" {
                self.isPlayingFromFavorites = false
                self.playShuffled(songs: LibraryManager.shared.songs)
            } else if item.type == "com.slowedandreverb.shuffleFavorites" {
                let favorites = LibraryManager.shared.songs.filter { $0.isFavorite ?? false }
                if !favorites.isEmpty {
                    self.isPlayingFromFavorites = true
                    self.playShuffled(songs: favorites)
                }
            }
        }
    }
    
    // MARK: - CarPlay Support
    
    private func setupCarPlay() {
        if #available(iOS 14.0, *) {
            // MPPlayableContentManager is deprecated in iOS 14 and causes the system to spawn
            // a dual "Now Playing" session with a list/hamburger menu on devices like iOS 15.
            // Skipping this setup fixes the duplicate, un-slowed player bug on these versions.
        } else {
            MPPlayableContentManager.shared().dataSource = self
            MPPlayableContentManager.shared().delegate = self
            MPPlayableContentManager.shared().reloadData()
        }
    }
    
    private func getEffectiveQueue() -> [Song] {
        if !playbackQueue.isEmpty {
            return playbackQueue
        }
        return getSortedLibrarySongs()
    }
}

extension AudioEffectsViewController: MPPlayableContentDataSource, MPPlayableContentDelegate {
    func numberOfChildItems(at indexPath: IndexPath) -> Int {
        if indexPath.count == 0 { // Root level
            return getEffectiveQueue().count
        }
        return 0
    }
    
    func contentItem(at indexPath: IndexPath) -> MPContentItem? {
        let songs = getEffectiveQueue()
        guard indexPath.row < songs.count else { return nil }
        let song = songs[indexPath.row]
        
        let item = MPContentItem(identifier: song.id.uuidString)
        item.title = song.title
        item.subtitle = song.artist
        item.isPlayable = true
        item.isContainer = false
        return item
    }
    
    func playableContentManager(_ contentManager: MPPlayableContentManager, initiatePlaybackOfContentItemAt indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completionHandler(nil); return }
            let songs = self.getEffectiveQueue()
            guard indexPath.row < songs.count else { completionHandler(nil); return }
            
            // If we are selecting from the library (implicit queue), populate the playbackQueue
            if self.playbackQueue.isEmpty {
                self.playbackQueue = songs
            }
            
            self.currentQueueIndex = indexPath.row
            self.loadSong(songs[indexPath.row], andPlay: true)
            completionHandler(nil)
        }
    }
}

// Helper extension to provide a default value for bool(forKey:)
extension UserDefaults {
    func bool(forKey defaultName: String, defaultValue: Bool) -> Bool {
        if object(forKey: defaultName) == nil {
            return defaultValue
        }
        return bool(forKey: defaultName)
    }
}
// MARK: - 3. SwiftUI Preview and App Entry Point

/// Wraps the UIKit ViewController for display in the SwiftUI Canvas Preview.
struct AudioEffectsAppPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AudioEffectsViewController {
        return AudioEffectsViewController()
    }
    
    func updateUIViewController(_ uiViewController: AudioEffectsViewController, context: Context) {
        // No updates needed
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UserDefaults.standard.register(defaults: [
            "isPitchLinked": true,
            "isDynamicBackgroundEnabled": true,
            "isAnimatedBackgroundEnabled": true,
            "isDynamicThemeEnabled": true,
            "isReverbSliderEnabled": true,
            "isResetSlidersOnTapEnabled": true,
            "isTapArtworkToChangeSongEnabled": true,
            "isAccuratePitchEnabled": false,
            "isAccurateSpeedEnabled": false,
            "isExportButtonEnabled": true,
            "isEQEnabled": false,
            "isAlbumArtVisible": true,
            "isLoopingEnabled": false,
            "isRememberSettingsEnabled": false,
            "isAutoPlayNextEnabled": false,
            "isStepperEnabled": false,
            "isAutoLoadAddedSongEnabled": false,
            "isShowPresetsEnabled": true,
            "slowedReverbSpeedPreset": 0.8,
            "slowedReverbReverbPreset": 40.0,
            "spedUpSpeedPreset": 1.2
        ])

        if #available(iOS 13.0, *) {
            // UI setup is handled by SceneDelegate. Creating a window here spawns a duplicate ghost player
            // which responds to lock screen controls as an un-slowed background player.
        } else {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let vc = AudioEffectsViewController()
            window.rootViewController = vc
            window.overrideUserInterfaceStyle = .dark
            window.tintColor = ThemeManager.shared.currentTheme.uiColor
            window.makeKeyAndVisible()
            self.window = window
            
            if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
                vc.handleShortcutItem(shortcutItem)
                return false
            }
        }

        return true
    }

    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        if let vc = window?.rootViewController as? AudioEffectsViewController {
            vc.handleShortcutItem(shortcutItem)
            completionHandler(true)
        } else {
            completionHandler(false)
        }
    }

    // MARK: UISceneSession Lifecycle
    @available(iOS 13.0, *)
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@available(iOS 13.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        let window = UIWindow(windowScene: windowScene)
        let vc = AudioEffectsViewController()
        window.rootViewController = vc
        window.overrideUserInterfaceStyle = .dark
        window.tintColor = ThemeManager.shared.currentTheme.uiColor
        window.makeKeyAndVisible()
        self.window = window
        
        if let shortcutItem = connectionOptions.shortcutItem {
            vc.handleShortcutItem(shortcutItem)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        if let vc = window?.rootViewController as? AudioEffectsViewController {
            vc.handleShortcutItem(shortcutItem)
            completionHandler(true)
        } else {
            completionHandler(false)
        }
    }
}

#Preview {
    AudioEffectsAppPreview()
}

// MARK: - Spectrogram Preview View Controller

class SpectrogramPreviewViewController: UIViewController {
    let spectrogramData: SpectrogramProcessor.SpectrogramData
    var currentImage: UIImage?
    
    private let imageView = UIImageView()
    private let colorSegmentedControl = UISegmentedControl(items: SpectrogramProcessor.ColorMapType.allCases.map { $0.rawValue })
    
    init(data: SpectrogramProcessor.SpectrogramData) {
        self.spectrogramData = data
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Spectrogram Preview"
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Close", style: .plain, target: self, action: #selector(cancelTapped))
        
        let saveItem = UIBarButtonItem(title: "Save to Photos", style: .done, target: self, action: #selector(saveTapped))
        let shareItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareTapped))
        navigationItem.rightBarButtonItems = [saveItem, shareItem]
        
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        
        colorSegmentedControl.selectedSegmentIndex = 0
        colorSegmentedControl.addTarget(self, action: #selector(colorMapChanged), for: .valueChanged)
        colorSegmentedControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(colorSegmentedControl)
        
        NSLayoutConstraint.activate([
            colorSegmentedControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            colorSegmentedControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            colorSegmentedControl.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            colorSegmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            imageView.bottomAnchor.constraint(equalTo: colorSegmentedControl.topAnchor, constant: -20),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        
        renderPreview()
    }
    
    @objc private func colorMapChanged() {
        renderPreview()
    }
    
    private func renderPreview() {
        let index = colorSegmentedControl.selectedSegmentIndex
        let type = SpectrogramProcessor.ColorMapType.allCases[index]
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if let image = SpectrogramProcessor.renderImage(from: self.spectrogramData, colorMap: type) {
                DispatchQueue.main.async {
                    self.currentImage = image
                    self.imageView.image = image
                }
            }
        }
    }
    
    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
    
    @objc private func saveTapped() {
        guard let image = currentImage else { return }
        // Note: Using this method automatically prompts the user for Photos access if needed.
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
    }
    
    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            let alert = UIAlertController(title: "Save Failed", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        } else {
            let alert = UIAlertController(title: "Saved!", message: "Your spectrogram has been saved to your Photo library.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
    
    @objc private func shareTapped() {
        guard let image = currentImage else { return }
        let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.last
        }
        present(activityVC, animated: true)
    }
}
