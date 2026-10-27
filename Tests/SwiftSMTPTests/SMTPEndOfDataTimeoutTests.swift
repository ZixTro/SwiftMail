import Foundation
import Testing
@testable import SwiftMail

/// The reply to the message body's final "." is the one wait that has to be long:
/// the server may scan, sign or relay the whole message before it answers.
@Suite
struct SMTPEndOfDataTimeoutTests {
    @Test
    func endOfDataReplyWaitsFiveMinutes() {
        // RFC 5321 §4.5.3.2.6 recommends 10 minutes for the reply to the final dot;
        // 300 s matches what other clients use and stays well above SwiftMail's other waits.
        #expect(SendContentCommand(data: Data("Subject: x\r\n\r\nbody".utf8)).timeoutSeconds == 300)
    }

    @Test
    func otherCommandTimeoutsAreUnchanged() throws {
        #expect(EHLOCommand(hostname: "client.local").timeoutSeconds == 30)
        #expect(try MailFromCommand(senderAddress: "a@example.com").timeoutSeconds == 30)
        #expect(try RcptToCommand(recipientAddress: "b@example.com").timeoutSeconds == 10)
        #expect(DataCommand().timeoutSeconds == 30)
        #expect(QuitCommand().timeoutSeconds == 10)
        #expect(StartTLSCommand().timeoutSeconds == 10)
    }
}
