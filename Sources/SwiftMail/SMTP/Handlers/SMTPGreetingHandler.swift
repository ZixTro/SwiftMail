import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Logging

/// Handler for processing the initial greeting from the SMTP server.
///
/// The channel initializer installs it before the TCP connection completes, so a greeting
/// sent the instant the connection is up is captured instead of falling off the end of the
/// pipeline. Unlike command handlers it does not remove itself: `connect()` reads the result
/// and then removes it. Anything that arrives after the greeting is passed on unchanged.
final class SMTPGreetingHandler: BaseSMTPHandler<SMTPGreeting>, @unchecked Sendable {
    /// Touched only on the channel's event loop.
    private var greetingReceived = false

    /// Handle a successful response by parsing the greeting
    override func handleSuccess(response: SMTPResponse) {
        // Create a greeting object from the response
        let greeting = SMTPGreeting(code: response.code, message: response.message)
        promise.succeed(greeting)
    }

    override public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !greetingReceived else {
            context.fireChannelRead(data)
            return
        }
        if processResponse(unwrapInboundIn(data)) {
            greetingReceived = true
        }
    }

    override public func handlerRemoved(context: ChannelHandlerContext) {
        // Every path must complete the promise (NIO traps on a leaked one in debug builds);
        // failing an already completed promise is a no-op.
        promise.fail(SMTPError.connectionFailed("Connection closed before the server greeting"))
    }
}

/// The greeting handler of each channel a connect attempt creates.
///
/// `ClientBootstrap` may create several channels for one connect (happy eyeballs over IPv4 and
/// IPv6), each with its own pipeline, so each gets its own handler and `connect()` picks the
/// one belonging to the channel that won.
final class SMTPGreetingHandlers: Sendable {
    private let handlers = NIOLockedValueBox<[ObjectIdentifier: SMTPGreetingHandler]>([:])

    /// Create and remember the greeting handler for a new channel.
    func makeHandler(for channel: Channel) -> SMTPGreetingHandler {
        let handler = SMTPGreetingHandler(
            commandTag: "",
            promise: channel.eventLoop.makePromise(of: SMTPGreeting.self)
        )
        handlers.withLockedValue { $0[ObjectIdentifier(channel)] = handler }
        return handler
    }

    func handler(for channel: Channel) -> SMTPGreetingHandler? {
        handlers.withLockedValue { $0[ObjectIdentifier(channel)] }
    }
}

/// Structure representing an SMTP server greeting
struct SMTPGreeting {
    /// The response code (usually 220)
    let code: Int

    /// The greeting message from the server
    let message: String

    /// Whether the server advertises ESMTP support in the greeting
    var supportsESMTP: Bool {
        return message.contains("ESMTP")
    }
}
