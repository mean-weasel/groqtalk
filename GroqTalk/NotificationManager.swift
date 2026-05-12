import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            DiagnosticLog.write("Notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    func postTranscriptionComplete(preview: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Complete"
        content.body = String(preview.prefix(100))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DiagnosticLog.write("Notification delivery failed: \(error.localizedDescription)")
            }
        }
    }

    func postTranscriptionFailed(errorMessage: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Failed"
        content.body = errorMessage
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DiagnosticLog.write("Notification delivery failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
