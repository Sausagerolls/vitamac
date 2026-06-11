import XCTest
@testable import MonitorKit

final class FramingTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let msg = ClientMessage.kill(pid: 1234, signal: 15, startTime: 99, sessionNonce: 7)
        let framed = try MonitorFraming.frame(msg)
        XCTAssertGreaterThan(framed.count, 4)

        var buffer = framed
        guard let payload = try MonitorFraming.nextPayload(from: &buffer) else {
            return XCTFail("expected a complete frame")
        }
        XCTAssertTrue(buffer.isEmpty)
        let decoded = try MonitorFraming.decoder.decode(ClientMessage.self, from: payload)
        if case let .kill(pid, signal, startTime, nonce) = decoded {
            XCTAssertEqual(pid, 1234)
            XCTAssertEqual(signal, 15)
            XCTAssertEqual(startTime, 99)
            XCTAssertEqual(nonce, 7)
        } else {
            XCTFail("wrong case decoded")
        }
    }

    func testPartialFrameReturnsNil() throws {
        var buffer = Data([0, 0, 0, 8, 1, 2])  // claims 8 bytes, only 2 present
        XCTAssertNil(try MonitorFraming.nextPayload(from: &buffer))
        XCTAssertEqual(buffer.count, 6, "incomplete frame must be left intact")
    }

    func testTwoFramesInOneBuffer() throws {
        var buffer = Data()
        buffer.append(try MonitorFraming.frame(ClientMessage.ping))
        buffer.append(try MonitorFraming.frame(ClientMessage.requestSnapshot))
        XCTAssertNotNil(try MonitorFraming.nextPayload(from: &buffer))
        XCTAssertNotNil(try MonitorFraming.nextPayload(from: &buffer))
        XCTAssertNil(try MonitorFraming.nextPayload(from: &buffer))
    }

    func testOversizedFrameThrows() {
        // length prefix of 0x7FFFFFFF (~2 GiB) exceeds the cap → must throw,
        // not silently buffer.
        var buffer = Data([0x7F, 0xFF, 0xFF, 0xFF, 0x00])
        XCTAssertThrowsError(try MonitorFraming.nextPayload(from: &buffer)) { error in
            guard case MonitorFramingError.frameTooLarge = error else {
                return XCTFail("expected frameTooLarge, got \(error)")
            }
        }
    }
}
