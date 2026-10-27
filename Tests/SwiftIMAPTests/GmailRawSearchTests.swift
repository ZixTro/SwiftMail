import Foundation
import NIO
import NIOEmbedded
@preconcurrency import NIOIMAP
@preconcurrency import NIOIMAPCore
import Testing
@testable import SwiftMail

private typealias UID = SwiftMail.UID
private typealias SequenceNumber = SwiftMail.SequenceNumber

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GmailRawSearchTests {

    // MARK: - Capability

    @Test
    func testSupportsGmailExtensionsReflectsAdvertisedCapability() async throws {
        let (server, _) = try await makeHarness(capabilities: [.gmailExtensions, .uidPlus])
        #expect(await server.supportsGmailExtensions)

        let (plainServer, _) = try await makeHarness(capabilities: [.uidPlus, .move])
        #expect(await !plainServer.supportsGmailExtensions)
    }

    // MARK: - CHARSET on SEARCH

    @Test
    func testSearchCommandSendsCharsetWhenRequested() async throws {
        let command = SearchCommand<UID>(criteria: [.text("invoice")], charset: "UTF-8")
        let wire = try await encode(command.toTaggedCommand(tag: "C001"))

        #expect(wire.hasPrefix("C001 UID SEARCH CHARSET UTF-8 "))
        #expect(wire.contains("TEXT"))
    }

    @Test
    func testSearchCommandOmitsCharsetByDefault() async throws {
        let command = SearchCommand<UID>(criteria: [.text("invoice")])
        let wire = try await encode(command.toTaggedCommand(tag: "C002"))

        #expect(wire.hasPrefix("C002 UID SEARCH "))
        #expect(!wire.contains("CHARSET"))
    }

    @Test
    func testExtendedSearchCommandSendsCharsetWithReturnOptions() async throws {
        let command = ExtendedSearchCommand<UID>(
            criteria: [.text("invoice")],
            useEsearch: true,
            charset: "UTF-8"
        )
        let wire = try await encode(command.toTaggedCommand(tag: "C003"))

        #expect(wire.contains("UID SEARCH RETURN ("))
        #expect(wire.contains("CHARSET UTF-8 "))
    }

    @Test
    func testExtendedSearchCommandSendsCharsetWithoutEsearch() async throws {
        let command = ExtendedSearchCommand<SequenceNumber>(
            criteria: [.subject("hello")],
            useEsearch: false,
            charset: "UTF-8"
        )
        let wire = try await encode(command.toTaggedCommand(tag: "C004"))

        #expect(wire.hasPrefix("C004 SEARCH CHARSET UTF-8 "))
    }

    @Test
    func testCharsetMustBeAPlainAtom() {
        for bad in ["", "UTF-8 ALL", "UTF-8\r\nA2 LOGOUT", "\"UTF-8\""] {
            #expect(throws: IMAPError.self) {
                try SearchCommand<UID>(criteria: [.all], charset: bad).validate()
            }
            #expect(throws: IMAPError.self) {
                try ExtendedSearchCommand<UID>(criteria: [.all], useEsearch: false, charset: bad).validate()
            }
        }
        #expect(throws: Never.self) {
            try SearchCommand<UID>(criteria: [.all], charset: "UTF-8").validate()
        }
    }

    @Test
    func testPublicSearchPassesCharsetThrough() async throws {
        let (server, channel) = try await makeHarness(capabilities: [])

        let resultTask = Task {
            let found: [UID] = try await server.search(
                criteria: [.text("invoice")],
                sortCriteria: [],
                charset: "UTF-8"
            )
            return found
        }

        let line = try #require(try await nextOutboundString(from: channel))
        #expect(line.contains("UID SEARCH CHARSET UTF-8 TEXT"))

        try await respond(on: channel, "* SEARCH 7 3\r\n\(tag(of: line)) OK SEARCH completed\r\n")
        #expect(Set(try await resultTask.value) == [UID(3), UID(7)])
    }

    // MARK: - X-GM-RAW

    @Test
    func testGmailRawSearchQuotesTheRawStringAndReturnsUIDs() async throws {
        let (server, channel) = try await makeHarness(capabilities: [.gmailExtensions])

        let resultTask = Task {
            try await server.uidSearchGmailRaw(#"from:alice has:attachment "Q3 report""#)
        }

        let line = try #require(try await nextOutboundString(from: channel))
        // Read-only: the only thing sent is UID SEARCH; nothing selects a mailbox first.
        #expect(!line.contains("SELECT") && !line.contains("EXAMINE"))
        #expect(line.hasSuffix(
            #" UID SEARCH CHARSET UTF-8 X-GM-RAW "from:alice has:attachment \"Q3 report\""\#r\#n"#
        ))

        try await respond(on: channel, "* SEARCH 9 5 12\r\n\(tag(of: line)) OK SEARCH completed (Success)\r\n")
        #expect(try await resultTask.value == [UID(5), UID(9), UID(12)])
    }

    @Test
    func testGmailRawSearchSendsNonASCIIAsUTF8Literal() async throws {
        let (server, channel) = try await makeHarness(capabilities: [.gmailExtensions])
        let raw = "faktúra in:inbox"

        let resultTask = Task {
            try await server.uidSearchGmailRaw(raw)
        }

        let head = try #require(try await nextOutboundString(from: channel))
        #expect(head.hasSuffix(" UID SEARCH CHARSET UTF-8 X-GM-RAW {\(raw.utf8.count)}\r\n"))

        // A synchronizing literal waits for the server's continuation before the bytes go out.
        try await respond(on: channel, "+ go ahead\r\n")
        let bodyBuffer = try #require(try await nextOutboundBuffer(from: channel))
        #expect(Array(bodyBuffer.readableBytesView) == Array((raw + "\r\n").utf8))

        try await respond(on: channel, "* SEARCH 42\r\n\(tag(of: head)) OK SEARCH completed (Success)\r\n")
        #expect(try await resultTask.value == [UID(42)])
    }

    @Test
    func testGmailRawSearchEmptyResult() async throws {
        let (server, channel) = try await makeHarness(capabilities: [.gmailExtensions])

        let resultTask = Task { try await server.uidSearchGmailRaw("older_than:1y") }
        let line = try #require(try await nextOutboundString(from: channel))

        try await respond(on: channel, "* SEARCH\r\n\(tag(of: line)) OK SEARCH completed (Success)\r\n")
        #expect(try await resultTask.value.isEmpty)
    }

    @Test
    func testGmailRawSearchSurfacesServerError() async throws {
        let (server, channel) = try await makeHarness(capabilities: [.gmailExtensions])

        let resultTask = Task { try await server.uidSearchGmailRaw("label:x") }
        let line = try #require(try await nextOutboundString(from: channel))

        try await respond(on: channel, "\(tag(of: line)) BAD Could not parse command\r\n")
        await #expect(throws: IMAPError.self) { try await resultTask.value }
    }

    @Test
    func testGmailRawSearchRefusesServersWithoutGmailExtensions() async throws {
        let (server, channel) = try await makeHarness(capabilities: [.uidPlus, .move])

        await #expect(throws: IMAPError.self) {
            try await server.uidSearchGmailRaw("has:attachment")
        }
        #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
    }

    @Test
    func testGmailRawSearchRejectsEmptyQuery() async throws {
        let (server, channel) = try await makeHarness(capabilities: [.gmailExtensions])

        await #expect(throws: IMAPError.self) {
            try await server.uidSearchGmailRaw("   ")
        }
        #expect(try await channel.readOutbound(as: ByteBuffer.self) == nil)
    }

    // MARK: - Helpers

    private func encode(_ tagged: TaggedCommand) async throws -> String {
        let channel = try await NIOAsyncTestingChannel.withIMAPClientHandler()
        try await channel.writeAndFlush(IMAPClientHandler.OutboundIn.part(CommandStreamPart.tagged(tagged)))
        var outbound = try #require(try await channel.readOutbound(as: ByteBuffer.self))
        return outbound.readString(length: outbound.readableBytes) ?? ""
    }

    /// Wires an `IMAPServer`'s primary connection to an embedded channel, as
    /// `FetchGmailAttributesTests` does, with a chosen capability set.
    private func makeHarness(
        capabilities: Set<NIOIMAPCore.Capability>
    ) async throws -> (server: SwiftMail.IMAPServer, channel: NIOAsyncTestingChannel) {
        let server = SwiftMail.IMAPServer(host: "localhost", port: 143, useTLS: false)
        let connection = await server.primaryConnection

        let channel = NIOAsyncTestingChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 143)
        try await channel.connect(to: address)
        try await channel.addIMAPClientHandler()
        try await channel.pipeline.addHandler(connection.duplexLogger)
        try await channel.pipeline.addHandler(connection.responseBuffer)
        connection.replaceChannelForTesting(channel)
        connection.replaceCapabilitiesForTesting(capabilities)

        return (server, channel)
    }

    private func tag(of commandLine: String) -> String {
        String(commandLine.prefix { $0 != " " })
    }

    private func respond(on channel: NIOAsyncTestingChannel, _ text: String) async throws {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        try await channel.writeInbound(buffer)
    }

    private func nextOutboundString(from channel: NIOAsyncTestingChannel) async throws -> String? {
        guard var buffer = try await nextOutboundBuffer(from: channel) else { return nil }
        return buffer.readString(length: buffer.readableBytes)
    }

    private func nextOutboundBuffer(
        from channel: NIOAsyncTestingChannel,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> ByteBuffer? {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if let buffer = try await channel.readOutbound(as: ByteBuffer.self) {
                return buffer
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}
