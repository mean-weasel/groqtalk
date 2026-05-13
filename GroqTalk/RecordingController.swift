import CoreAudio
import Foundation

// MARK: - Delegate protocol

@MainActor
protocol RecordingControllerDelegate: AnyObject {
    /// Called when recording successfully starts.
    func recordingControllerDidStart(_ controller: RecordingController)

    /// Called when recording stops and audio is ready for transcription.
    func recordingController(
        _ controller: RecordingController,
        didStopWithURL audioURL: URL,
        format: AudioFormat
    )

    /// Called when the audio recorder reports no audio (silent/empty recording).
    func recordingControllerDidStopWithNoAudio(_ controller: RecordingController)

    /// Called when recording is cancelled by the user.
    func recordingControllerDidCancel(_ controller: RecordingController)

    /// Called when recording fails (e.g. microphone unavailable, encoding error).
    func recordingController(
        _ controller: RecordingController,
        didFailWithError error: Error
    )
}

// MARK: - RecordingController

/// Owns the AudioRecorder reference and the 1-second recording-duration timer.
/// Manages the recording start/stop/cancel lifecycle only.
/// Transcription, paste, and anything after recording are left to the delegate.
@MainActor
final class RecordingController {
    // MARK: Public state

    /// True while a recording session is active.
    private(set) var isRecording = false

    weak var delegate: RecordingControllerDelegate?

    // MARK: Private state

    private let audioRecorder: any AudioRecording
    private let appState: AppState
    private var recordingTimer: Timer?

    // MARK: Init

    init(audioRecorder: any AudioRecording, appState: AppState) {
        self.audioRecorder = audioRecorder
        self.appState = appState
    }

    // MARK: - Public API

    /// Start a recording session.
    /// Does nothing if a transcription is in flight or recording is already in progress.
    func startRecording() {
        guard appState.status != .transcribing else {
            DiagnosticLog.write("RecordingController.startRecording: SKIPPED — transcription in flight")
            return
        }
        guard appState.status != .recording else {
            DiagnosticLog.write("RecordingController.startRecording: SKIPPED — already recording")
            return
        }

        do {
            let deviceID = appState.selectedInputDeviceUID.flatMap { AudioRecorder.deviceID(forUID: $0) }
            try audioRecorder.startRecording(deviceID: deviceID)
            isRecording = true
            appState.setStatus(.recording)
            startRecordingTimer()
            delegate?.recordingControllerDidStart(self)
            DiagnosticLog.write("RecordingController.startRecording: started")
        } catch {
            isRecording = false
            DiagnosticLog.write("RecordingController.startRecording: failed — \(error)")
            delegate?.recordingController(self, didFailWithError: error)
        }
    }

    /// Stop the current recording session and deliver the encoded audio to the delegate.
    func stopRecording() {
        guard appState.status == .recording else {
            DiagnosticLog.write("RecordingController.stopRecording: SKIPPED — not recording (status=\(appState.status))")
            return
        }

        DiagnosticLog.write("RecordingController.stopRecording: stopping")
        stopRecordingTimer()
        isRecording = false

        let format = appState.selectedAudioFormat
        Task { @MainActor in
            do {
                guard let url = try await audioRecorder.stopRecordingAsync(format: format) else {
                    DiagnosticLog.write("RecordingController.stopRecording: no audio captured")
                    delegate?.recordingControllerDidStopWithNoAudio(self)
                    return
                }
                DiagnosticLog.write("RecordingController.stopRecording: audio ready url=\(url.lastPathComponent)")
                delegate?.recordingController(self, didStopWithURL: url, format: format)
            } catch {
                DiagnosticLog.write("RecordingController.stopRecording: error \(error)")
                delegate?.recordingController(self, didFailWithError: error)
            }
        }
    }

    /// Cancel the current recording, discarding any captured audio.
    func cancelRecording() {
        DiagnosticLog.write("RecordingController.cancelRecording")
        stopRecordingTimer()
        audioRecorder.cancelRecording()
        isRecording = false
        delegate?.recordingControllerDidCancel(self)
    }

    /// Invalidate all timers (call on app termination or teardown).
    func invalidateTimers() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Private helpers

    private func startRecordingTimer() {
        appState.recordingStartTime = Date()
        appState.recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.appState.recordingStartTime else { return }
                self.appState.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        appState.recordingStartTime = nil
        appState.recordingDuration = 0
    }
}
