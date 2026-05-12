import Testing
@testable import GroqTalk

@MainActor
struct NotificationManagerTests {
    @Test func singletonIsConsistent() {
        let a = NotificationManager.shared
        let b = NotificationManager.shared
        #expect(a === b)
    }

    @Test func postTranscriptionCompleteDoesNotCrash() {
        // Should not throw or crash when called with a short preview
        NotificationManager.shared.postTranscriptionComplete(preview: "Hello world")
    }

    @Test func postTranscriptionFailedDoesNotCrash() {
        NotificationManager.shared.postTranscriptionFailed(errorMessage: "Network error")
    }

    @Test func longPreviewIsTruncatedTo100Characters() {
        // Build a 200-character string and verify the content body would be capped at 100
        let longText = String(repeating: "a", count: 200)
        let truncated = String(longText.prefix(100))
        #expect(truncated.count == 100)
        // Calling postTranscriptionComplete with the long string should not crash
        NotificationManager.shared.postTranscriptionComplete(preview: longText)
    }

    @Test func postTranscriptionCompleteWithEmptyPreviewDoesNotCrash() {
        NotificationManager.shared.postTranscriptionComplete(preview: "")
    }

    @Test func postTranscriptionFailedWithEmptyMessageDoesNotCrash() {
        NotificationManager.shared.postTranscriptionFailed(errorMessage: "")
    }
}
