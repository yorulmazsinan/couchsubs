// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import RemotePlay

final class PSNAccountTests: XCTestCase {
    func testCodeIsReadFromRedirect() {
        let url = URL(string: PSNAccount.redirectPrefix + "?code=AbC123&cid=x")!
        XCTAssertEqual(PSNAccount.code(fromRedirect: url), "AbC123")
    }

    func testNonRedirectUrlHasNoCode() {
        XCTAssertNil(PSNAccount.code(fromRedirect: URL(string: "https://example.com/redirect?code=AbC123")!))
    }

    /// Tarayıcıda giriş: adres çubuğundan kopyalanan metin boşluk, tırnak ya da başka yazıyla gelebilir (Windows'taki
    /// PsnAccountTests ile aynı örnekler).
    func testPastedBrowserAddressGivesTheRedirectWithItsCode() {
        for pasted in [
            "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=AbC123&cid=x",
            "  https://remoteplay.dl.playstation.net/remoteplay/redirect?code=AbC123&cid=x\r\n",
            "\"https://remoteplay.dl.playstation.net/remoteplay/redirect?code=AbC123\"",
            "redirect https://remoteplay.dl.playstation.net/remoteplay/redirect?code=AbC123 copied",
        ] {
            let redirect = PSNAccount.redirect(fromPastedText: pasted)
            XCTAssertEqual(redirect.flatMap(PSNAccount.code(fromRedirect:)), "AbC123", pasted)
        }
    }

    func testPastedTextWithoutACodeIsRejected() {
        for pasted in [
            nil, "",
            "https://my.account.sony.com/central/signin/",
            "https://remoteplay.dl.playstation.net/remoteplay/redirect",
            "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=",
            "https://example.com/?u=https://remoteplay.dl.playstation.net/remoteplay/redirectx",
        ] as [String?] {
            XCTAssertNil(PSNAccount.redirect(fromPastedText: pasted), pasted ?? "nil")
        }
    }

    func testPastedSonyErrorRedirectIsKeptForItsMessage() {
        let redirect = PSNAccount.redirect(fromPastedText: PSNAccount.redirectPrefix + "?error=access_denied&error_description=denied")
        XCTAssertEqual(redirect.flatMap(PSNAccount.error(fromRedirect:))?.hasPrefix("access_denied"), true)
    }

    /// Windows'taki PsnAccountTests ile aynı örnekler.
    func testSonyServerUnreachablePageIsRecognised() {
        for text in ["Can't connect to the server.", "Can\u{2019}t connect to the server", "Cannot connect to the server",
                     "Could not connect to the server", "Sign in\nUnable to connect to the server\nTry again"] {
            XCTAssertTrue(PSNAccount.looksServerUnreachable(text), text)
        }
        for text in [nil, "", "Sign in to PlayStation Network", "Connect to the server room"] as [String?] {
            XCTAssertFalse(PSNAccount.looksServerUnreachable(text), text ?? "nil")
        }
    }

    func testPageTextIsOnlyTrustedFromSonyHosts() {
        XCTAssertTrue(PSNAccount.isSonyHost("my.account.sony.com"))
        XCTAssertTrue(PSNAccount.isSonyHost("ca.account.sony.com"))
        XCTAssertTrue(PSNAccount.isSonyHost("remoteplay.dl.playstation.net"))
        XCTAssertFalse(PSNAccount.isSonyHost("accounts.google.com"))
        XCTAssertFalse(PSNAccount.isSonyHost(nil))
    }

    func testUserIdBecomesEightLittleEndianBytes() {
        XCTAssertEqual(PSNAccount.accountIdBytes(userId: "1")?.base64EncodedString(), "AQAAAAAAAAA=")
        XCTAssertEqual(PSNAccount.accountIdBytes(userId: "258")?.map { $0 }, [2, 1, 0, 0, 0, 0, 0, 0])
    }

    func testInvalidUserIdIsRejected() {
        XCTAssertNil(PSNAccount.accountIdBytes(userId: "abc"))
        XCTAssertNil(PSNAccount.accountIdBytes(userId: ""))
    }

    func testBase64AccountIdAcceptsEightBytesAndTrimsWhitespace() {
        let id = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(PSNAccount.accountId(fromBase64: id.base64EncodedString()), id)
        XCTAssertEqual(PSNAccount.accountId(fromBase64: "  AQID BAUG\nBwg=  "), id)
    }

    func testInvalidBase64AccountIdIsRejected() {
        for value in ["", "   ", "AQIDBAUGBw==", "AQIDBAUGBwgJ", "AQIDBAUGBw!=", "1234567890", "AQIDBAUGBwg"] {
            XCTAssertNil(PSNAccount.accountId(fromBase64: value), value)
        }
    }

    /// Sony girişi tamamlamazsa yönlendirmede kod yerine hata gelir; o hata okunur ve token isteği yapılmaz.
    func testRedirectErrorIsRead() async {
        let url = URL(string: PSNAccount.redirectPrefix + "?error=access_denied&error_description=Access+denied&error_code=4002")!
        XCTAssertNil(PSNAccount.code(fromRedirect: url))
        XCTAssertEqual(PSNAccount.error(fromRedirect: url), "access_denied: Access denied (4002)")
        XCTAssertNil(PSNAccount.error(fromRedirect: URL(string: PSNAccount.redirectPrefix + "?code=x")!))
        do {
            _ = try await PSNAccount.accountId(fromRedirect: url)
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? PSNAccount.PSNError, .refused(status: nil, detail: "access_denied: Access denied (4002)"))
        }
        do {
            _ = try await PSNAccount.accountId(fromRedirect: URL(string: PSNAccount.redirectPrefix + "?cid=x")!)
            XCTFail("Hata bekleniyordu")
        } catch {
            XCTAssertEqual(error as? PSNAccount.PSNError, .noCode)
        }
    }

    /// Sony'nin HTTP hatası sınıflanır; JSON hatası ayrıntıya taşınır.
    func testHttpFailuresAreClassified() {
        let grant = Data(#"{"error":"invalid_grant","error_description":"Invalid authorization code","error_code":4165}"#.utf8)
        XCTAssertEqual(PSNAccount.failure(status: 400, body: grant),
                       .refused(status: 400, detail: "invalid_grant: Invalid authorization code (4165)"))
        XCTAssertEqual(PSNAccount.failure(status: 429, body: Data("Too Many Requests".utf8)),
                       .rateLimited(status: 429, detail: "Too Many Requests"))
        XCTAssertEqual(PSNAccount.failure(status: 503, body: Data()), .http(503, detail: nil))
        XCTAssertEqual(PSNAccount.sonyError(["error": "invalid_grant"]), "invalid_grant")
        XCTAssertNil(PSNAccount.sonyError(["access_token": "x"]))
    }

    func testAuthorizeUrlPointsToSonyWithRemotePlayRedirect() {
        let url = PSNAccount.authorizeURL.absoluteString
        XCTAssertTrue(url.hasPrefix("https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?"))
        XCTAssertTrue(url.contains("redirect_uri=https://remoteplay.dl.playstation.net/remoteplay/redirect"))
    }
}
