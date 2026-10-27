import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

/// `UID SEARCH CHARSET UTF-8 X-GM-RAW <query>`, Gmail's search syntax (X-GM-EXT-1).
///
/// NIOIMAP's `SearchKey` has no X-GM-RAW case, so the command is built with
/// `Command.custom`. The query always travels as a single IMAP string (quoted with
/// escapes, or a literal for non-ASCII, long or CR/LF-bearing input), never as protocol
/// syntax. The command searches the already selected mailbox and changes nothing.
struct GmailRawSearchCommand: IMAPTaggedCommand, Sendable {
    typealias ResultType = MessageIdentifierSet<UID>
    typealias HandlerType = SearchHandler<UID>

    /// The Gmail search query, as typed into Gmail's search box.
    let rawQuery: String

    var timeoutSeconds: Int { return 60 }

    func validate() throws {
        guard !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IMAPError.invalidArgument("Gmail search query cannot be empty")
        }
        // An IMAP literal may not carry NUL (RFC 3501 §4.3).
        guard !rawQuery.utf8.contains(0) else {
            throw IMAPError.invalidArgument("Gmail search query cannot contain NUL")
        }
    }

    func toTaggedCommand(tag: String) -> TaggedCommand {
        TaggedCommand(
            tag: tag,
            command: .custom(
                name: "UID SEARCH",
                payloads: [
                    .verbatim(ByteBuffer(string: "CHARSET UTF-8 X-GM-RAW ")),
                    .literal(ByteBuffer(string: rawQuery))
                ]
            )
        )
    }
}
