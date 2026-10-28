import Foundation
import Testing
@testable import SwiftMail

@Suite
struct MessageInfoRawHeaderFieldsCodableTests {
    private let raw = "Authentication-Results: mx.google.com;\r\n\tdkim=pass header.d=firma.sk\r\n"
        + "Authentication-Results: relay.evil.example;\r\n\tdmarc=pass header.from=paypal.com\r\n\r\n"

    @Test
    func testRawHeaderFieldsRoundTripsThroughCodable() throws {
        let original = MessageInfo(
            sequenceNumber: SequenceNumber(3),
            uid: UID(42),
            subject: "Hello",
            rawHeaderFields: raw
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageInfo.self, from: data)

        #expect(decoded.rawHeaderFields.map { Array($0.utf8) } == Array(raw.utf8))
        #expect(decoded.subject == "Hello")
        #expect(decoded.uid == UID(42))
    }

    @Test
    func testEncodedJSONCarriesTheRawHeaderFieldsKey() throws {
        let data = try JSONEncoder().encode(MessageInfo(sequenceNumber: SequenceNumber(1), rawHeaderFields: raw))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["rawHeaderFields"] as? String == raw)
    }

    @Test
    func testDecodingJSONWithoutTheKeyGivesNil() throws {
        // Data stored before the key existed: take a real encoding and drop the key.
        let withKey = try JSONEncoder().encode(
            MessageInfo(sequenceNumber: SequenceNumber(5), subject: "Old row", rawHeaderFields: raw)
        )
        var object = try #require(try JSONSerialization.jsonObject(with: withKey) as? [String: Any])
        #expect(object.removeValue(forKey: "rawHeaderFields") != nil)
        let oldJSON = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(MessageInfo.self, from: oldJSON)

        #expect(decoded.rawHeaderFields == nil)
        #expect(decoded.subject == "Old row")
        #expect(decoded.sequenceNumber == SequenceNumber(5))
    }

    @Test
    func testNilRawHeaderFieldsRoundTripsAsNil() throws {
        let data = try JSONEncoder().encode(MessageInfo(sequenceNumber: SequenceNumber(2)))
        let decoded = try JSONDecoder().decode(MessageInfo.self, from: data)

        #expect(decoded.rawHeaderFields == nil)
    }
}
