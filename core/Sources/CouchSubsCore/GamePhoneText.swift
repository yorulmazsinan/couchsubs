// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum GamePhoneText {
    private static let identifier = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])[@#][\p{L}\p{N}_]+(?:[.-][\p{L}\p{N}_]+)*"#)
    private static let chatWord = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_@#.-])(?:2gether|4u)(?![\p{L}\p{N}_])"#)
    private static let misreadTen = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_@#])(?:IO|I0|lO|l0)(?=\s+min(?:s|utes?)?\b)"#)

    /// Aynı uzun mesajda yan yana iki kısa sözcükte birer harf oynamış ("it out" → "ct ocut"): yazı tanıma sapması, yeni
    /// mesaj değil. Tek sözcüklü seçenekler, eklenen/silinen sözcükler, sayılar ve olumsuzluklar doğrudan işlenir (Windows ile aynı).
    static func hasAdjacentOcrEdits(_ shown: String, _ next: String) -> Bool {
        let before = TextMatch.normalize(shown).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let after = TextMatch.normalize(next).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard before.count >= 9, before.count == after.count else { return false }
        var first = 0, last = before.count - 1
        while first <= last && before[first] == after[first] { first += 1 }
        while last > first && before[last] == after[last] { last -= 1 }
        guard last == first + 1 else { return false }
        for i in first...last {
            let a = before[i], b = after[i]
            let length = max(a.count, b.count)
            guard min(a.count, b.count) >= 2, length <= 6, a.allSatisfy(\.isLetter), b.allSatisfy(\.isLetter),
                  TextMatch.isSimilar(a, b, threshold: 1.0 - 1.0 / Double(length)) else { return false }
        }
        return !TextMatch.addsMeaning(next, to: shown) && !TextMatch.addsMeaning(shown, to: next)
    }

    static func containsIdentifier(_ text: String) -> Bool {
        (text.contains("@") || text.contains("#")) && identifier.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isWrittenChatWord(_ token: String) -> Bool {
        (token.contains("2") || token.contains("4")) && chatWord.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
    }

    static func englishModelInput(_ text: String) -> String {
        var value = text
        if text.contains("min") {
            value = misreadTen.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "10")
        }
        guard isWrittenChatWord(value) else { return value }
        let out = NSMutableString(string: value)
        for match in chatWord.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            out.replaceCharacters(in: match.range, with: out.substring(with: match.range) == "2gether" ? "together" : "for you")
        }
        return out as String
    }

    static func keepIdentifiers(_ source: String, translation: String?) -> String? {
        guard let translation, !translation.isEmpty, containsIdentifier(source) else { return translation }
        let original = source as NSString
        var names = identifier.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { original.substring(with: $0.range) }
        let result = NSMutableString(string: translation)
        for match in identifier.matches(in: translation, range: NSRange(translation.startIndex..., in: translation)).reversed() {
            let name = result.substring(with: match.range)
            guard let index = names.lastIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
            result.replaceCharacters(in: match.range, with: names.remove(at: index))
        }
        return names.isEmpty ? result as String : nil
    }

    private static func isTag(_ token: Substring) -> Bool {
        guard token.first == "@" || token.first == "#" else { return false }
        let value = String(token), range = NSRange(value.startIndex..., in: value)
        return identifier.firstMatch(in: value, range: range)?.range == range
    }

    private static let headings = ["Messages", "Suggested", "Suggestions", "Öneriler", "Mesajlar"]

    /// Sohbet listesinin bölüm başlığı ("Suggested", "Messages"); değilse nil. Başlığın yanındaki simge yazı tanımada tek
    /// harf ya da işaret olarak okunur ("g Suggested", "✱ Suggested", "Messages ☆"): o artık atılır. Önceden "g Suggested"
    /// başlık sayılmıyor, sallanan telefonda liste her okumada bir liste bir sohbet çiziliyor, TV'de "g Önerilen" yazıyordu.
    /// Simge artığı `ButtonIcons.isIconToken` ile aynı tanımdadır (tek harf ya da işaret; ekran yazısı #1228 ile aynı).
    static func section(_ text: String) -> String? {
        let value = String(text.drop(while: { !$0.isLetter }).reversed().drop(while: { !$0.isLetter }).reversed())
        if headings.contains(value) { return value }
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (2...3).contains(words.count), let heading = words.first(where: headings.contains) else { return nil }
        let rest = words.filter { $0 != heading }
        guard rest.count == words.count - 1,
              rest.allSatisfy({ $0.count == 1 || ButtonIcons.isIconToken($0) || !$0.contains(where: \.isLetter) }) else { return nil }
        return heading
    }

    /// Grup sohbetinin adı virgüllüdür ("Papa Audacity, Jaso", "Yasmani, Jason, Luc"): ad sayılmayınca önizleme sanılıyor, liste kartı ad ve önizleme diye ikiye bölünüyordu (X, 28 Kas, beta.108). Windows ve Android ile aynı.
    /// Seçili satırın çerçevesi adın başını kesebilir ("smani, Jason, Lucia"): ilk sözcük küçük harfle başlasa da grup adıdır.
    private static func looksLikeGroupName(_ text: String) -> Bool {
        let label = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard text.contains(","), let first = label.first else { return false }
        return looksLikeName(first.uppercased() + label.dropFirst())
    }

    private static func looksLikeName(_ text: String) -> Bool {
        let label = String(text.prefix(while: { $0 != "(" })).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = label.split(separator: " ")
        guard section(label) == nil, (1...4).contains(words.count), words[0].first?.isUppercase == true else { return false }
        return words.allSatisfy { word in
            (word.first?.isUppercase == true || ["de","du","of"].contains(String(word))) &&
            word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" }
        }
    }

    static func isMessagePreview(_ text: String) -> Bool {
        text.contains(where: \.isWhitespace) && section(text) == nil && !looksLikeName(text)
    }

    private static func layout(_ line: TextLine) -> TextBox? { line.phoneBox ?? line.box }

    private static func isContactPair(_ name: TextLine, _ preview: TextLine) -> Bool {
        let label = name.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerName = (2...18).contains(label.count) && label.allSatisfy(\.isLowercase)
        guard looksLikeName(label) || looksLikeGroupName(label) || lowerName, let a = layout(name), let b = layout(preview) else {
            return false
        }
        let h = a.bottom - a.top
        return a.left > 0.1 && a.left < 0.48 && abs(a.left - b.left) <= 0.06 &&
            b.top > a.top && b.top - a.bottom < h * 0.7 && b.bottom - b.top < h * 1.8
    }

    private static func previewPunctuation(_ line: TextLine) -> TextLine {
        guard let box = layout(line), box.right >= 0.76 else { return line }
        let tail = line.text.reversed().prefix { ".,„".contains($0) }
        let stem = line.text.dropLast(tail.count)
        // "there ..", "there ...", "there..." tek yazımla: "there..." (son sözcük tamamlanmaz).
        guard (2...3).contains(tail.count), tail.last == "." else { return line }
        let word = stem.reversed().drop(while: \.isWhitespace).reversed()
        guard word.last?.isLetter == true else { return line }
        if word.count == stem.count && line.text.hasSuffix("...") { return line }
        var copy = line
        copy.text = String(word) + "..."
        return copy
    }

    /// Çeviriye gidecek satırlar. Sohbet listesi (Mesajlar ekranı: "Suggested", "Messages", kişi adı ve altında son mesajın
    /// önizlemesi) tanınırsa her satır rolüyle işaretlenir (`TextLine.listRole`): kişi adı (çevrilmez, kalın), önizleme
    /// (altında, çevrilir), bölüm başlığı. Liste için kişi adı sütununda en az üç "ad + önizleme" çifti ve bir bölüm başlığı
    /// (ya da başlık okunamadıysa "…" ile kesilmiş en az iki önizleme) gerekir. Önceden iki başlığın ikisi de okunmalıydı:
    /// sallanan telefonda biri her okumada kaçıyor, liste bir sohbet balonları bir düz satırlar olarak gidip geliyordu
    /// (LG, beta.93). Kişi adları da atılıyordu; şimdi listede adıyla görünür (Windows ve Android ile aynı).
    ///
    /// Liste değilse ve ekran sohbet dışıysa (`PhoneScreen.kind`: gönderi, haber, makale, hava, fitness, ayarlar,
    /// eklenti) satırlar kartlarına ayrılır (`TextLine.phoneCard`); çevrilmeyen satırlar (kullanıcı adı, saat, geri
    /// düğmesi, konum, fotoğraf yazısı, kaynak adı) atılır. Ana ekran kendi kurallarında kalır (`PhoneChat.isHomeScreen`).
    static func forTranslation(_ reading: Reading) -> Reading {
        let list = listed(reading)
        if list.lines.contains(where: { $0.listRole != nil }) || PhoneChat.isHomeScreen(list.lines) { return list }
        return screen(reading) ?? list
    }

    /// Sohbet dışı ekranın kartları (`PhoneScreen.cards`); ekran sohbetse ya da satırların düz yeri bilinmiyorsa nil.
    static func screen(_ reading: Reading) -> Reading? {
        let all = reading.lines.filter { $0.phoneBox != nil }
        guard !all.isEmpty else { return nil }
        let lines = all.map { PhoneScreen.Line(text: $0.text, spot: $0.phoneBox!) }
        let kind = PhoneScreen.kind(lines)
        guard kind != .chat else { return nil }
        var result: [TextLine] = []
        for (number, card) in PhoneScreen.cards(lines, kind: kind).enumerated() {
            for (position, index) in card.lines.enumerated() {
                var line = all[index]
                line.listRole = .card
                line.phoneCard = PhoneScreen.Mark(card: number, title: card.titled && position == 0, bold: card.bold)
                result.append(line)
            }
        }
        return Reading(lines: result)
    }

    private static func listed(_ reading: Reading) -> Reading {
        var lines = reading.lines.filter { line in
            let words = line.text.split(whereSeparator: \.isWhitespace)
            return !(words.contains(where: isTag) && words.allSatisfy { isTag($0) || !$0.contains(where: { $0.isLetter || $0.isNumber }) })
        }
        for i in lines.indices { if let heading = section(lines[i].text) { lines[i].text = heading } }
        let headed = lines.contains { section($0.text) != nil }
        let order = lines.indices.filter { layout(lines[$0]) != nil }.sorted { layout(lines[$0])!.top < layout(lines[$1])!.top }
        var names: [Int] = [], previews: Set<Int> = []
        var i = 0
        while i + 1 < order.count {
            let name = order[i], preview = order[i + 1]
            if lines[preview].text.trimmingCharacters(in: .whitespacesAndNewlines).contains(" "),
               isContactPair(lines[name], lines[preview]) {
                names.append(name)
                previews.insert(preview)
                i += 2
            } else { i += 1 }
        }
        guard names.count >= 3, let first = layout(lines[names[0]]), let last = layout(lines[names[names.count - 1]]),
              last.top > first.top else { return Reading(lines: lines) }
        guard headed || previews.filter({ isCut(lines[$0].text) }).count >= 2 else { return Reading(lines: lines) }
        let slope = (last.left - first.left) / (last.top - first.top)
        func inColumn(_ line: TextLine) -> Bool {
            guard let box = layout(line) else { return false }
            return abs(box.left - (first.left + slope * (box.top - first.top))) <= 0.06
        }
        guard names.allSatisfy({ inColumn(lines[$0]) }) else { return Reading(lines: lines) }
        // Listeyi uzun önizlemeler doğruladı: aynı satır düzenindeki "Okay" gibi tek sözcüklük yanıt, kişi adına benziyor
        // diye ad sayılmaz; önizlemesi olarak kalır (Windows ile aynı).
        var k = 0
        while k + 1 < order.count {
            let name = order[k], preview = order[k + 1]
            let text = lines[preview].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inColumn(lines[name]), !previews.contains(name), !names.contains(preview), !text.contains(" "),
               looksLikeName(lines[preview].text), isContactPair(lines[name], lines[preview]) {
                names.append(name)
                previews.insert(preview)
                k += 2
            } else { k += 1 }
        }
        return Reading(lines: lines.indices.map { index in
            var line = lines[index]
            if previews.contains(index) {
                line = previewPunctuation(line)
                line.listRole = .preview
            } else if section(line.text) != nil {
                line.listRole = .heading
            } else if inColumn(line) && (names.contains(index) || looksLikeName(line.text) || looksLikeGroupName(line.text)) {
                line.listRole = .contact
            } else {
                line.listRole = .preview
            }
            return line
        })
    }

    /// Telefonun "…" ile kestiği önizleme ("Hey this is Joey from Coa...").
    static func isCut(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasSuffix("...") || value.hasSuffix("…")
    }

    private static let danglingWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "from", "with", "by", "about", "and", "but", "or", "so",
        "than", "my", "your", "his", "her", "its", "our", "their", "this", "that", "is", "are", "was", "were", "be", "i",
        "you", "we", "they", "it", "if", "as",
    ]

    /// Kesik önizlemenin çevrilecek kısmı: telefon son sözcüğü yarıda keser ("Coa...", "in t..."), yazı tanıma da üç
    /// noktanın önündeki boşluğu güvenilir okumaz; son sözcük her zaman atılır, ardından kalan bağlaç/edat ("from", "in",
    /// "than") da. Çeviri "..." ile biter (`cutTranslation`): önceden "Hey this is Joey from Coa..." "Selam, ben
    /// Coa'dan Joey..." çevriliyor, yarım sözcük uyduruluyordu. Kesik değilse ya da geriye bir sözcük bile kalmazsa nil.
    static func cutInput(_ text: String) -> String? {
        guard isCut(text) else { return nil }
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, last == "." || last == "…" { value.removeLast() }
        var words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return nil }
        words.removeLast()
        while words.count > 1, let last = words.last,
              danglingWords.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) { words.removeLast() }
        var core = words.joined(separator: " ")
        while let last = core.last, ",;:-–—".contains(last) { core.removeLast() }
        core = core.trimmingCharacters(in: .whitespaces)
        return core.contains(where: \.isLetter) ? core : nil
    }

    /// Önizleme satırın sağ kenarına bu kadar yakınsa (düz ekranda) ve cümle sonu yoksa telefon onu "…" koymadan kesmiştir
    /// ("$ in your mailbox. You bailed": aslı "...You bailed me out again bro!").
    static let clipEdge = 0.88

    /// "…" olmadan kesilmiş önizlemenin çevrilecek kısmı: sözcükler kalır (son sözcük tam görünüyor), sondaki bağlaç/edat
    /// atılır. Sinan Bey (beta.100, 3399): "$ in your mailbox. You bailed" bağlamsız çevrilip "Posta kutunda. Beni aradın"
    /// oluyordu. Cümle sonuyla biten ya da tek sözcüklük önizleme kesik sayılmaz (nil).
    static func clippedInput(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = value.last, !".!?…\"')".contains(last) else { return nil }
        var words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return nil }
        while words.count > 1, let last = words.last,
              danglingWords.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) { words.removeLast() }
        var core = words.joined(separator: " ")
        while let last = core.last, ",;:-–—".contains(last) { core.removeLast() }
        core = core.trimmingCharacters(in: .whitespaces)
        return core.contains(where: \.isLetter) ? core : nil
    }

    /// Kesik önizlemenin motora giden hâli: sonuna "..." eklenir; motor metnin kesik olduğunu görür, sonunu tamamlamaz.
    static func cutHint(_ core: String) -> String { core + "..." }

    /// Kaynağın başındaki para simgesi ("$ in your mailbox") çeviride düştüyse başa geri konur.
    static func keepingLeadingSymbol(_ source: String, _ translation: String) -> String {
        guard let first = source.trimmingCharacters(in: .whitespaces).unicodeScalars.first,
              first.properties.generalCategory == .currencySymbol,
              !translation.unicodeScalars.contains(first) else { return translation }
        let symbol = String(first)
        let glued = source.trimmingCharacters(in: .whitespaces).dropFirst().first?.isWhitespace == false
        return symbol + (glued ? "" : " ") + translation.trimmingCharacters(in: .whitespaces)
    }

    /// Sohbetten tam çevirisi bilinen mesajın kesik önizlemesi: önizlemenin (kesik ya da "…"sız kesilmiş) sadeleştirilmiş
    /// hâliyle başlayan bilinen en kısa mesajın çevirisinin aynı oranda başı + "...". Uydurma değil, sohbette gösterilen
    /// çevirinin kendisidir. Önizleme en az `previewLetters` harf olmalı; bulunmazsa nil.
    static let previewLetters = 8
    static func knownPreview(_ preview: String, in known: [String: String]) -> String? {
        var core = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = core.last, last == "." || last == "…" { core.removeLast() }
        let words = TextMatch.normalize(core).split(separator: " ")
        // "…" ile kesilen önizlemenin son sözcüğü yarımdır ("Coa"): eşleşmeye girmez.
        let head = (isCut(preview) && words.count > 1 ? words.dropLast() : words[...]).joined(separator: " ")
        guard head.filter(\.isLetter).count >= previewLetters else { return nil }
        let candidates = known.filter { key, _ in
            let full = TextMatch.normalize(key)
            return full.count > head.count + 2 && (full.hasPrefix(head + " ") || full.hasPrefix(head))
        }
        guard let best = candidates.min(by: { a, b in
            a.key.count != b.key.count ? a.key.count < b.key.count : a.key < b.key
        }) else { return nil }
        let ratio = Double(head.count) / Double(max(1, TextMatch.normalize(best.key).count))
        let target = Int((Double(best.value.count) * ratio).rounded(.up))
        var taken: [Substring] = [], length = 0
        for word in best.value.split(whereSeparator: \.isWhitespace) {
            if !taken.isEmpty, length + 1 + word.count > target + 2 { break }
            length += (taken.isEmpty ? 0 : 1) + word.count
            taken.append(word)
        }
        guard taken.count < best.value.split(whereSeparator: \.isWhitespace).count else { return nil }
        return cutTranslation(taken.joined(separator: " "))
    }

    /// Kesik önizlemenin çevirisi: sondaki noktalama atılıp "..." eklenir (telefondaki gibi kesik görünür).
    static func cutTranslation(_ translation: String) -> String {
        var value = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, ".,;:…–—-".contains(last) { value.removeLast() }
        return value.trimmingCharacters(in: .whitespaces) + "..."
    }

    /// Telefon ekranının blokları, kendi yerlerinde. Ana ekranda uygulama adları (WhatUp, simge etiketleri) çevrilmez
    /// (`PhoneChat.withoutAppNames`); saat ve hava harfsiz satır olarak zaten atılır.
    static func groups(_ reading: Reading) -> [ScreenTranslation.Group] {
        if reading.lines.contains(where: { $0.phoneCard != nil }) { return cardGroups(reading) }
        let home = PhoneChat.isHomeScreen(reading.lines)
        let reading = Reading(lines: PhoneChat.withoutAppNames(reading.lines))
        let flat = reading.lines.allSatisfy { $0.phoneBox != nil }
        // Sohbet listesi (`forTranslation`): her satır kendi satırıdır (ad ve altındaki önizleme ayrı), rolü okumadan gelir.
        let listed = reading.lines.contains { $0.listRole != nil }
        func box(_ line: TextLine) -> TextBox { (flat ? line.phoneBox : line.box)! }
        var groups: [ScreenTranslation.Group] = [], run: [TextLine] = []
        func finish() {
            guard !run.isEmpty else { return }
            defer { run.removeAll(keepingCapacity: true) }
            if !flat {
                groups += ScreenTranslation.groups(Reading(lines: run), keepIdentifiers: true)
                return
            }
            let clean = withoutRepeatedLines(Reading(lines: run).withButtonIcons().withoutButtonPrompts()
                .withoutOcrNoise(keepIdentifiers: true).lines.filter { $0.box != nil && ScreenTranslation.isWords($0.text) })
            guard let first = clean.first?.box else { return }
            let place = clean.dropFirst().reduce(first) { $0.union($1.box!) }
            let heights = run.map { box($0).bottom - box($0).top }.sorted()
            let icons = clean.flatMap { $0.icons ?? [] }
            var group = ScreenTranslation.Group(paragraphs: [withoutRepeat(clean.map(\.text).joined(separator: " "))], box: place,
                                                lineHeight: heights[heights.count / 2], icons: icons.isEmpty ? nil : [icons])
            // Düz ekrandaki yeri: sohbet panelinde tarafı (sol/sağ) ve sırası bundan çıkar (`roles`).
            let spots = run.map(box)
            group.phone = ScreenPhoneCard.Placement(role: listed ? run[0].listRole ?? .preview : .message,
                                                    spot: spots.dropFirst().reduce(spots[0]) { $0.union($1) })
            groups.append(group)
        }
        for line in reading.lines.filter({ $0.box != nil }).sorted(by: { box($0).top < box($1).top }) {
            if let previous = run.last,
               listed || breaksBlock(box(previous), box(line),
                                     gapShare: flat && !home ? PhoneChat.bubbleGap : flat && endsSentence(previous.text) ? 0.65 : 1) {
                finish()
            }
            run.append(line)
        }
        finish()
        let kept = Array(groups.prefix(ScreenTranslation.maxGroups))
        if listed, flat, !kept.isEmpty { return kept }
        let placed = roles(kept, home: home)
        return home ? widgets(placed) : placed
    }

    /// Sohbet dışı ekranın kartları (`forTranslation` işaretledi): her kart bir grup, telefondaki sırasıyla. Başlıklı
    /// kartın başlığı ayrı paragraf (kalın çizilir), gövdesi tek paragraf; alt satıra sarılmış cümle birleşir (tireyle
    /// bölünmüş sözcük boşluksuz). Grubun rolü `card`, düz ekrandaki yeri kartın satırlarının birleşimi.
    static func cardGroups(_ reading: Reading) -> [ScreenTranslation.Group] {
        let marked = reading.lines.filter { $0.phoneCard != nil && $0.box != nil && $0.phoneBox != nil }
        let numbers = Array(Set(marked.map { $0.phoneCard!.card })).sorted()
        var groups: [ScreenTranslation.Group] = []
        for number in numbers {
            let run = marked.filter { $0.phoneCard!.card == number }
            let clean = Reading(lines: run).withoutOcrNoise(keepIdentifiers: true).lines
                .filter { $0.box != nil && $0.phoneBox != nil && ScreenTranslation.isWords($0.text) }
            guard !clean.isEmpty else { continue }
            let mark = run[0].phoneCard!
            let titled = clean.count >= 2 && clean[0].phoneCard?.title == true
            func joined(_ lines: ArraySlice<TextLine>) -> String {
                var text = ""
                for line in lines {
                    let part = line.text.trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { text = part } else if text.hasSuffix("-") { text += part } else { text += " " + part }
                }
                return text
            }
            let paragraphs = titled ? [clean[0].text.trimmingCharacters(in: .whitespaces), joined(clean.dropFirst())]
                : [joined(clean[...])]
            let boxes = clean.map { $0.box! }, spots = clean.map { $0.phoneBox! }
            let heights = spots.map { $0.bottom - $0.top }.sorted()
            var group = ScreenTranslation.Group(paragraphs: paragraphs, box: boxes.dropFirst().reduce(boxes[0]) { $0.union($1) },
                                                lineHeight: heights[(heights.count - 1) / 2])
            group.phone = ScreenPhoneCard.Placement(role: .card, spot: spots.dropFirst().reduce(spots[0]) { $0.union($1) },
                                                    titled: titled, bold: mark.bold)
            groups.append(group)
        }
        return Array(groups.prefix(ScreenTranslation.maxGroups))
    }

    /// Ana ekranda bileşen başlığı ve hemen altındaki sayaç ("Reminders" / "6 Notifications") tek grup olur: panelde tek
    /// kart (`ScreenPhoneCard.Role.widget`; "Ekranı çevir"de `PhoneChat.isWidget`). Başlığın solunda simge olduğundan
    /// ikisi ayrı blok okunuyordu ve bileşen çevrilmiyordu (Sinan Bey, beta.100 3397).
    /// "Reminders 10 Notifications": bir-üç sözcüklük harfli başlık ve ardından sayaç; değilse nil.
    static func widgetParts(_ text: String) -> (title: String, counter: String)? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for count in 1...3 where count < words.count {
            let title = words[..<count].joined(separator: " "), counter = words[count...].joined(separator: " ")
            if PhoneChat.isCounter(counter), !title.contains(where: \.isNumber), title.contains(where: \.isLetter) {
                return (title, counter)
            }
        }
        return nil
    }

    static func widgets(_ groups: [ScreenTranslation.Group]) -> [ScreenTranslation.Group] {
        var result: [ScreenTranslation.Group] = []
        for group in groups {
            let text = group.paragraphs.joined(separator: " ")
            // Başlık ve sayaç tek satır grubu okunduysa ("Reminders 10 Notifications") ikiye ayrılır.
            if group.phone?.role == .home, group.paragraphs.count == 1, let split = widgetParts(text) {
                var widget = group
                widget.paragraphs = [split.title, split.counter]
                widget.icons = nil
                widget.phone = ScreenPhoneCard.Placement(role: .widget, spot: group.phone!.spot)
                result.append(widget)
                continue
            }
            if PhoneChat.isCounter(text), let spot = group.phone?.spot, let last = result.last, let above = last.phone?.spot,
               last.phone?.role == .home, last.paragraphs.count == 1, !PhoneChat.isCounter(last.paragraphs[0]),
               (1...3).contains(last.paragraphs[0].split(whereSeparator: \.isWhitespace).count),
               spot.top >= above.top, spot.top - above.bottom < (above.bottom - above.top) * PhoneChat.homeGap,
               spot.left <= above.left + PhoneChat.leftAlign, above.left - spot.left <= PhoneChat.widgetIndent {
                var widget = last
                widget.paragraphs = [last.paragraphs[0], text]
                widget.box = last.box.union(group.box)
                widget.phone = ScreenPhoneCard.Placement(role: .widget, spot: above.union(spot))
                result[result.count - 1] = widget
                continue
            }
            result.append(group)
        }
        return result
    }

    /// Sohbet panelinde her grubun rolü ("Ekranı çevir"in `PhoneChat` kuralları, düz ekrandaki yerinden): en üstteki
    /// kısa ad satırı kişinin adıdır (çevrilmez), ortalı kısa satır not, sağa yaslı balon oyuncunun, sola yaslı karşı
    /// tarafın mesajı; iki yanı da dar balonun tarafını panel rengiyle seçer. Sohbet listesinde ("Messages" bölümü)
    /// önizlemeler, ana ekranda bütün yazılar `home` rolünde (panelde kart). Düz yeri bilinmeyen gruplar rolsüz kalır.
    static func roles(_ groups: [ScreenTranslation.Group], home: Bool) -> [ScreenTranslation.Group] {
        guard groups.allSatisfy({ $0.phone != nil }) else { return groups.map { var g = $0; g.phone = nil; return g } }
        let list = groups.contains { section($0.paragraphs.joined()) != nil }
        let first = groups.indices.min { groups[$0].phone!.spot.top < groups[$1].phone!.spot.top }
        let placed = groups.indices.map { index in
            var group = groups[index]
            let text = group.paragraphs.joined(separator: " ")
            let spot = group.phone!.spot
            let row = PhoneChat.Row(lines: [], spot: spot, text: text)
            let role: ScreenPhoneCard.Role
            if home { role = .home }
            else if index == first, !list, PhoneChat.isHeader(row) { role = .header }
            else if list { role = section(text) != nil ? .heading : .preview }
            else { role = PhoneChat.role(of: [row]) }
            group.phone = ScreenPhoneCard.Placement(role: role, spot: spot)
            return group
        }
        // Sohbetin altındaki cevap seçenekleri (`PhoneChat.withOptions`); gruplar yukarıdan aşağı sıralı.
        guard !home, !list else { return placed }
        let order = placed.indices.sorted { placed[$0].phone!.spot.top < placed[$1].phone!.spot.top }
        let roles = PhoneChat.withOptions(order.map { placed[$0].phone!.role })
        var result = placed
        for (position, index) in order.enumerated() { result[index].phone?.role = roles[position] }
        return result
    }

    /// Art arda iki kez yazılmış metin ("A. B. A. B.") bir kez: OCR aynı satırı iki kutuda okuyunca ya da motor çeviriyi
    /// iki kez yazınca balonda aynı paragraf art arda iki kez görünüyordu (X, 22 Kas). Metin sözcük sözcük ikiye bölünür;
    /// iki yarı aynı mesajsa (`PhoneSteady.sameReading`, kısa yarıda birebir aynı) ilk yarı kalır. Windows ve Android aynı.
    static func withoutRepeat(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 4, words.count % 2 == 0 else { return text }
        let half = words.count / 2
        let first = words[..<half].joined(separator: " "), second = words[half...].joined(separator: " ")
        guard TextMatch.normalize(first).contains(where: \.isLetter), PhoneSteady.sameReading(first, second) else { return text }
        return first
    }

    /// Aynı balonda bir öncekiyle aynı (`PhoneSteady.sameReading`) ya da bir öncekinin içinde kalan satır atılır: Vision
    /// soluk satırı bazen hem tam hem parça olarak iki kutuda okur.
    static func withoutRepeatedLines(_ lines: [TextLine]) -> [TextLine] {
        var kept: [TextLine] = []
        for line in lines {
            if let previous = kept.last {
                let a = TextMatch.normalize(previous.text), b = TextMatch.normalize(line.text)
                if PhoneSteady.sameReading(previous.text, line.text)
                    || (b.count >= 6 && 2 * b.count >= a.count && b.filter(\.isLetter).count >= 4 && a.contains(b)) { continue }
            }
            kept.append(line)
        }
        return kept
    }

    private static func endsSentence(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".!?".contains($0) } ?? false
    }

    /// Düzeltilmiş telefon görüntüsünde satır arası dar, ardışık balonlar arasındaki boşluk daha geniştir. Sohbette balon
    /// aralığı (`PhoneChat.bubbleGap`) cümle sonundan bağımsızdır: OCR nokta kaçırsa da iki cevap ayrı kalır (X, 28 Kas,
    /// beta.107; Windows ve Android ile aynı).
    private static func breaksBlock(_ previous: TextBox, _ next: TextBox, gapShare: Double) -> Bool {
        let lineHeight = max(previous.bottom - previous.top, next.bottom - next.top)
        if next.top - previous.bottom > lineHeight * gapShare { return true }
        let alignedLeft = abs(previous.left - next.left) <= 0.08
        let alignedRight = min(previous.left, next.left) > 0.25 && abs(previous.right - next.right) <= 0.045
        return !alignedLeft && !alignedRight
    }
}
