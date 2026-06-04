import Foundation
import Accelerate
import AVFoundation
import UIKit

class SpectrogramProcessor {
    
    /// Generates a spectrogram image from an audio file.
    /// - Parameters:
    ///   - url: URL of the audio file.
    ///   - size: Desired size of the output image (default 1920x1080).
    ///   - completion: Called with the resulting image or nil on failure.
    static func generateSpectrogram(from url: URL, size: CGSize = CGSize(width: 1920, height: 1080), completion: @escaping (UIImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let audioFile = try AVAudioFile(forReading: url)
                let format = audioFile.processingFormat
                let frameLength = AVAudioFrameCount(audioFile.length)
                
                guard frameLength > 0 else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                
                let targetWidth = Int(size.width)
                let targetHeight = Int(size.height)
                
                let framesPerColumn = max(1, Int(audioFile.length) / targetWidth)
                let fftSize = 4096
                let halfFftSize = fftSize / 2
                let log2n = vDSP_Length(log2(Float(fftSize)))
                
                guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                defer { vDSP_destroy_fftsetup(fftSetup) }
                
                var window = [Float](repeating: 0, count: fftSize)
                vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
                
                var allMagnitudes = [[Float]]()
                allMagnitudes.reserveCapacity(targetWidth)
                
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fftSize)) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                
                var globalMaxMag: Float = -Float.greatestFiniteMagnitude
                
                for col in 0..<targetWidth {
                    let startFrame = AVAudioFramePosition(col * framesPerColumn)
                    if startFrame >= audioFile.length { break }
                    
                    audioFile.framePosition = startFrame
                    do {
                        try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(fftSize))
                        guard let channelData = buffer.floatChannelData else { continue }
                        let channel0 = channelData[0]
                        
                        var realIn = [Float](repeating: 0, count: halfFftSize)
                        var imagIn = [Float](repeating: 0, count: halfFftSize)
                        
                        var multiplied = [Float](repeating: 0, count: fftSize)
                        vDSP_vmul(channel0, 1, window, 1, &multiplied, 1, vDSP_Length(fftSize))
                        
                        multiplied.withUnsafeBufferPointer { ptr in
                            realIn.withUnsafeMutableBufferPointer { realPtr in
                                imagIn.withUnsafeMutableBufferPointer { imagPtr in
                                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfFftSize) { complexPtr in
                                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfFftSize))
                                    }
                                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                                    
                                    var magnitudes = [Float](repeating: 0, count: halfFftSize)
                                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfFftSize))
                                    
                                    var dbMagnitudes = [Float](repeating: 0, count: halfFftSize)
                                    var one: Float = 1.0
                                    vDSP_vdbcon(magnitudes, 1, &one, &dbMagnitudes, 1, vDSP_Length(halfFftSize), 0)
                                    
                                    var localMax: Float = 0
                                    vDSP_maxv(dbMagnitudes, 1, &localMax, vDSP_Length(halfFftSize))
                                    if localMax > globalMaxMag {
                                        globalMaxMag = localMax
                                    }
                                    
                                    allMagnitudes.append(dbMagnitudes)
                                }
                            }
                        }
                    } catch {
                        break // Reached EOF or read error
                    }
                }
                
                var pixelData = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
                for i in stride(from: 3, to: pixelData.count, by: 4) {
                    pixelData[i] = 255 // Opaque black background
                }
                
                let minDb: Float = -80.0
                let rangeDb = max(1.0, globalMaxMag - minDb)
                
                let actualWidth = min(targetWidth, allMagnitudes.count)
                for x in 0..<actualWidth {
                    let colMags = allMagnitudes[x]
                    
                    for y in 0..<targetHeight {
                        // Focus on the lower half of the frequencies for a better visual representation
                        let bin = Int(Float(y) / Float(targetHeight) * Float(halfFftSize / 2))
                        var mag = colMags[min(bin, halfFftSize - 1)]
                        
                        mag = max(minDb, mag)
                        let normalizedMag = max(0, min(1, (mag - minDb) / rangeDb))
                        
                        let color = colorMap(value: normalizedMag)
                        
                        let pixelIndex = ((targetHeight - 1 - y) * targetWidth + x) * 4
                        pixelData[pixelIndex] = color.r
                        pixelData[pixelIndex + 1] = color.g
                        pixelData[pixelIndex + 2] = color.b
                    }
                }
                
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let data = Data(pixelData)
                
                guard let providerRef = CGDataProvider(data: data as CFData),
                      let cgImage = CGImage(width: targetWidth, height: targetHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: targetWidth * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: providerRef, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                
                let image = UIImage(cgImage: cgImage)
                DispatchQueue.main.async { completion(image) }
                
            } catch {
                print("Spectrogram Error: \(error)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
    
    private static func colorMap(value: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        let v = max(0, min(1, value))
        if v < 0.25 { return (UInt8(0.2 * (v / 0.25) * 255), 0, UInt8(0.5 * (v / 0.25) * 255)) }
        else if v < 0.5 { return (UInt8((0.2 + 0.6 * ((v - 0.25) / 0.25)) * 255), 0, UInt8((0.5 - 0.3 * ((v - 0.25) / 0.25)) * 255)) }
        else if v < 0.75 { return (UInt8((0.8 + 0.2 * ((v - 0.5) / 0.25)) * 255), UInt8(0.5 * ((v - 0.5) / 0.25) * 255), UInt8((0.2 - 0.2 * ((v - 0.5) / 0.25)) * 255)) }
        else { return (255, UInt8((0.5 + 0.5 * ((v - 0.75) / 0.25)) * 255), UInt8(((v - 0.75) / 0.25) * 255)) }
    }
}