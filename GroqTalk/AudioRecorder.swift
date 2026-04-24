import AVFAudio
import Foundation

/// Audio format for recording output. Used across AudioRecorder, TranscriptionService,
/// AppState, and MenuBarView to eliminate stringly-typed format routing.
enum AudioFormat: String, CaseIterable, Codable {
    case m4a
    case wav
    case flac

    var filename: String { "audio.\(rawValue)" }

    var contentType: String {
        switch self {
        case .m4a:  "audio/mp4"
        case .wav:  "audio/wav"
        case .flac: "audio/flac"
        }
    }
}

final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var buffers: [AVAudioPCMBuffer] = []
    private var conversionErrorCount = 0
    private let bufferQueue = DispatchQueue(label: "com.neonwatty.groqtalk.audiobuffers")

    private static let targetSampleRate: Double = 16000
    private static let targetChannels: AVAudioChannelCount = 1

    private static var pcmFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )!
    }

    func startRecording() throws {
        cancelRecording()

        let engine = AVAudioEngine()
        audioEngine = engine
        bufferQueue.sync { buffers = []; conversionErrorCount = 0 }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hwFormat, to: Self.pcmFormat) else {
            throw RecordingError.formatConversionFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = Self.targetSampleRate / hwFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outputFrameCount > 0,
                  let converted = AVAudioPCMBuffer(
                      pcmFormat: Self.pcmFormat, frameCapacity: outputFrameCount
                  ) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let error {
                self.bufferQueue.sync { self.conversionErrorCount += 1 }
                print("AudioRecorder: conversion error — \(error)")
            } else if converted.frameLength > 0 {
                self.bufferQueue.sync { self.buffers.append(converted) }
            }
        }

        try engine.start()
    }

    /// Stops recording and encodes captured audio in the given format.
    /// Returns nil if no recording was active or no audio was captured (benign short press).
    /// Throws if audio was captured but encoding failed, or if all buffers were lost to conversion errors.
    func stopRecording(format: AudioFormat = .wav) throws -> URL? {
        guard let engine = audioEngine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        let (captured, errors) = bufferQueue.sync { () -> ([AVAudioPCMBuffer], Int) in
            let b = buffers; let e = conversionErrorCount
            buffers = []; conversionErrorCount = 0
            return (b, e)
        }

        if captured.isEmpty && errors > 0 {
            throw RecordingError.conversionFailed(errorCount: errors)
        }
        guard !captured.isEmpty else { return nil }

        switch format {
        case .m4a:  return try writeM4A(buffers: captured)
        case .wav:  return try writeWAV(buffers: captured)
        case .flac: return try writeFLAC(buffers: captured)
        }
    }

    func cancelRecording() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        bufferQueue.sync { buffers = []; conversionErrorCount = 0 }
    }

    // MARK: - WAV output

    /// Internal for testing — callers should use stopRecording(format:).
    func writeWAV(buffers: [AVAudioPCMBuffer]) throws -> URL {
        let url = tempURL(extension: "wav")
        // Write as 16-bit PCM WAV (smaller than float32 WAV)
        let int16Format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: true
        )!
        let file = try AVAudioFile(forWriting: url, settings: int16Format.settings)
        for buffer in buffers {
            try file.write(from: buffer)
        }
        return url
    }

    // MARK: - M4A/AAC output

    /// Internal for testing — callers should use stopRecording(format:).
    func writeM4A(buffers: [AVAudioPCMBuffer]) throws -> URL {
        let url = tempURL(extension: "m4a")
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: Self.targetChannels,
        ]
        let file = try AVAudioFile(forWriting: url, settings: aacSettings)
        for buffer in buffers {
            try file.write(from: buffer)
        }
        return url
    }

    // MARK: - FLAC output

    /// Internal for testing — callers should use stopRecording(format:).
    func writeFLAC(buffers: [AVAudioPCMBuffer]) throws -> URL {
        let url = tempURL(extension: "flac")
        let flacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: Self.targetChannels,
        ]
        let file = try AVAudioFile(forWriting: url, settings: flacSettings)
        for buffer in buffers {
            try file.write(from: buffer)
        }
        return url
    }

    private func tempURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("groqtalk-\(UUID().uuidString).\(ext)")
    }

    enum RecordingError: Error {
        case formatConversionFailed
        case conversionFailed(errorCount: Int)
    }
}
