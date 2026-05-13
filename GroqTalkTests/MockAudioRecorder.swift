import CoreAudio
import Foundation
@testable import GroqTalk

/// Test double for AudioRecording. All state is inspectable; errors can be injected.
final class MockAudioRecorder: AudioRecording {
    // MARK: - startRecording
    var startRecordingCallCount = 0
    var startRecordingDeviceID: AudioDeviceID?
    var startRecordingShouldThrow: Error?

    func startRecording(deviceID: AudioDeviceID?) throws {
        startRecordingCallCount += 1
        startRecordingDeviceID = deviceID
        if let error = startRecordingShouldThrow {
            throw error
        }
    }

    // MARK: - stopRecordingAsync
    var stopRecordingCallCount = 0
    var stopRecordingResult: URL?
    var stopRecordingShouldThrow: Error?

    func stopRecordingAsync(format: AudioFormat) async throws -> URL? {
        stopRecordingCallCount += 1
        if let error = stopRecordingShouldThrow {
            throw error
        }
        return stopRecordingResult
    }

    // MARK: - cancelRecording
    var cancelRecordingCallCount = 0

    func cancelRecording() {
        cancelRecordingCallCount += 1
    }
}
