import Testing
@testable import GroqTalk

@MainActor
struct LaunchAtLoginManagerTests {
    @Test func initDoesNotCrash() {
        let manager = LaunchAtLoginManager()
        // isEnabled reflects SMAppService status — just verify it's a Bool
        let _ = manager.isEnabled
    }

    @Test func refreshStatusDoesNotCrash() {
        let manager = LaunchAtLoginManager()
        // refreshStatus reads SMAppService.mainApp.status; should not throw or crash
        manager.refreshStatus()
        let _ = manager.isEnabled
    }

    @Test func isEnabledIsConsistentAfterRefresh() {
        let manager = LaunchAtLoginManager()
        let before = manager.isEnabled
        manager.refreshStatus()
        // status should not flip spontaneously
        #expect(manager.isEnabled == before)
    }
}
