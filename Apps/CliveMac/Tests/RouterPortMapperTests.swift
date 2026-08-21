import CliveCore
import XCTest
@testable import Clive

final class RouterPortMapperTests: XCTestCase {
    func testPCPResponseReturnsAssignedPublicEndpoint() throws {
        let nonce = Data(repeating: 7, count: 12)
        var response = Data([2, 0x81, 0, 0]); response.appendUInt32(3600)
        response.append(Data(repeating: 0, count: 16)); response.append(nonce)
        response.append(contentsOf: [6, 0, 0, 0]); response.appendUInt16(64236); response.appendUInt16(443)
        response.append(Data(repeating: 0, count: 10)); response.append(contentsOf: [0xff, 0xff, 203, 0, 113, 8])
        let mapping = try RouterPortMapper.parsePCPResponse(response, nonce: nonce, internalPort: 64236)
        XCTAssertEqual(mapping.host, "203.0.113.8")
        XCTAssertEqual(mapping.externalPort, 443)
        XCTAssertEqual(mapping.method, .pcp)
    }

    func testNATPMPResponsesReturnAssignedPort() throws {
        var address = Data([0, 128, 0, 0]); address.appendUInt32(1); address.append(contentsOf: [198, 51, 100, 7])
        XCTAssertEqual(try RouterPortMapper.parseNATPMPAddressResponse(address), "198.51.100.7")
        var mapping = Data([0, 130, 0, 0]); mapping.appendUInt32(1); mapping.appendUInt16(64236); mapping.appendUInt16(42424); mapping.appendUInt32(3600)
        XCTAssertEqual(try RouterPortMapper.parseNATPMPMappingResponse(mapping, host: "198.51.100.7", internalPort: 64236).externalPort, 42424)
    }

    func testNATPMPRejectsPrivateExternalAddress() {
        var response = Data([0, 128, 0, 0]); response.appendUInt32(1); response.append(contentsOf: [100, 64, 0, 1])
        XCTAssertThrowsError(try RouterPortMapper.parseNATPMPAddressResponse(response))
    }
}
