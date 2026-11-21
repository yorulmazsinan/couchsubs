// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation

/// testdata/frames/frames.json: her karenin elle konmuş beklenen sonucu.
struct Manifest: Decodable {
    var frames: [Frame]
    /// Telefon çevirisi senaryoları (#801/#822): telefon karesi, telefonun doğrulanamadığı kare, yine telefon karesi.
    var phoneScenarios: [PhoneScenario] = []
    /// Konuşan adı sonradan okunan diyalog senaryoları (X: "çift altyazı").
    var speakerScenarios: [SpeakerScenario] = []

    enum CodingKeys: String, CodingKey { case frames, phoneScenarios, speakerScenarios }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frames = try container.decode([Frame].self, forKey: .frames)
        phoneScenarios = try container.decodeIfPresent([PhoneScenario].self, forKey: .phoneScenarios) ?? []
        speakerScenarios = try container.decodeIfPresent([SpeakerScenario].self, forKey: .speakerScenarios) ?? []
    }

    static func load(_ directory: URL) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("frames.json")))
    }
}

struct Frame: Decodable {
    var id: String
    var file: String
    var source: String
    var game: String
    /// Aynı oturumda (aynı hatla, sırayla) okunan kareler; yoksa kare kendi oturumundadır.
    var session: String?
    /// Altyazı alanı [sol, üst, sağ, alt], kareye oranla; yoksa uygulamanın varsayılanı.
    var region: [Double]?
    /// Okunması gereken altyazı (konuşan adı dahil); nil: bu karede altyazı yok, hiçbir şey gönderilmemeli.
    var subtitle: String?
    /// Altyazının karedeki yeri [sol, üst, sağ, alt]; çizim kutusu bunu örtmeli.
    var subtitleBox: [Double]?
    /// Altyazı sayılmaması gereken sahne yazıları (tabela, tişört, afiş).
    var signs: [String]?
    /// Karede GTA 6 telefonu: "chat" (mesajlaşma), "home" (ana ekran), "list" (kişi/sohbet listesi); nil: telefon yok.
    var phone: String?
    /// Haritada görev kartı var mı.
    var mapCard: Bool?
    /// Ekran yazısı denetimi (menü, görev listesi; `ScreenExpectation`).
    var screen: ScreenExpectation?

    var cropRegion: CropRegion {
        guard let region, region.count == 4 else { return CropRegion() }
        return CropRegion(top: region[1], bottom: region[3], left: region[0], right: region[2])
    }
}

struct PhoneScenario: Decodable {
    var name: String
    /// Telefonun açık olduğu kare.
    var phone: String
    /// Telefonun doğrulanamadığı kare (kare geçişi, el titremesi).
    var gone: String
}

/// Diyalog satırının renkli konuşan adı ilk karelerde okunmuyor (ad örtülmüş kare), sonra okunuyor: aynı cümle yeniden
/// çevrilmemeli, TV'de adsız ve adlı iki satır olarak görünmemeli; ad ekrandaki satıra eklenmeli (yerine geçerek).
struct SpeakerScenario: Decodable {
    var name: String
    /// Adlı altyazılı kare (`frames` içindeki id).
    var frame: String
    /// Konuşan adının karedeki yeri [sol, üst, sağ, alt]; ilk karelerde bu alan çevresinin rengiyle örtülür.
    var nameBox: [Double]
}

func box(_ values: [Double]?) -> TextBox? {
    guard let values, values.count == 4 else { return nil }
    return TextBox(left: values[0], top: values[1], right: values[2], bottom: values[3])
}
