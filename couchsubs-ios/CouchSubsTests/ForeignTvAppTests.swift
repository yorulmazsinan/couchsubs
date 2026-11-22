// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubs

/// TV'de CouchSubs kimliğiyle (com.couchsubs.tv, CouchSubsT) kurulu uygulamanın bizim olup olmadığı. Bizim olmayan
/// uygulama onaysız kaldırılmaz; ekran kullanıcıya sorar (Mac, Windows ve Android ile aynı kurallar).
final class ForeignTvAppTests: XCTestCase {
    // MARK: Android TV (dumpsys imza özeti)

    private func dumpsys(_ signatures: String?) -> String {
        var lines = ["Packages:", "  Package [com.couchsubs.tv] (1a2b3c):", "    versionName=0.9.74"]
        if let signatures { lines.append("    signatures=\(signatures)") }
        lines.append("    User 0: ceDataInode=1 installed=true hidden=false")
        return lines.joined(separator: "\r\n")
    }

    func testOurSignatureInNewAndOldFormatsIsNotForeign() {
        let new = dumpsys("PackageSignatures{a1b2c3 version:2, signatures:[32d37cf9], past signatures:[]}")
        let old = dumpsys("PackageSignatures{41ab21 [32d37cf9]}")
        XCTAssertEqual(AndroidTvInstaller.signatureHashes(new), ["32d37cf9"])
        XCTAssertEqual(AndroidTvInstaller.signatureHashes(old), ["32d37cf9"])
        XCTAssertFalse(AndroidTvInstaller.isForeign(new))
        XCTAssertFalse(AndroidTvInstaller.isForeign(old))
        XCTAssertTrue(AndroidTvInstaller.signatureIsOurs(new))
    }

    func testOtherSignatureIsForeign() {
        XCTAssertTrue(AndroidTvInstaller.isForeign(dumpsys("PackageSignatures{a1b2c3 version:3, signatures:[7f00aa12], past signatures:[]}")))
        XCTAssertTrue(AndroidTvInstaller.isForeign(dumpsys("PackageSignatures{41ab21 [deadbeef]}")))
        XCTAssertFalse(AndroidTvInstaller.signatureIsOurs(dumpsys("PackageSignatures{41ab21 [deadbeef]}")))
    }

    func testUnknownSignatureOrMissingAppIsNotForeign() {
        XCTAssertFalse(AndroidTvInstaller.isForeign(dumpsys(nil)))
        XCTAssertFalse(AndroidTvInstaller.isForeign(dumpsys("PackageSignatures{a1b2c3 version:0, signatures:[], past signatures:[]}")))
        XCTAssertFalse(AndroidTvInstaller.isForeign(""))
        XCTAssertFalse(AndroidTvInstaller.signatureIsOurs(dumpsys(nil)))
    }

    // MARK: LG webOS (appinfo.json)

    func testLgAppInfo() {
        let ours = #"{"id": "com.couchsubs.tv", "version": "0.9.74", "vendor": "Enmera", "title": "CouchSubs"}"#
        XCTAssertFalse(LGInstaller.isForeignAppInfo(ours))
        XCTAssertTrue(LGInstaller.isForeignAppInfo(#"{"id": "com.couchsubs.tv", "version": "2.0.0", "vendor": "Enmera", "title": "Başka Uygulama"}"#))
        XCTAssertTrue(LGInstaller.isForeignAppInfo(#"{"id": "com.couchsubs.tv", "version": "1.0.0", "vendor": "Other Vendor", "title": "CouchSubs"}"#))
        // Alanlar yoksa ya da dosya okunamadıysa bizim sayılır.
        XCTAssertFalse(LGInstaller.isForeignAppInfo(#"{"id": "com.couchsubs.tv", "version": "0.9.74"}"#))
        XCTAssertFalse(LGInstaller.isForeignAppInfo("cat: can't open: No such file or directory"))
        XCTAssertEqual(LGInstaller.fieldFromAppInfo("\r\n" + ours + "\r\n", "title"), "CouchSubs")
    }

    // MARK: Samsung (vd_applist)

    private func applist(_ title: String?) -> String {
        var lines = ["\t-------------app_title  =  Other App----------------------------",
                     "\t-------------app_tizen_id  =  AbCdEf1234.Other-----------------",
                     "\t-------------app_version  =  1.2.0----------------------------",
                     "\t--------------------------------------------------------------"]
        if let title { lines.append("\t-------------app_title  =  \(title)----------------------------") }
        lines += ["\t-------------app_tizen_id  =  CouchSubsT.CouchSubs----------------",
                  "\t-------------app_version  =  0.9.74----------------------------",
                  "\t--------------------------------------------------------------"]
        return lines.joined(separator: "\n")
    }

    func testSamsungTitle() {
        XCTAssertEqual(SamsungDiagnostics.installedVersion(applist("CouchSubs")), "0.9.74")
        XCTAssertEqual(SamsungDiagnostics.installedTitle(applist("CouchSubs")), "CouchSubs")
        XCTAssertFalse(SamsungDiagnostics.isForeign(applist("CouchSubs")))
        XCTAssertTrue(SamsungDiagnostics.isForeign(applist("Başka Uygulama")))
        // Ad yoksa bizim sayılır; başka uygulamanın adı CouchSubs'ın bloğuna karışmaz.
        XCTAssertNil(SamsungDiagnostics.installedTitle(applist(nil)))
        XCTAssertFalse(SamsungDiagnostics.isForeign(applist(nil)))
        XCTAssertFalse(SamsungDiagnostics.isForeign(""))
    }
}
