import Foundation
import NIO
import Testing
@testable import SwiftMail

/// A server may send its 220 greeting the instant the TCP connection is up. The client
/// must never lose it to the gap between "connected" and "listening for the greeting".
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPEarlyGreetingTests {
    @Test
    func connectKeepsAGreetingThatArrivesBeforeTheClientIsListening() async throws {
        try await LoopbackSMTPServer.run { port in
            let client = SMTPServer(host: "127.0.0.1", port: port, transportSecurity: .plainText)
            // Hold the client between TCP connect and the greeting wait, so the greeting
            // has certainly arrived by the time the client starts listening for it.
            await client.setAfterConnectHookForTesting {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            let started = Date()
            try await client.connect()
            #expect(Date().timeIntervalSince(started) < 3, "greeting was not lost to a 5 s timeout")
            #expect(await client.supports8BitMIME)
            try await client.disconnect()
        }
    }

    @Test
    func connectSucceedsRepeatedlyAgainstAServerThatGreetsImmediately() async throws {
        try await LoopbackSMTPServer.run { port in
            for _ in 0..<10 {
                let client = SMTPServer(host: "127.0.0.1", port: port, transportSecurity: .plainText)
                let started = Date()
                try await client.connect()
                #expect(Date().timeIntervalSince(started) < 3)
                #expect(await client.supports8BitMIME)
                try await client.disconnect()
            }
        }
    }

    @Test
    func connectThroughAHostnameUsesTheWinningChannelsGreeting() async throws {
        // "localhost" can resolve to ::1 and 127.0.0.1; the server listens on IPv4 only, so
        // a happy-eyeballs connect may create more than one channel before one wins.
        try await LoopbackSMTPServer.run { port in
            let client = SMTPServer(host: "localhost", port: port, transportSecurity: .plainText)
            try await client.connect()
            #expect(await client.supports8BitMIME)
            try await client.disconnect()
        }
    }

    @Test
    func connectToAClosedPortFailsWithoutHanging() async throws {
        var closedPort = 0
        try await LoopbackSMTPServer.run { port in closedPort = port }

        let client = SMTPServer(host: "127.0.0.1", port: closedPort, transportSecurity: .plainText)
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }

    @Test
    func connectStillReportsARejectingGreeting() async throws {
        try await LoopbackSMTPServer.run(greeting: "554 no service here\r\n") { port in
            let client = SMTPServer(host: "127.0.0.1", port: port, transportSecurity: .plainText)
            await #expect(throws: SMTPError.self) {
                try await client.connect()
            }
        }
    }
}

/// A minimal loopback SMTP server that writes its greeting in `channelActive`, i.e. as
/// soon as the connection is accepted, then answers EHLO and QUIT.
private enum LoopbackSMTPServer {
    static func run(
        greeting: String = "220 loopback.test ESMTP ready\r\n",
        _ body: (Int) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(GreeterHandler(greeting: greeting))
                }
            }
        let serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        do {
            let port = try #require(serverChannel.localAddress?.port)
            try await body(port)
        } catch {
            try? await serverChannel.close()
            try? await group.shutdownGracefully()
            throw error
        }
        try? await serverChannel.close()
        try? await group.shutdownGracefully()
    }

    private final class GreeterHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let greeting: String
        private var pending = ""

        init(greeting: String) {
            self.greeting = greeting
        }

        func channelActive(context: ChannelHandlerContext) {
            send(greeting, context: context)
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            pending += buffer.readString(length: buffer.readableBytes) ?? ""
            while let end = pending.range(of: "\r\n") {
                let line = String(pending[..<end.lowerBound])
                pending.removeSubrange(..<end.upperBound)
                switch line.prefix(4).uppercased() {
                case "EHLO":
                    send("250-loopback.test\r\n250 8BITMIME\r\n", context: context)
                case "QUIT":
                    send("221 bye\r\n", context: context)
                    context.close(promise: nil)
                    return
                default:
                    send("250 OK\r\n", context: context)
                }
            }
        }

        private func send(_ text: String, context: ChannelHandlerContext) {
            var out = context.channel.allocator.buffer(capacity: text.utf8.count)
            out.writeString(text)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
    }
}
