import XCTest
import AVFAudio
@testable import GroqTalk

final class AudioRecorderTests: XCTestCase {
    private var recorder: AudioRecorder!
    private var tempFiles: [URL] = []

    override func setUp() {
        recorder = AudioRecorder()
        tempFiles = []
    }

    override func tearDown() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    /// Creates a synthetic 16kHz mono Float32 PCM buffer filled with a sine wave.
    private func makeSineBuffer(
        durationSeconds: Double = 1.0,
        frequency: Float = 440.0
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(16000 * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            samples[i] = sin(2.0 * .pi * frequency * Float(i) / 16000.0) * 0.5
        }
        return buffer
    }

    @discardableResult
    private func track(_ url: URL) -> URL {
        tempFiles.append(url)
        return url
    }

    // MARK: - WAV format tests

    func testWriteWAVProducesFile() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeWAV(buffers: [buffer]))
        XCTAssertEqual(url.pathExtension, "wav")
    }

    func testWriteWAVHasRIFFHeader() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeWAV(buffers: [buffer]))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 44, "WAV file should be larger than 44-byte header")
        let header = String(data: data[0..<4], encoding: .ascii)
        XCTAssertEqual(header, "RIFF", "WAV file must start with RIFF header")
    }

    func testWriteWAVIsReadableAs16kHzMono() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeWAV(buffers: [buffer]))
        let audioFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 16000, accuracy: 1.0)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
    }

    func testWriteWAVIs16BitPCM() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeWAV(buffers: [buffer]))
        let audioFile = try AVAudioFile(forReading: url)
        let settings = audioFile.fileFormat.settings
        let bitDepth = settings[AVLinearPCMBitDepthKey] as? Int
        XCTAssertEqual(bitDepth, 16, "WAV should be 16-bit PCM")
    }

    func testWriteWAVFrameCount() throws {
        let buffer = makeSineBuffer(durationSeconds: 2.0)
        let url = track(try recorder.writeWAV(buffers: [buffer]))
        let audioFile = try AVAudioFile(forReading: url)
        // 2 seconds at 16kHz = 32000 frames
        XCTAssertEqual(audioFile.length, 32000)
    }

    // MARK: - M4A format tests

    func testWriteM4AProducesFile() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeM4A(buffers: [buffer]))
        XCTAssertEqual(url.pathExtension, "m4a")
    }

    func testWriteM4AHasValidContainer() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeM4A(buffers: [buffer]))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 8)
        // ISO Base Media File Format: bytes 4-7 should be "ftyp"
        let boxType = String(data: data[4..<8], encoding: .ascii)
        XCTAssertEqual(boxType, "ftyp", "M4A file must have ftyp box at offset 4")
    }

    func testWriteM4AIsSmallerThanWAV() throws {
        let buffer = makeSineBuffer(durationSeconds: 2.0)
        let wavURL = track(try recorder.writeWAV(buffers: [buffer]))
        let m4aURL = track(try recorder.writeM4A(buffers: [buffer]))
        let wavSize = try Data(contentsOf: wavURL).count
        let m4aSize = try Data(contentsOf: m4aURL).count
        XCTAssertLessThan(m4aSize, wavSize, "M4A (\(m4aSize)B) should be smaller than WAV (\(wavSize)B)")
    }

    func testWriteM4AIsReadableAsAudio() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeM4A(buffers: [buffer]))
        let audioFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 16000, accuracy: 1.0)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
    }

    // MARK: - FLAC format tests

    func testWriteFLACProducesFile() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeFLAC(buffers: [buffer]))
        XCTAssertEqual(url.pathExtension, "flac")
    }

    func testWriteFLACHasValidHeader() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeFLAC(buffers: [buffer]))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 4)
        // FLAC files start with "fLaC" magic bytes
        let magic = String(data: data[0..<4], encoding: .ascii)
        XCTAssertEqual(magic, "fLaC", "FLAC file must start with fLaC magic bytes")
    }

    func testWriteFLACIsSmallerThanWAV() throws {
        let buffer = makeSineBuffer(durationSeconds: 2.0)
        let wavURL = track(try recorder.writeWAV(buffers: [buffer]))
        let flacURL = track(try recorder.writeFLAC(buffers: [buffer]))
        let wavSize = try Data(contentsOf: wavURL).count
        let flacSize = try Data(contentsOf: flacURL).count
        XCTAssertLessThan(flacSize, wavSize, "FLAC (\(flacSize)B) should be smaller than WAV (\(wavSize)B)")
    }

    func testWriteFLACIsReadableAsAudio() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeFLAC(buffers: [buffer]))
        let audioFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(audioFile.fileFormat.sampleRate, 16000, accuracy: 1.0)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1)
    }

    // MARK: - Format routing via stopRecording

    func testStopRecordingWithoutStartReturnsNil() throws {
        XCTAssertNil(try recorder.stopRecording(format: .wav))
        XCTAssertNil(try recorder.stopRecording(format: .m4a))
        XCTAssertNil(try recorder.stopRecording(format: .flac))
    }

    // MARK: - Multiple buffers

    func testMultipleBuffersConcatenateWAV() throws {
        let b1 = makeSineBuffer(durationSeconds: 0.5)
        let b2 = makeSineBuffer(durationSeconds: 0.5, frequency: 880.0)
        let url = track(try recorder.writeWAV(buffers: [b1, b2]))
        let audioFile = try AVAudioFile(forReading: url)
        // 0.5s + 0.5s at 16kHz = 16000 frames
        XCTAssertEqual(audioFile.length, 16000)
    }

    func testMultipleBuffersConcatenateM4A() throws {
        let b1 = makeSineBuffer(durationSeconds: 0.5)
        let b2 = makeSineBuffer(durationSeconds: 0.5, frequency: 880.0)
        let url = track(try recorder.writeM4A(buffers: [b1, b2]))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0, "M4A from multiple buffers should produce output")
    }

    func testMultipleBuffersConcatenateFLAC() throws {
        let b1 = makeSineBuffer(durationSeconds: 0.5)
        let b2 = makeSineBuffer(durationSeconds: 0.5, frequency: 880.0)
        let url = track(try recorder.writeFLAC(buffers: [b1, b2]))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0, "FLAC from multiple buffers should produce output")
    }

    // MARK: - Format-to-extension consistency with TranscriptionService

    func testWAVExtensionMatchesTranscriptionServiceExpectation() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeWAV(buffers: [buffer]))
        XCTAssertEqual(url.pathExtension, "wav")

        let service = TranscriptionService()
        let body = try service.buildMultipartBody(
            audioFileURL: url, model: "whisper-large-v3-turbo", format: .wav, boundary: "b"
        )
        let bodyString = String(data: body, encoding: .isoLatin1)!
        XCTAssertTrue(bodyString.contains("filename=\"audio.wav\""))
        XCTAssertTrue(bodyString.contains("Content-Type: audio/wav"))
    }

    func testM4AExtensionMatchesTranscriptionServiceExpectation() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeM4A(buffers: [buffer]))
        XCTAssertEqual(url.pathExtension, "m4a")

        let service = TranscriptionService()
        let body = try service.buildMultipartBody(
            audioFileURL: url, model: "whisper-large-v3-turbo", format: .m4a, boundary: "b"
        )
        let bodyString = String(data: body, encoding: .isoLatin1)!
        XCTAssertTrue(bodyString.contains("filename=\"audio.m4a\""))
        XCTAssertTrue(bodyString.contains("Content-Type: audio/mp4"))
    }

    func testFLACExtensionMatchesTranscriptionServiceExpectation() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeFLAC(buffers: [buffer]))
        XCTAssertEqual(url.pathExtension, "flac")

        let service = TranscriptionService()
        let body = try service.buildMultipartBody(
            audioFileURL: url, model: "whisper-large-v3-turbo", format: .flac, boundary: "b"
        )
        let bodyString = String(data: body, encoding: .isoLatin1)!
        XCTAssertTrue(bodyString.contains("filename=\"audio.flac\""))
        XCTAssertTrue(bodyString.contains("Content-Type: audio/flac"))
    }

    // MARK: - AudioFormat enum

    func testAudioFormatFilenames() {
        XCTAssertEqual(AudioFormat.wav.filename, "audio.wav")
        XCTAssertEqual(AudioFormat.m4a.filename, "audio.m4a")
        XCTAssertEqual(AudioFormat.flac.filename, "audio.flac")
    }

    func testAudioFormatContentTypes() {
        XCTAssertEqual(AudioFormat.wav.contentType, "audio/wav")
        XCTAssertEqual(AudioFormat.m4a.contentType, "audio/mp4")
        XCTAssertEqual(AudioFormat.flac.contentType, "audio/flac")
    }

    func testAudioFormatRawValues() {
        XCTAssertEqual(AudioFormat.wav.rawValue, "wav")
        XCTAssertEqual(AudioFormat.m4a.rawValue, "m4a")
        XCTAssertEqual(AudioFormat.flac.rawValue, "flac")
    }

    func testAudioFormatCaseIterable() {
        XCTAssertEqual(AudioFormat.allCases.count, 3)
    }
}
