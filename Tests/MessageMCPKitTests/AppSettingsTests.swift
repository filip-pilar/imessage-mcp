import Foundation
import Testing
@testable import MessageMCPKit

@Suite("App settings")
struct AppSettingsTests {
    @Test("older settings preserve values and default approval notifications off")
    func backwardCompatibleDecoding() throws {
        let data = Data("""
        {
          "writesEnabled": false,
          "confirmSends": false,
          "confirmReactions": true,
          "liveEventsEnabled": false,
          "launchAtLogin": true,
          "maxAttachmentBytes": 1024,
          "imsgOverridePath": "/tmp/fake-imsg"
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(settings.writesEnabled == false)
        #expect(settings.confirmSends == false)
        #expect(settings.confirmReactions == true)
        #expect(settings.approvalNotificationsEnabled == false)
        #expect(settings.liveEventsEnabled == false)
        #expect(settings.launchAtLogin == true)
        #expect(settings.maxAttachmentBytes == 1024)
        #expect(settings.imsgOverridePath == "/tmp/fake-imsg")
    }
}
