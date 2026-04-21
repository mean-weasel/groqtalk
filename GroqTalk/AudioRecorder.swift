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
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.buffers.append(buffer)
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
