// Ana ekranın gezinme yığını: ekranlar yığını `pop(route)` ile kapatır. TestFlight çökmesi (yapı 18): "Altyazı hedefi"
// ekranında "Tamam"a iki kez dokununca ikinci dokunuş boş yığında `removeLast()` çağırıyor, uygulama kapanıyordu.

import XCTest
@testable import CouchSubs

final class RoutePopTests: XCTestCase {
    func testPopsTheScreenOnTop() {
        var path: [Route] = [.profile, .target]
        XCTAssertTrue(path.pop(.target))
        XCTAssertEqual(path, [.profile])
    }

    func testSecondTapOnEmptyStackDoesNothing() {
        var path: [Route] = [.target]
        XCTAssertTrue(path.pop(.target))
        XCTAssertFalse(path.pop(.target))
        XCTAssertEqual(path, [])
    }

    func testSecondTapDoesNotCloseTheScreenBelow() {
        var path: [Route] = [.settings, .platform]
        XCTAssertTrue(path.pop(.platform))
        XCTAssertFalse(path.pop(.platform))
        XCTAssertEqual(path, [.settings])
    }

    /// Giriş bitince "kapat, eşlemeyi aç": ikinci dokunuş eşleme ekranını bir kez daha açmaz.
    func testReplaceHappensOnlyOnce() {
        var path: [Route] = [.platform]
        for _ in 0..<2 where path.pop(.platform) { path.append(.ps5) }
        XCTAssertEqual(path, [.ps5])
    }
}
