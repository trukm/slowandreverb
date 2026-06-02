import AVFoundation
import CoreML
import Accelerate

/// Handles audio source separation (vocals vs instruments) using CoreML models.
/// This processor can separate an audio file into vocal and instrumental components.
class SourceSeparationProcessor {
    
    // MARK: - Properties
    private var vocalModel: MLModel?
    private var instrumentalModel: MLModel?
    
    private var vocalBuffer: AVAudioPCMBuffer?
    private var instrumentalBuffer: AVAudioPCMBuffer?
    private var isSeparationInProgress = false
    
    let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
    
    // Callbacks for progress tracking
    var onSeparationProgressChanged: ((Float) -> Void)?
    var onSeparationCompleted: ((Bool) -> Void)?
    
    // MARK: - Initialization
    
    init() {
        loadModels()
    }
    
    /// Loads the CoreML models for source separation.
    /// Note: This example shows the structure. You'll need to add the actual CoreML models.
    private func loadModels() {
        // Attempt to load the vocal separation model
        if let modelURL = Bundle.main.url(forResource: "VocalSeparation", withExtension: "mlmodelc") {
            do {
                let compiledModelURL = modelURL
                self.vocalModel = try MLModel(contentsOf: compiledModelURL)
                print("✓ Vocal separation model loaded successfully")
            } catch {
                print("✗ Failed to load vocal separation model: \(error.localizedDescription)")
                // Fallback: Use a basic approach without dedicated models
                print("  Using simplified vocal removal (EQ-based approach)")
            }
        } else {
            #if DEBUG
            print("ℹ️ CoreML model not found. Using simplified vocal removal.")
            #endif
        }
    }
    
    // MARK: - Audio Processing
    
    /// Separates an audio buffer into vocals and instrumental components.
    /// - Parameter audioBuffer: The audio buffer to process
    /// - Parameter completion: Called when separation is complete
    func separateAudio(audioBuffer: AVAudioPCMBuffer, completion: @escaping (Bool) -> Void) {
        guard !isSeparationInProgress else {
            print("⚠️ Separation already in progress")
            completion(false)
            return
        }
        
        isSeparationInProgress = true
        print("🔄 Starting audio separation: \(audioBuffer.frameLength) frames, \(audioBuffer.format.channelCount) channels")
        
        // Process on a background thread to avoid blocking the audio thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            defer {
                self.isSeparationInProgress = false
            }
            
            // If models are available, use CoreML
            if self.vocalModel != nil {
                let success = self.performMLBasedSeparation(audioBuffer: audioBuffer)
                DispatchQueue.main.async {
                    completion(success)
                }
            } else {
                // Fallback: Use simplified vocal removal via frequency domain processing
                let success = self.performSimplifiedVocalRemoval(audioBuffer: audioBuffer)
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        }
    }
    
    /// Performs CoreML-based source separation (requires trained model).
    private func performMLBasedSeparation(audioBuffer: AVAudioPCMBuffer) -> Bool {
        // This is a placeholder for actual CoreML model inference
        // The actual implementation depends on your specific CoreML model's input/output format
        
        print("Processing audio with CoreML model...")
        
        // Create buffers for separated audio
        let format = audioBuffer.format
        guard let vocalBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: audioBuffer.frameLength),
              let instrumentalBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: audioBuffer.frameLength) else {
            print("Failed to create output buffers")
            return false
        }
        
        // Extract audio data from input buffer
        guard let channelData = audioBuffer.floatChannelData else {
            print("Failed to access audio data")
            return false
        }
        
        let channelCount = Int(format.channelCount)
        let frameCount = Int(audioBuffer.frameLength)
        
        // TODO: Pass audio through CoreML model here
        // Example structure (specific implementation depends on model):
        // 1. Prepare input data for model (normalize, reshape, etc.)
        // 2. Run model prediction
        // 3. Extract vocal and instrumental outputs
        // 4. Write to buffers
        
        // For now, use a simplified approach (split frequency bands)
        if let vocalData = vocalBuffer.floatChannelData,
           let instrumentalData = instrumentalBuffer.floatChannelData {
            let success = simplifiedSeparation(
                inputChannels: channelData,
                vocalChannels: vocalData,
                instrumentalChannels: instrumentalData,
                channelCount: channelCount,
                frameCount: frameCount
            )
            
            if success {
                vocalBuffer.frameLength = AVAudioFrameCount(frameCount)
                instrumentalBuffer.frameLength = AVAudioFrameCount(frameCount)
                self.vocalBuffer = vocalBuffer
                self.instrumentalBuffer = instrumentalBuffer
                print("✓ Source separation completed")
            } else {
                print("✗ Source separation failed")
            }
            
            return success
        }
        
        return false
    }
    
    /// Simplified vocal removal using frequency domain analysis and phase cancellation.
    /// This is a fallback approach that doesn't require a trained model.
    private func performSimplifiedVocalRemoval(audioBuffer: AVAudioPCMBuffer) -> Bool {
        print("🎵 Processing audio with mid-side vocal removal...")
        
        let format = audioBuffer.format
        guard let vocalBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: audioBuffer.frameLength),
              let instrumentalBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: audioBuffer.frameLength) else {
            print("❌ Failed to create separation buffers")
            return false
        }
        
        guard let channelData = audioBuffer.floatChannelData else {
            print("❌ Failed to access input audio data")
            return false
        }
        
        let channelCount = Int(format.channelCount)
        let frameCount = Int(audioBuffer.frameLength)
        print("  Input: \(channelCount) channels, \(frameCount) frames")
        
        if let vocalData = vocalBuffer.floatChannelData,
           let instrumentalData = instrumentalBuffer.floatChannelData {
            let success = simplifiedSeparation(
                inputChannels: channelData,
                vocalChannels: vocalData,
                instrumentalChannels: instrumentalData,
                channelCount: channelCount,
                frameCount: frameCount
            )
            
            if success {
                // Set the frame length so the buffers have the actual data length
                vocalBuffer.frameLength = AVAudioFrameCount(frameCount)
                instrumentalBuffer.frameLength = AVAudioFrameCount(frameCount)
                
                self.vocalBuffer = vocalBuffer
                self.instrumentalBuffer = instrumentalBuffer
                print("✓ Mid-side separation completed: \(frameCount) frames processed")
            } else {
                print("❌ Mid-side separation failed")
            }
            
            return success
        }
        
        return false
    }
    
    /// Mid-side stereo processing for vocal removal:
    /// Vocals are typically center-panned (mono), instruments are spread (stereo)
    /// - Vocals (Mid) = (L + R) / 2
    /// - Instrumental (Sides) = (L - R) / 2
    private func simplifiedSeparation(
        inputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        vocalChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        instrumentalChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> Bool {
        // Only process stereo (2 channels)
        guard channelCount == 2 else {
            // Fallback for mono: just copy
            for channel in 0..<channelCount {
                let inputChannel = inputChannels[channel]
                let vocalChannel = vocalChannels[channel]
                let instrumentalChannel = instrumentalChannels[channel]
                
                for frame in 0..<frameCount {
                    let sample = inputChannel[frame]
                    vocalChannel[frame] = sample * 0.7  // Vocals
                    instrumentalChannel[frame] = sample * 0.3  // Instruments
                }
            }
            return true
        }
        
        let leftChannel = inputChannels[0]
        let rightChannel = inputChannels[1]
        let vocalLeft = vocalChannels[0]
        let vocalRight = vocalChannels[1]
        let instLeft = instrumentalChannels[0]
        let instRight = instrumentalChannels[1]
        
        // Process each frame
        for frame in 0..<frameCount {
            let left = leftChannel[frame]
            let right = rightChannel[frame]
            
            // Mid-Side conversion
            let mid = (left + right) * 0.5
            let side = (left - right) * 0.5
            
            // Output mono-compatible in-phase signals to prevent cancellation on device speakers
            vocalLeft[frame] = mid
            vocalRight[frame] = mid
            
            instLeft[frame] = side
            instRight[frame] = side
        }
        
        return true
    }
    
    // MARK: - Buffer Retrieval
    
    /// Returns the separated vocal buffer.
    func getVocalBuffer() -> AVAudioPCMBuffer? {
        return vocalBuffer
    }
    
    /// Returns the separated instrumental buffer.
    func getInstrumentalBuffer() -> AVAudioPCMBuffer? {
        return instrumentalBuffer
    }
    
    /// Mixes vocal and instrumental buffers based on vocal level (0.0 = instrumental only, 1.0 = vocals only).
    func getMixedBuffer(vocalLevel: Float, format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let vocalBuf = vocalBuffer,
              let instrumentalBuf = instrumentalBuffer,
              let vocalData = vocalBuf.floatChannelData,
              let instrumentalData = instrumentalBuf.floatChannelData else {
            print("⚠️ getMixedBuffer: Missing buffers - vocal=\(vocalBuffer != nil), instrumental=\(instrumentalBuffer != nil)")
            return nil
        }
        
        let outputFormat = format ?? vocalBuf.format
        guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: vocalBuf.frameLength) else {
            print("❌ Failed to create mixed buffer")
            return nil
        }
        
        guard let mixedData = mixedBuffer.floatChannelData else {
            print("❌ Failed to get mixed buffer channel data")
            return nil
        }
        
        let channelCount = Int(vocalBuf.format.channelCount)
        let frameCount = Int(vocalBuf.frameLength)
        let clampedVocalLevel = max(0, min(1, vocalLevel)) // Clamp between 0 and 1
        let instrumentalLevel = 1.0 - clampedVocalLevel
        
        print("  Mixing: vocalLevel=\(String(format: "%.1f", vocalLevel * 100))%, instrumental=\(String(format: "%.1f", instrumentalLevel * 100))%, channels=\(channelCount), frames=\(frameCount)")
        
        for channel in 0..<channelCount {
            let vocalChannel = vocalData[channel]
            let instrumentalChannel = instrumentalData[channel]
            let mixedChannel = mixedData[channel]
            
            // Mix: vocal * vocalLevel + instrumental * instrumentalLevel
            for frame in 0..<frameCount {
                mixedChannel[frame] = vocalChannel[frame] * clampedVocalLevel + instrumentalChannel[frame] * instrumentalLevel
            }
        }
        
        mixedBuffer.frameLength = vocalBuf.frameLength
        return mixedBuffer
    }
    
    /// Clears cached buffers to free memory.
    func clearBuffers() {
        vocalBuffer = nil
        instrumentalBuffer = nil
    }
    
    /// Returns whether source separation models are available.
    func isModelAvailable() -> Bool {
        return vocalModel != nil
    }
}
