// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

/// PR #870 incelemesi: TV'nin başlattığı eşleşme onaylanınca TV kaydedilmiyordu (bekçi ve TV kartı çalışmıyordu).
final class PairedTVTests: XCTestCase {
    func testTVHostFromPeer() {
        XCTAssertEqual(SubtitleAccess.tvHost(fromPeer: "192.168.1.40"), "192.168.1.40")
        XCTAssertEqual(SubtitleAccess.tvHost(fromPeer: "::ffff:192.168.1.40"), "192.168.1.40")
        XCTAssertEqual(SubtitleAccess.tvHost(fromPeer: "fe80::1%en0"), "fe80::1")
        // Bu cihazın kendisi (ikinci ekran sayfası) ve internet adresi TV sayılmaz.
        XCTAssertEqual(SubtitleAccess.tvHost(fromPeer: "127.0.0.1"), "")
        XCTAssertEqual(SubtitleAccess.tvHost(fromPeer: "::1"), "")
        XCTAssertEqual(SubtitleAccess.tvHost(fromPeer: "8.8.8.8"), "")
        XCTAssertEqual(SubtitleAccess.tvHost(fromPeer: ""), "")
    }

    func testTicketCarriesRequesterAddress() {
        let pairing = SubtitlePairing()
        pairing.setSession(true)
        let ticket = pairing.begin(host: "192.168.1.40")
        XCTAssertEqual(ticket?.host, "192.168.1.40")
        XCTAssertEqual(pairing.pending?.host, "192.168.1.40")
    }

    func testAdoptsOnlyWhenNoChosenTV() {
        let lg = LGTV(name: "LG", host: "192.168.1.30")
        XCTAssertTrue(PairedTV.shouldAdopt(host: "192.168.1.40", saved: nil, hasKey: false))
        // TV seçilmiş ama izni alınmamış: eşleşen TV kaydedilir.
        XCTAssertTrue(PairedTV.shouldAdopt(host: "192.168.1.40", saved: lg, hasKey: false))
        // Adresi bilinmeyen Android TV kaydı bu TV'nin adresiyle tamamlanır.
        XCTAssertTrue(PairedTV.shouldAdopt(host: "192.168.1.40", saved: LGTV(name: "Android TV", host: "", brand: .androidTV), hasKey: true))
        // Kullanıcının seçtiği, izinli TV değiştirilmez; adresi bilinmeyen istek kaydedilmez.
        XCTAssertFalse(PairedTV.shouldAdopt(host: "192.168.1.40", saved: lg, hasKey: true))
        XCTAssertFalse(PairedTV.shouldAdopt(host: "192.168.1.30", saved: lg, hasKey: true))
        XCTAssertFalse(PairedTV.shouldAdopt(host: "", saved: nil, hasKey: false))
    }
}
