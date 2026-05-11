import AVFAudio
import CoreAudio
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

/// Language hint for Whisper transcription. When not `.auto`, the ISO 639-1
/// code is included in the API request to constrain language detection and improve accuracy.
enum Language: String, CaseIterable, Codable {
    case auto
    case en, es, fr, de, pt, it, ja, zh, ko, hi, ar, ru

    var displayName: String {
        switch self {
        case .auto: "Auto-detect"
        case .en:   "English"
        case .es:   "Spanish"
        case .fr:   "French"
        case .de:   "German"
        case .pt:   "Portuguese"
        case .it:   "Italian"
        case .ja:   "Japanese"
        case .zh:   "Chinese"
        case .ko:   "Korean"
        case .hi:   "Hindi"
        case .ar:   "Arabic"
        case .ru:   "Russian"
        }
    }
}

final class AudioRecorder: @unchecked Sendable {
    static let defaultMaxRecordingDuration: TimeInterval = 600
    static let defaultMaxBufferedFrames = Int(targetSampleRate * defaultMaxRecordingDuration)

    private var audioEngine: AVAudioEngine?
    private var buffers: [AVAudioPCMBuffer] = []
    private var conversionErrorCount = 0
    private var capturedFrameCount = 0
    private var didExceedFrameLimit = false
    private let bufferLock = NSLock()
    private let encodingQueue = DispatchQueue(label: "com.neonwatty.groqtalk.audioencoding", qos: .userInitiated)
    private let maxBufferedFrames: Int

    private static let targetSampleRate: Double = 16000
    private static let targetChannels: AVAudioChannelCount = 1

    private static var pcmFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )
    }

    init(maxBufferedFrames: Int = AudioRecorder.defaultMaxBufferedFrames) {
        self.maxBufferedFrames = maxBufferedFrames
    }

    func startRecording() throws {
        cancelRecording()

        let engine = AVAudioEngine()
        audioEngine = engine
        resetCapturedState()

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = Self.pcmFormat else {
            throw RecordingError.audioFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw RecordingError.formatConversionFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = Self.targetSampleRate / hwFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outputFrameCount > 0,
                  let converted = AVAudioPCMBuffer(
                      pcmFormat: targetFormat, frameCapacity: outputFrameCount
                  ) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if let error {
                self.bufferLock.withLock {
                    self.conversionErrorCount += 1
                }
                DiagnosticLog.write("audioRecorder: conversion error \(error.localizedDescription)")
            } else if converted.frameLength > 0 {
                self.appendConvertedBuffer(converted)
            }
        }

        try engine.start()
    }

    /// Stops recording and encodes captured audio in the given format.
    /// Returns nil if no recording was active or no audio was captured (benign short press).
    /// Throws if audio was captured but encoding failed, or if all buffers were lost to conversion errors.
    func stopRecording(format: AudioFormat = .wav) throws -> URL? {
        let capturedAudio = try stopAndCaptureRecording()
        return try encodeCapturedAudio(capturedAudio, format: format)
    }

    /// Stops recording immediately, then encodes captured audio off the caller's actor.
    /// Engine/tap teardown stays synchronous so recording state is finalized before UI updates.
    func stopRecordingAsync(format: AudioFormat = .wav) async throws -> URL? {
        let capturedAudio = try stopAndCaptureRecording()
        return try await withCheckedThrowingContinuation { continuation in
            encodingQueue.async { [self] in
                do {
                    let url = try encodeCapturedAudio(capturedAudio, format: format)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func stopAndCaptureRecording() throws -> CapturedAudio? {
        guard let engine = audioEngine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        let (captured, errors, exceededLimit) = bufferLock.withLock { () -> ([AVAudioPCMBuffer], Int, Bool) in
            let b = buffers; let e = conversionErrorCount
            let exceeded = didExceedFrameLimit
            buffers = []
            conversionErrorCount = 0
            capturedFrameCount = 0
            didExceedFrameLimit = false
            return (b, e, exceeded)
        }

        if exceededLimit {
            throw RecordingError.recordingTooLong
        }
        if captured.isEmpty && errors > 0 {
            throw RecordingError.conversionFailed(errorCount: errors)
        }
        guard !captured.isEmpty else { return nil }
        return CapturedAudio(buffers: captured, conversionErrorCount: errors)
    }

    private func encodeCapturedAudio(_ capturedAudio: CapturedAudio?, format: AudioFormat) throws -> URL? {
        guard let capturedAudio else { return nil }
        let captured = capturedAudio.buffers
        let errors = capturedAudio.conversionErrorCount
        let frameCount = captured.reduce(0) { $0 + Int($1.frameLength) }
        DiagnosticLog.write(
            "audioRecorder: captured buffers=\(captured.count) frames=\(frameCount) conversionErrors=\(errors) format=\(format.rawValue)"
        )

        let url: URL
        switch format {
        case .m4a:  url = try writeM4A(buffers: captured)
        case .wav:  url = try writeWAV(buffers: captured)
        case .flac: url = try writeFLAC(buffers: captured)
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        DiagnosticLog.write("audioRecorder: wrote file=\(url.lastPathComponent) bytes=\(fileSize)")
        return url
    }

    func cancelRecording() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        resetCapturedState()
    }

    private func appendConvertedBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferLock.withLock {
            guard !didExceedFrameLimit else { return }
            let frameLength = Int(buffer.frameLength)
            guard capturedFrameCount + frameLength <= maxBufferedFrames else {
                didExceedFrameLimit = true
                buffers.removeAll()
                capturedFrameCount = 0
                return
            }
            buffers.append(buffer)
            capturedFrameCount += frameLength
        }
    }

    private func resetCapturedState() {
        bufferLock.withLock {
            buffers = []
            conversionErrorCount = 0
            capturedFrameCount = 0
            didExceedFrameLimit = false
        }
    }

    // MARK: - WAV output

    /// Internal for testing — callers should use stopRecording(format:).
    func writeWAV(buffers: [AVAudioPCMBuffer]) throws -> URL {
        let url = tempURL(extension: "wav")
        // Write as 16-bit PCM WAV (smaller than float32 WAV)
        guard let int16Format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: true
        ) else {
            throw RecordingError.audioFormatUnavailable
        }
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

    // MARK: - Audio device enumeration

    struct AudioDevice: Identifiable, Equatable, Hashable {
        let id: AudioDeviceID
        let name: String
        let isInput: Bool
    }

    static func availableInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var inputDevices: [AudioDevice] = []

        for deviceID in deviceIDs {
            // Check for input channels via stream configuration on the input scope
            var inputScopeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var configSize: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &inputScopeAddress, 0, nil, &configSize)
            guard sizeStatus == noErr, configSize > 0 else { continue }

            let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufferListPointer.deallocate() }

            var configSizeMutable = configSize
            let dataStatus = AudioObjectGetPropertyData(deviceID, &inputScopeAddress, 0, nil, &configSizeMutable, bufferListPointer)
            guard dataStatus == noErr else { continue }

            let bufferList = bufferListPointer.load(as: AudioBufferList.self)
            let totalChannels = withUnsafePointer(to: bufferList.mBuffers) { buffersStart in
                (0..<Int(bufferList.mNumberBuffers)).reduce(0) { total, i in
                    total + Int(buffersStart[i].mNumberChannels)
                }
            }
            guard totalChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
            let deviceName = nameStatus == noErr ? (nameRef as String) : "Unknown Device"

            inputDevices.append(AudioDevice(id: deviceID, name: deviceName, isInput: true))
        }

        return inputDevices
    }

    enum RecordingError: Error {
        case formatConversionFailed
        case audioFormatUnavailable
        case conversionFailed(errorCount: Int)
        case recordingTooLong
    }

    private struct CapturedAudio {
        let buffers: [AVAudioPCMBuffer]
        let conversionErrorCount: Int
    }
}
