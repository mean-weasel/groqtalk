import AVFAudio
import Foundation

final class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var buffers: [AVAudioPCMBuffer] = []

    func startRecording() {
        let engine = AVAudioEngine()
        audioEngine = engine
        buffers = []

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        // Whisper expects 16kHz mono 16-bit PCM
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else { return }

        // Install converter if hardware format differs
        guard let converter = AVAudioConverter(from: hwFormat, to: recordingFormat) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * (16000.0 / hwFormat.sampleRate)
            )
            guard let converted = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error == nil {
                self.buffers.append(converted)
            }
        }

        do {
            try engine.start()
        } catch {
            print("AudioRecorder: failed to start — \(error)")
        }
    }

    func stopRecording() async -> URL? {
        guard let engine = audioEngine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        guard !buffers.isEmpty, let format = buffers.first?.format else { return nil }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("groqtalk-\(UUID().uuidString).wav")

        do {
            let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            for buffer in buffers {
                try file.write(from: buffer)
            }
            buffers = []
            return tempURL
        } catch {
            print("AudioRecorder: failed to write WAV — \(error)")
            buffers = []
            return nil
        }
    }

    func cancelRecording() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        buffers = []
    }
}
