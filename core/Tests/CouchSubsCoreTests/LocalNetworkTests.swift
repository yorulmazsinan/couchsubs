// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import XCTest
@testable import CouchSubsCore

final class LocalNetworkTests: XCTestCase {
    private func address(_ text: String) -> in_addr { in_addr(s_addr: inet_addr(text)) }

    func testScanCoversTheWholeHomeNetworkExceptThisComputer() {
        let targets = LocalNetwork.scanTargets([address("192.168.1.40")])
        XCTAssertEqual(targets.count, 253)
        XCTAssertTrue(targets.contains("192.168.1.1"))
        XCTAssertTrue(targets.contains("192.168.1.254"))
        XCTAssertFalse(targets.contains("192.168.1.40"))
    }

    func testTwoAdaptersOnTheSameNetworkAreScannedOnce() {
        let targets = LocalNetwork.scanTargets([address("10.0.0.5"), address("10.0.0.6")])
        XCTAssertEqual(targets.count, Set(targets).count)
    }

    func testOnlyHomeNetworkAddressesArePrivate() {
        XCTAssertTrue(LocalNetwork.isPrivate(address("192.168.0.10")))
        XCTAssertTrue(LocalNetwork.isPrivate(address("172.20.1.1")))
        XCTAssertTrue(LocalNetwork.isPrivate(address("10.1.2.3")))
        XCTAssertFalse(LocalNetwork.isPrivate(address("8.8.8.8")))
        XCTAssertFalse(LocalNetwork.isPrivate(address("172.32.0.1")))
    }

    // Host PC IP: VPN ve sanal bağdaştırıcılar seçilmez (Duhan Ay, 2026-11-13).
    private let wifi = NetworkAddress.Candidate(interface: "en0", address: "192.168.1.34", netmask: "255.255.255.0")
    private let vpn = NetworkAddress.Candidate(interface: "utun4", address: "10.8.0.2", netmask: "255.255.255.0", pointToPoint: true)
    private let vm = NetworkAddress.Candidate(interface: "bridge100", address: "192.168.64.1", netmask: "255.255.255.0")

    func testTheAdapterOnTheTVsNetworkIsChosen() {
        XCTAssertEqual(NetworkAddress.choose([vpn, vm, wifi], near: "192.168.1.171"), "192.168.1.34")
    }

    func testWithoutATVAddressWiFiWinsOverVPNAndVirtualMachines() {
        XCTAssertEqual(NetworkAddress.choose([vpn, vm, wifi], near: nil), "192.168.1.34")
        XCTAssertEqual(NetworkAddress.choose([vm, wifi], near: "10.0.0.5"), "192.168.1.34")
    }

    func testAVirtualAdapterIsUsedOnlyWhenNothingElseExists() {
        XCTAssertEqual(NetworkAddress.choose([vpn], near: nil), "10.8.0.2")
        XCTAssertNil(NetworkAddress.choose([], near: nil))
    }
}
