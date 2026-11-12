// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Uygulamanın adı ve kimlikleri tek yerde.
public enum AppIdentity {
    public static let name = "CouchSubs"
    public static let tvAppId = "com.couchsubs.tv"
    public static let samsungAppId = "CouchSubsT.CouchSubs"
    public static let tvGuideURL = URL(string: "https://github.com/yorulmazsinan/couchsubs/blob/main/docs/tv-kurulum.md")!
    public static let sourceURL = URL(string: "https://github.com/yorulmazsinan/couchsubs")!
    public static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    public static let serverPort: UInt16 = 8787
}
