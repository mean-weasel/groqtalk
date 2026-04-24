import AudioToolbox
import AVFAudio
import Foundation

final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var buffers: [AVAudioPCMBuffer] = []
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
        bufferQueue.sync { buffers = [] }

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
            if error == nil && converted.frameLength > 0 {
                self.bufferQueue.sync { self.buffers.append(converted) }
            }
        }

        try engine.start()
    }

    func stopRecording(format: String = "wav") -> URL? {
        guard let engine = audioEngine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        let captured = bufferQueue.sync { () -> [AVAudioPCMBuffer] in
            let b = buffers; buffers = []; return b
        }

        guard !captured.isEmpty else { return nil }

        switch format {
        case "m4a": return writeM4A(buffers: captured)
        case "mp3": return writeMP3(buffers: captured)
        default:    return writeWAV(buffers: captured)
        }
    }

    func cancelRecording() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        bufferQueue.sync { buffers = [] }
    }

    // MARK: - WAV output

    private func writeWAV(buffers: [AVAudioPCMBuffer]) -> URL? {
        let url = tempURL(extension: "wav")
        // Write as 16-bit PCM WAV for smallest lossless size
        let int16Format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: true
        )!
        do {
            let file = try AVAudioFile(forWriting: url, settings: int16Format.settings)
            for buffer in buffers {
                try file.write(from: buffer)
            }
            return url
        } catch {
            print("AudioRecorder: failed to write WAV — \(error)")
            return nil
        }
    }

    // MARK: - M4A/AAC output

    private func writeM4A(buffers: [AVAudioPCMBuffer]) -> URL? {
        let url = tempURL(extension: "m4a")
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: Self.targetChannels,
            AVEncoderBitRateKey: 64000
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: aacSettings)
            for buffer in buffers {
                try file.write(from: buffer)
            }
            return url
        } catch {
            print("AudioRecorder: failed to write M4A — \(error)")
            return nil
        }
    }

    // MARK: - MP3 output

    private func writeMP3(buffers: [AVAudioPCMBuffer]) -> URL? {
        // First write to WAV, then convert to MP3 via AudioToolbox
        guard let wavURL = writeWAV(buffers: buffers) else { return nil }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let mp3URL = tempURL(extension: "mp3")

        do {
            try convertWAVToMP3(inputURL: wavURL, outputURL: mp3URL)
            return mp3URL
        } catch {
            print("AudioRecorder: failed to write MP3 — \(error)")
            return nil
        }
    }

    private func convertWAVToMP3(inputURL: URL, outputURL: URL) throws {
        var inputFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(inputURL as CFURL, &inputFile)
        guard status == noErr, let srcFile = inputFile else {
            throw RecordingError.formatConversionFailed
        }
        defer { ExtAudioFileDispose(srcFile) }

        var outputDesc = AudioStreamBasicDescription(
            mSampleRate: Self.targetSampleRate,
            mFormatID: kAudioFormatMPEGLayer3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1152,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.targetChannels),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var outputFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileMP3Type,
            &outputDesc,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outputFile
        )
        guard status == noErr, let dstFile = outputFile else {
            throw RecordingError.formatConversionFailed
        }
        defer { ExtAudioFileDispose(dstFile) }

        // Set client format to match our PCM
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: Self.targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: UInt32(Self.targetChannels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            srcFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else { throw RecordingError.formatConversionFailed }

        status = ExtAudioFileSetProperty(
            dstFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else { throw RecordingError.formatConversionFailed }

        let bufferFrames: UInt32 = 4096
        let bufferSize = bufferFrames * 2 // 16-bit mono = 2 bytes per frame
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(bufferSize))
        defer { buffer.deallocate() }

        while true {
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(Self.targetChannels),
                    mDataByteSize: bufferSize,
                    mData: buffer
                )
            )
            var frameCount = bufferFrames
            status = ExtAudioFileRead(srcFile, &frameCount, &bufferList)
            guard status == noErr else { throw RecordingError.formatConversionFailed }
            if frameCount == 0 { break }
            status = ExtAudioFileWrite(dstFile, frameCount, &bufferList)
            guard status == noErr else { throw RecordingError.formatConversionFailed }
        }
    }

    private func tempURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("groqtalk-\(UUID().uuidString).\(ext)")
    }

    enum RecordingError: Error {
        case formatConversionFailed
    }
}
