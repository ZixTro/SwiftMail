import Foundation
import NIOIMAPCore

extension IMAPServer {
    /// Fetches Gmail-native attributes for the given UIDs.
    ///
    /// Requires the `X-GM-EXT-1` capability; other IMAP servers answer with a
    /// tagged BAD. Gate calls on `Capability.gmailExtensions` being advertised.
    public func fetchGmailAttributes(
        for identifierSet: UIDSet
    ) async throws -> [UID: GmailMessageAttributes] {
        let command = FetchGmailAttributesCommand(identifierSet: identifierSet)
        let records = try await executeCommand(command)

        var result: [UID: GmailMessageAttributes] = [:]
        for record in records {
            guard let uid = record.uid,
                  let messageID = record.messageID,
                  let threadID = record.threadID
            else { continue }
            result[uid] = GmailMessageAttributes(messageID: messageID, threadID: threadID, labels: record.labels)
        }
        return result
    }

    /// Searches the selected mailbox with Gmail's own search syntax (`X-GM-RAW`) and returns
    /// the matching UIDs in ascending order.
    ///
    /// Sends `UID SEARCH CHARSET UTF-8 X-GM-RAW <raw>`, with `raw` encoded as one IMAP string
    /// (a quoted string, or a UTF-8 literal for non-ASCII input), and reuses the SEARCH
    /// response handling of ``search(identifierSet:criteria:sortCriteria:sortCharset:calendar:charset:)``.
    ///
    /// Read-only: it issues no SELECT or EXAMINE of its own and stores nothing. Select or
    /// examine the mailbox to search first.
    ///
    /// - Parameter raw: The query as typed into Gmail's search box, e.g. `has:attachment from:alice`.
    /// - Returns: The matching UIDs, ascending.
    /// - Throws:
    ///   - `IMAPError.commandNotSupported` when the server did not advertise `X-GM-EXT-1`;
    ///     nothing is sent in that case.
    ///   - `IMAPError.invalidArgument` for an empty query.
    ///   - `IMAPError.commandFailed` when the server answers NO or BAD.
    public func uidSearchGmailRaw(_ raw: String) async throws -> [UID] {
        guard supportsGmailExtensions else {
            throw IMAPError.commandNotSupported("X-GM-RAW search requires the X-GM-EXT-1 capability")
        }
        let command = GmailRawSearchCommand(rawQuery: raw)
        let result = try await executeCommand(command)
        return result.toArray()
    }
}
