import XCTest
import Foundation
import SwiftProtobuf
@testable import TeslaBLEKeyKit

final class MockConnector: VehicleConnector {
    var vin = "5YJYGDEE0MF000000"
    let localName = "S0000000000000000C"
    let retryInterval: TimeInterval = 1
    let allowedLatency: TimeInterval = 4
    let preferredAuthMethod: ConnectorAuthMethod = .aesGCM
    var sent: [Data] = []
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    init() { let pair = AsyncStream<Data>.makeStream(); stream = pair.stream; continuation = pair.continuation }
    func receiveMessages() -> AsyncStream<Data> { stream }
    func send(_ data: Data) async throws {
        sent.append(data)
        var response = VCSEC_FromVCSECMessage()
        response.commandStatus.whitelistOperationStatus.whitelistOperationInformation = .init(rawValue: 0)!
        var routed = UniversalMessage_RoutableMessage()
        routed.protobufMessageAsBytes = try response.serializedData()
        continuation.yield(try routed.serializedData())
    }
    func close() { continuation.finish() }
}

final class InspectorTests: XCTestCase {
    func testExactlyOneEmptyEndpointPerRequest() throws {
        XCTAssertEqual(InspectorEndpoint.allCases.count, 24)
        for endpoint in InspectorEndpoint.allCases {
            let bytes = try endpoint.request().serializedData()
            // Each request is one tag (1 or 2 bytes) + a zero length empty message.
            XCTAssertTrue(bytes.count == 2 || bytes.count == 3)
            XCTAssertEqual(bytes.last, 0)
            let roundTrip = try CarServer_GetVehicleData(serializedBytes: bytes)
            XCTAssertEqual(roundTrip, endpoint.request())
        }
    }
    func testUnknownBytesSurviveSwiftRoundTrip() throws {
        let bytes = Data([0x80, 0xe2, 0x09, 0xe1, 0x5b])
        let response = try CarServer_Response(serializedBytes: bytes)
        XCTAssertEqual(try response.serializedData(), bytes)
    }
    func testBLEFragmentationAndConcatenation() throws {
        let first = Data([1,2,3]); let second = Data([4,5])
        let combined = try BLEFramer.encode(first) + BLEFramer.encode(second)
        var framer = BLEFramer()
        XCTAssertEqual(try framer.receive(combined.prefix(1)), [])
        XCTAssertEqual(try framer.receive(combined.dropFirst()), [first, second])
    }
    func testPairingRequestsMonitorOnly() async throws {
        let connector = MockConnector()
        try await TeslaPairing(connector: connector).requestPairing(publicKey: Data(repeating: 1, count: 65))
        let routed = try UniversalMessage_RoutableMessage(serializedBytes: connector.sent[0])
        let request = try VCSEC_UnsignedMessage(serializedBytes: routed.protobufMessageAsBytes)
        XCTAssertEqual(request.whitelistOperation.addKeyToWhitelistAndAddPermissions.keyRole, .vehicleMonitor)
        XCTAssertEqual(routed.fromDestination.routingAddress.count, 16)
        XCTAssertEqual(connector.sent.count, 1)
    }
    func testDriverRoleRejectedBeforeSending() async throws {
        let connector = MockConnector()
        do {
            try await TeslaPairing(connector: connector).requestPairing(publicKey: Data(), role: .driver)
            XCTFail("Driver role must be rejected")
        } catch { XCTAssertEqual(connector.sent.count, 0) }
    }
}
