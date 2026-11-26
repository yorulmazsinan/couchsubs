// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Okuma hattının bir kareye vereceği tepki.
public enum StabilizerAction: Equatable {
    case none
    case translate(String)
    case clear
    /// Az önce kalkan satır geri geldi; çevirisi yeniden gösterilir, yeniden çevrilmez (metin: ilk gönderilen hali).
    case restore(String)
}

/// Satırın gönderilmeden bırakıldığı durumlar (yalnız altyazı günlüğü için; kararları değiştirmez).
public enum StabilizerNote: Equatable {
    /// Gönderilen satırın daha kötü (daha az sözcük okuyan) yeniden okuması; yeni satır sayılmadı.
    case worseReread(String)
    /// Çöp gibi okunan satır (`OcrNoise.looksGarbled`) yeterince kararlı kalmadan ekrandan kalktı ya da değişti; hiç gönderilmedi.
    case garbledDropped(String)
}

/// Kare kare gelen OCR çıktısını izler; altyazı kararlı hale gelince çevrilmesini,
/// ekrandan kalkınca TV'den temizlenmesini ister. Aynı altyazıyı tekrar göndermez.
/// Kararlar okuma hızına değil saate bağlıdır (`clock`: milisaniye; testlerde sahtesi verilir).
public struct SubtitleStabilizer {
    /// Bölge bu kadar boş kalırsa altyazı kalkmış sayılır; parlak arka planda kaçan birkaç okuma silmez.
    public static let clearAfterMs = 800
    /// Okuma boş döndüğü halde satırın yeri, satır son okunduğundan beri değişmediyse (bölge izi, `ReadScheduler.changed`)
    /// yazı hâlâ oradadır, yazı tanıma kaçırmıştır: parlak zeminde beyaz yazı saniyelerce okunamıyor, TV'deki Türkçe
    /// İngilizce dururken siliniyordu (It Takes Two, 2026-11-13). Satırın yeri değişince her zamanki `clearAfterMs`
    /// sayılır. Değişmeyen yerde de satır en çok bu kadar tutulur: küçültülmüş iz harfleri kaçırırsa kalkan satırın
    /// çevirisi en çok bu kadar fazla kalır.
    public static let holdUnchangedMs = 4000
    /// Kalkan satır bu süre içinde geri gelirse aynı satırdır (okuma kaçmıştı); yeniden çevrilmez.
    public static let restoreWithinMs = 1500
    /// Çevirisi başarısız olan satır en erken bu kadar sonra yeniden denenir.
    public static let retryAfterMs = 1000
    /// Çöp gibi okunan satır (`OcrNoise.looksGarbled`) ancak bu kadar süre aynı okununca gider. Altyazılar geçişte üst
    /// üste solarken yazı tanıma iki satırı karıştırıp birkaç kare aynı çöpü okuyabiliyordu ("- Nat) but, you knpw.
    /// shit, I m", GTA V, #26); süslü ama gerçekten öyle duran yazı yine çevrilir.
    public static let garbledStableMs = 700
    private static let historySize = 5

    /// Uygulamanın saati: açılıştan bu yana geçen milisaniye.
    public static func uptimeMs() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    private let similarity: Double
    private let stableFrames: Int
    private let clearAfterMs: Int
    private let now: () -> Int

    private var candidate = ""
    private var candidateCount = 0
    private var candidateSince = 0
    /// Ekrandaki (gönderilmiş) satır: sadeleştirilmiş satırlar alt alta, ve ilk okunduğu hali.
    private var sent = ""
    private var sentRaw = ""
    /// Yeniden deneme veya geri çekme sent durumunu temizlese de ekrandaki satırın temizlenmesi bekleniyor.
    private var clearPending = false
    private var emptySince: Int?
    /// Boş okunan bölgede satırın yerinin değiştiği (ya da yeri bilinmediği için kalkmış sayıldığı) an.
    private var goneSince: Int?
    /// Ekrandaki satırın son okunduğu karenin bölge izi ve satırın bölgedeki yeri.
    private var lastSeen: (signature: [UInt8], box: TextBox)?
    /// Son kalkan satırlar ve kalktıkları an.
    private var history: [(rows: String, raw: String, leftAt: Int)] = []
    /// Çevirisi başarısız olan satır ve en erken yeniden deneneceği an.
    private var forgotten = ""
    private var retryAt = 0
    /// Bekleyen (henüz gönderilmemiş) çöp gibi okunan aday; gönderilmeden kalkarsa günlüğe yazılır.
    private var garbledPending = ""
    /// Gönderilen satırın kaç kez aynı okunduğu ve gönderilenden farklı okunan, art arda gelen aynı okuma (düzeltme adayı).
    private var sentReads = 0
    private var correction: (text: String, raw: String, count: Int)?
    /// Şu anki adayın ilk okunduğu an (gecikme dökümü için; kararları değiştirmez).
    public var candidateStartedAt: Int { candidateSince }
    /// Son `feed` çağrısında bırakılan satır (günlük için); her çağrıda sıfırlanır.
    public private(set) var note: StabilizerNote?

    public init(similarity: Double = 0.85, stableFrames: Int = 2, clearAfterMs: Int = SubtitleStabilizer.clearAfterMs,
                clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        self.similarity = similarity
        self.stableFrames = stableFrames
        self.clearAfterMs = clearAfterMs
        self.now = clock
    }

    /// `signature`: karenin bölge izi (`RegionCropper.signature`); verilmezse boş okuma hep kalkma sayılır.
    /// `box`: okunan yazının bölgedeki yeri (bölgenin kenarlarına oranla).
    public mutating func feed(_ rawText: String, signature: [UInt8]? = nil, box: TextBox? = nil) -> StabilizerAction {
        let time = now()
        let text = TextMatch.normalize(rawText)
        note = nil
        // 3 karakterden kısa okumalar (gürültü, tek simge) boş kare sayılır.
        guard text.count >= 3 else {
            dropGarbled()
            candidate = ""
            candidateCount = 0
            let since = emptySince ?? time
            emptySince = since
            guard !sent.isEmpty || clearPending else { return .none }
            // Satırın yeri son okunduğu kareden beri değişmediyse yazı tanıma kaçırmıştır; kalkma sayılmaz.
            if goneSince == nil && !looksUnchanged(signature) { goneSince = time }
            let gone = goneSince.map { time - $0 >= clearAfterMs } ?? false
            if gone || time - since >= Self.holdUnchangedMs {
                leaveScreen(at: time)
                return .clear
            }
            return .none
        }

        emptySince = nil
        goneSince = nil
        if TextMatch.isSimilar(text, candidate, threshold: similarity) {
            candidateCount += 1
        } else {
            dropGarbled()
            candidate = text
            candidateCount = 1
            candidateSince = time
        }
        // Daktilo efektinde metin büyürken aday değişir; tamamlanıp kararlı olunca gider.
        // Noktalamayla biten satır zaten tamamdır; hızlı konuşmada beklemeden ilk karede gider. Çöp gibi okunan satır
        // (altyazılar geçişte üst üste solarken karışan okuma) beklemeden gitmez; geçiş süresinden uzun kararlıysa gider.
        let garbled = OcrNoise.looksGarbled(rawText)
        let ready = garbled
            ? candidateCount >= stableFrames && time - candidateSince >= Self.garbledStableMs
            : candidateCount >= stableFrames || Self.endsSentence(rawText)
        // Gönderilenin gürültülü yeniden okuması yeni satır değildir; TV'de aynı cümle iki kez görünmesin. Adlı gönderilen
        // satırın ("JASON: …") renkli adı bir karede okunamadıysa adsız okuması da aynı satırdır.
        if Self.isSame(text, sent) || Self.isUnnamedReread(rawText, of: sentRaw) {
            remember(signature, box)
            if let fixed = corrected(text, rawText) { return .translate(fixed) }
            return .none
        }
        guard ready else {
            if garbled { garbledPending = rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
            return .none
        }
        garbledPending = ""
        // Aynı cümlenin bir iki sözcüğü başka okunmuş, daha iyi olmayan okuması da yeni satır değildir; çevrilseydi TV'de
        // aynı cümlenin iki üç çevirisi üst üste dururdu. Daha çok sözcük okuyan okuma yeniden çevrilir (TV yerine koyar).
        if !sentRaw.isEmpty, TextMatch.isWorseReread(rawText, of: sentRaw) {
            note = .worseReread(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
            remember(signature, box)
            return .none
        }

        // Az önce kalkan satır geri geldiyse okuma birkaç kare kaçmıştır: çevirisi yeniden gösterilir, yeniden çevrilmez.
        if let index = history.lastIndex(where: { time - $0.leftAt <= Self.restoreWithinMs && Self.isSame(text, $0.rows) }) {
            let back = history.remove(at: index)
            leaveScreen(at: time)
            (sent, sentRaw) = (back.rows, back.raw)
            remember(signature, box)
            return .restore(back.raw)
        }
        // Çevirisi az önce başarısız olan satır her karede yeniden istenmez.
        if !forgotten.isEmpty && time < retryAt && Self.isSame(text, forgotten) { return .none }

        leaveScreen(at: time)
        forgotten = ""
        sentRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        sent = TextMatch.normalizeRows(sentRaw)
        sentReads = 1
        correction = nil
        remember(signature, box)
        return .translate(sentRaw)
    }

    /// Gönderilen satır ilk karesinde bir sözcüğü bozuk okunmuş olabilir: yazı belirirken (ya da renkli sözcük açık zeminde)
    /// "lives" "Ijz", "speedboat" "eedboat" okunuyor, satır noktalamayla bittiği için ilk karede gidiyordu. Sonraki
    /// okumalar aynı satır sayıldığından (`isSame`) doğrusu hiç çevrilmiyor, TV'de bozuk sözcüklü çeviri kalıyordu
    /// (GitHub #854, GTA 6). Gönderilenle aynı sayıda sözcüklü, ondan farklı bir okuma art arda en az `stableFrames` kez
    /// okunur, puanı da (`OcrNoise.score`: daha çok düzgün harf) yüksekse ve ya gönderilenden daha çok kez okunduysa ya da
    /// farklı sözcükleri gönderilenin onarılmış hali ise (`repairsWords`) düzeltmedir: yeniden çevrilir (hat onu
    /// gösterilenin yerine koyar). Düzeltilen satır bir daha düzeltilmez. Windows
    /// (SubtitleStabilizer.cs) ve Android (SubtitleStabilizer.kt) aynı kuralı uygular.
    private mutating func corrected(_ text: String, _ rawText: String) -> String? {
        guard sentReads > 0 else { return nil }
        let shown = TextMatch.normalize(sentRaw)
        if text == shown {
            sentReads += 1
            return nil
        }
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = correction, current.text == text {
            correction = (text, raw, current.count + 1)
        } else {
            correction = (text, raw, 1)
        }
        let words = text.split(separator: " ").map(String.init), old = shown.split(separator: " ").map(String.init)
        guard let candidate = correction, candidate.count >= stableFrames, words.count == old.count,
              OcrNoise.score(candidate.raw) > OcrNoise.score(sentRaw),
              candidate.count > sentReads || Self.repairsWords(words, old) else { return nil }
        sentRaw = candidate.raw
        sent = TextMatch.normalizeRows(sentRaw)
        // Düzeltme kesindir: aynı satır bir daha düzeltilmez (iki okuma arasında gidip gelmesin).
        sentReads = 0
        correction = nil
        return sentRaw
    }

    /// Okumanın gönderilenden farklı her sözcüğü onun onarılmış hali mi: gönderilendeki sözcük ya sözcük değil
    /// (`OcrNoise.isNonWord`: "ijz") ya da yenisinin baştan/sondan kesilmiş parçası ("eedboat" → "speedboat").
    static func repairsWords(_ words: [String], _ old: [String]) -> Bool {
        var changed = false
        for (new, previous) in zip(words, old) where new != previous {
            changed = true
            let fragment = new.count > previous.count && (new.hasSuffix(previous) || new.hasPrefix(previous))
            guard fragment || (OcrNoise.isNonWord(previous) && !OcrNoise.isNonWord(new)) else { return false }
        }
        return changed
    }

    /// Ekrandaki satır bu karede okundu: bölgenin izi ve satırın yeri saklanır (yer bilinmiyorsa hiçbiri).
    private mutating func remember(_ signature: [UInt8]?, _ box: TextBox?) {
        if let signature, let box { lastSeen = (signature, box) } else { lastSeen = nil }
    }

    /// Bu karede satırın yeri, satırın son okunduğu karedekiyle aynı mı (izi ve yeri bilinmiyorsa hayır).
    private func looksUnchanged(_ signature: [UInt8]?) -> Bool {
        guard let signature, let seen = lastSeen else { return false }
        return !ReadScheduler.changed(seen.signature, signature, threshold: ReadScheduler.defaultChangeThreshold, within: seen.box)
    }

    /// Bekleyen çöp aday gönderilmeden bırakıldı (kalktı ya da başka okumaya döndü): günlük için not edilir.
    private mutating func dropGarbled() {
        guard !garbledPending.isEmpty else { return }
        note = .garbledDropped(garbledPending)
        garbledPending = ""
    }

    /// Okuma, bu satırların (gürültülü) yeniden okuması mı; sonuna sözcük eklenmiş hali yenidir.
    private static func isSame(_ text: String, _ rows: String) -> Bool {
        !rows.isEmpty && TextMatch.isSameSubtitle(text, rows)
    }

    /// Okuma, adlı gönderilen satırın ("JASON: Gidelim.") adı okunamamış hali mi ("Gidelim."). Ad sonradan okunan satırın
    /// tersi (bkz. `SubtitlePipeline.nameRead`): ad bir görünüp bir kaybolunca cümle yeniden çevrilip TV'de adsız ve adlı
    /// iki kez görünmesin (Windows: IsUnnamedReread, Android: isUnnamedReread).
    static func isUnnamedReread(_ raw: String, of sentRaw: String) -> Bool {
        guard !sentRaw.isEmpty, SpeakerPrefix.split(raw) == nil, let named = SpeakerPrefix.split(sentRaw) else { return false }
        return isSame(TextMatch.normalize(raw), TextMatch.normalizeRows(named.body))
    }

    /// Ekrandaki satırı geçmişe yazar (kalktı ya da yerine başkası geldi).
    private mutating func leaveScreen(at time: Int) {
        if !sent.isEmpty {
            history.append((sent, sentRaw, time))
            if history.count > Self.historySize { history.removeFirst() }
            sent = ""
            sentRaw = ""
        }
        sentReads = 0
        correction = nil
        lastSeen = nil
        clearPending = false
    }

    /// Satır nokta, ünlem, soru ya da üç noktayla bitiyor mu (kapanan tırnak ve parantezler yok sayılır).
    static func endsSentence(_ raw: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]"]
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, closers.contains(last) { text.removeLast() }
        guard let last = text.last else { return false }
        return ".!?…".contains(last)
    }

    /// Çeviri kaynağıyla neredeyse aynıysa metin zaten hedef dildedir (ör. konsolun Türkçe menüleri).
    public mutating func shouldSend(source: String, translation: String) -> Bool {
        !TextMatch.isSimilar(TextMatch.normalize(source), TextMatch.normalize(translation), threshold: 0.90)
    }

    /// Az önce çevrilmek üzere verilen satırı hat yok saydı (bekleyen satırın arasına giren bozuk okuma): satır gönderilmemiş
    /// sayılır, ekranda kaldıkça sonraki okumada yeniden verilir. Yoksa gerçek bir yeni satır "gönderildi" sayılıp hiç
    /// çevrilmiyordu (Windows: WithdrawSent, Android: withdrawSent).
    public mutating func withdrawSent() {
        if !sent.isEmpty { clearPending = true }
        sent = ""
        sentRaw = ""
        if !clearPending { lastSeen = nil }
    }

    /// Son gönderilen satırı unutur (ör. çevirisi başarısız oldu); satır ekranda kaldıkça yeniden kararlı sayılıp çevrilir,
    /// ama en erken `retryAfterMs` sonra: kalıcı hatada (dil paketi eksik) her karede çevirmene gidilmez.
    public mutating func forgetSent() {
        if !sent.isEmpty {
            forgotten = sent
            clearPending = true
        }
        retryAt = now() + Self.retryAfterMs
        sent = ""
        sentRaw = ""
        if !clearPending { lastSeen = nil }
        candidate = ""
        candidateCount = 0
        garbledPending = ""
    }

    public mutating func reset() -> StabilizerAction {
        candidate = ""
        candidateCount = 0
        garbledPending = ""
        note = nil
        emptySince = nil
        goneSince = nil
        lastSeen = nil
        history.removeAll()
        forgotten = ""
        let shouldClear = !sent.isEmpty || clearPending
        sent = ""
        sentRaw = ""
        sentReads = 0
        correction = nil
        clearPending = false
        return shouldClear ? .clear : .none
    }
}
