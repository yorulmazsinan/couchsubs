// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

/// Yapay zekâ hizmetlerinin yerine geçen sahte sunucu: istekleri saklar, cümleleri "[tr] cümle" diye çevirir.
/// Gerçek hizmetlere hiç gidilmez.
private final class FakeAI: URLProtocol {
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: [String: Any])] = []
    /// Verilirse bu durum koduyla ve gövdeyle yanıt verir.
    nonisolated(unsafe) static var failure: (status: Int, body: String)?
    /// Verilirse yanıt gelmez, istek zaman aşımına düşer.
    nonisolated(unsafe) static var timeout = false
    /// Verilirse hizmetin döndüğü metin bu olur.
    nonisolated(unsafe) static var replyText: String?
    /// İstek uçuşta iken oyun değişimini taklit eder; yanıt verilmeden çağrılır.
    nonisolated(unsafe) static var onRequest: (() -> Void)?
    /// Verilirse eski Ollama gibi düşünmeyi kapatan alanı 400 ile reddeder.
    nonisolated(unsafe) static var rejectThinking = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.requests.append((request, body))
        Self.onRequest?()
        if Self.timeout {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let rejected = Self.rejectThinking && body["reasoning_effort"] != nil
        let status = rejected ? 400 : Self.failure?.status ?? 200
        let reply: Data
        if rejected {
            reply = Data(#"{"error":{"message":"invalid reasoning value: \"none\" (must be \"high\", \"medium\", or \"low\")"}}"#.utf8)
        } else if let failure = Self.failure {
            reply = Data(failure.body.utf8)
        } else {
            let text = Self.replyText ?? Self.echo(Self.userText(body, url: request.url!))
            reply = try! JSONSerialization.data(withJSONObject: Self.wrap(text, url: request.url!))
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func userText(_ body: [String: Any], url: URL) -> String {
        if url.host == "generativelanguage.googleapis.com" {
            let content = (body["contents"] as? [[String: Any]])?.first
            return ((content?["parts"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        let messages = body["messages"] as? [[String: Any]] ?? []
        return messages.last?["content"] as? String ?? ""
    }

    /// İletinin son satırındaki JSON dizisini "[tr] …" diye çevirir.
    static func echo(_ user: String) -> String {
        let list = user.split(separator: "\n").last.map(String.init) ?? "[]"
        let sentences = (try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String]) ?? []
        let data = try! JSONSerialization.data(withJSONObject: sentences.map { "[tr] " + $0 })
        return String(data: data, encoding: .utf8)!
    }

    /// Hizmetin kendi yanıt biçimi.
    static func wrap(_ text: String, url: URL) -> [String: Any] {
        switch url.host {
        case "generativelanguage.googleapis.com":
            ["candidates": [["content": ["role": "model", "parts": [["text": "thinking…", "thought": true], ["text": text]]]]]]
        // Yerel model sunucuları (Ollama, LM Studio) OpenAI biçimiyle yanıt verir.
        case "api.openai.com", "localhost", "127.0.0.1", "192.168.1.20":
            ["choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]]]
        default:
            ["content": [["type": "thinking", "thinking": "…"], ["type": "text", "text": text]], "stop_reason": "end_turn"]
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeAI.self]
        return URLSession(configuration: configuration)
    }
}

private final class WarmupFallback: TextTranslator {
    private(set) var warmUpCalls = 0

    func warmUp() async { warmUpCalls += 1 }
    func translate(_ text: String) async throws -> String { "yerel: " + text }
}

/// Windows'taki AiTranslatorTests ile aynı durumlar.
final class AITranslationTests: XCTestCase {
    private let secret = "sk-SECRET-123"

    override func setUp() {
        FakeAI.requests = []
        FakeAI.failure = nil
        FakeAI.timeout = false
        FakeAI.replyText = nil
        FakeAI.onRequest = nil
        FakeAI.rejectThinking = false
        LocalThinking.reset()
    }

    /// Her çevirmen kendi dakikalık hakkıyla kurulur; testler uygulamanın ortak hakkını tüketmesin.
    private func make(_ provider: AIProvider, cache: TranslationCache = TranslationCache(), model: String? = nil,
                      budget: RequestBudget = RequestBudget(perMinute: 1000)) -> AITranslationCore {
        AITranslationCore(provider: provider, key: "  \(secret) ", model: model, session: FakeAI.session(), cache: cache, budget: budget)
    }

    /// Gemini'nin dakikalık sınır yanıtı (error.details içinde QuotaFailure ve RetryInfo).
    private func rateLimitBody(quotaId: String, value: String = "5", delay: String = "3s") -> String {
        #"{"error":{"code":429,"message":"You exceeded your current quota.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"\#(quotaId)","quotaValue":"\#(value)"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"\#(delay)"}]}}"#
    }

    private func local(_ text: String) async throws -> String { "yerel: " + text }

    private func user(_ index: Int) -> String { FakeAI.userText(FakeAI.requests[index].body, url: FakeAI.requests[index].request.url!) }

    private func withGame(_ cache: TranslationCache, game: @escaping @Sendable () -> String?) -> AITranslationCore {
        AITranslationCore(provider: .openAI, key: secret, session: FakeAI.session(), cache: cache,
                          budget: RequestBudget(perMinute: 1000), game: game)
    }

    func testGameCacheSeparatesGamesAndReusesTheSameGame() async throws {
        for screen in [false, true] {
            FakeAI.requests = []
            let box = GameBox()
            box.value = "City game"
            let core = withGame(TranslationCache(), game: { box.value })
            func translate() async throws -> String {
                if screen { return try await core.translateAll(["The bank is close."], fallback: local)[0] }
                return try await core.translate("The bank is close.", fallback: local)
            }
            FakeAI.replyText = #"["Banka yakında."]"#
            let first = try await translate()
            let repeatFirst = try await translate()
            XCTAssertEqual(first, "Banka yakında.")
            XCTAssertEqual(repeatFirst, first)
            XCTAssertEqual(FakeAI.requests.count, 1)
            box.value = "River game"
            FakeAI.replyText = #"["Kıyı yakında."]"#
            let second = try await translate()
            XCTAssertEqual(second, "Kıyı yakında.")
            XCTAssertEqual(FakeAI.requests.count, 2)
            XCTAssertTrue(user(0).hasPrefix("Game: City game\n"))
            if FakeAI.requests.count > 1 { XCTAssertTrue(user(1).hasPrefix("Game: River game\n")) }
            box.value = "City game"
            let back = try await translate()
            XCTAssertEqual(back, first)
            XCTAssertEqual(FakeAI.requests.count, 2)
        }
    }

    func testGameCacheAlsoSeparatesSentencePieces() async throws {
        let box = GameBox()
        box.value = "One"
        let core = withGame(TranslationCache(), game: { box.value })
        _ = try await core.translate("Stay close.", fallback: local)
        box.value = "Two"
        _ = try await core.translate("Stay close. Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)
        XCTAssertTrue(user(1).hasSuffix("[\"Stay close.\",\"Run!\"]"))
        _ = try await core.translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)
    }

    func testGameCacheKeepsLegacyEntriesOnlyForUnknownGame() async throws {
        for screen in [false, true] {
            FakeAI.requests = []
            let cache = TranslationCache()
            cache.store("Eski çeviri.", for: "Stay close.")
            let box = GameBox()
            let core = withGame(cache, game: { box.value })
            func translate() async throws -> String {
                if screen { return try await core.translateAll(["Stay close."], fallback: local)[0] }
                return try await core.translate("Stay close.", fallback: local)
            }
            let unknown = try await translate()
            XCTAssertEqual(unknown, "Eski çeviri.")
            box.value = "   "
            let blank = try await translate()
            XCTAssertEqual(blank, unknown)
            XCTAssertTrue(FakeAI.requests.isEmpty)
            box.value = "  One  "
            let known = try await translate()
            XCTAssertEqual(known, "[tr] Stay close.")
            if !FakeAI.requests.isEmpty { XCTAssertTrue(user(0).hasPrefix("Game: One\n")) }
            box.value = "One"
            let trimmed = try await translate()
            XCTAssertEqual(trimmed, known)
            XCTAssertEqual(FakeAI.requests.count, 1)
            box.value = nil
            let unknownAgain = try await translate()
            XCTAssertEqual(unknownAgain, unknown)
            XCTAssertEqual(cache.value(for: "Stay close."), unknown)
        }
    }

    func testGameCacheSnapshotsGameBeforeRequestAndStoresUnderThatGame() async throws {
        for screen in [false, true] {
            FakeAI.requests = []
            let box = GameBox()
            box.value = "One"
            let cache = TranslationCache()
            FakeAI.onRequest = { box.value = "Two" }
            let core = withGame(cache, game: { box.reads += 1; return box.value })
            if screen { _ = try await core.translateAll(["Stay close."], fallback: local) }
            else { _ = try await core.translate("Stay close.", fallback: local) }
            XCTAssertEqual(box.reads, 1)
            XCTAssertTrue(user(0).hasPrefix("Game: One\n"))
            let other = withGame(cache, game: { "Two" })
            if screen { _ = try await other.translateAll(["Stay close."], fallback: local) }
            else { _ = try await other.translate("Stay close.", fallback: local) }
            XCTAssertEqual(FakeAI.requests.count, 2)
            let original = withGame(cache, game: { "One" })
            if screen { _ = try await original.translateAll(["Stay close."], fallback: local) }
            else { _ = try await original.translate("Stay close.", fallback: local) }
            XCTAssertEqual(FakeAI.requests.count, 2)
        }
    }

    func testGameCachePersistsSpeechPiecesWithoutLeakingAcrossGames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("couchsubs-game-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.jsonl")
        let text = "KRATOS: We go now. Stay close."
        let box = GameBox()
        box.value = "One"
        let first = withGame(TranslationCache(file: file), game: { box.value })
        _ = try await first.translate(text, fallback: local)
        let expected = first.spokenLines(for: text, fallback: { _ in [] })
        XCTAssertEqual(expected.count, 2)
        XCTAssertTrue(expected.allSatisfy { $0.speaker == "KRATOS" })
        box.value = "Two"
        XCTAssertTrue(first.spokenLines(for: text, fallback: { _ in [] }).isEmpty)
        box.value = "One"
        let reloaded = withGame(TranslationCache(file: file), game: { box.value })
        XCTAssertEqual(reloaded.spokenLines(for: text, fallback: { _ in [] }), expected)
        _ = try await reloaded.translate(text, fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 1)
        box.value = "Two"
        XCTAssertTrue(reloaded.spokenLines(for: text, fallback: { _ in [] }).isEmpty)
        FakeAI.replyText = #"["Gidelim.","Yakında kal."]"#
        _ = try await reloaded.translate(text, fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)
        XCTAssertEqual(reloaded.spokenLines(for: text, fallback: { _ in [] }).first?.turkish, "Gidelim.")
        box.value = "One"
        XCTAssertEqual(reloaded.spokenLines(for: text, fallback: { _ in [] }), expected)
    }

    func testGameCacheSpeechCanUseWholeScreenEntryWithoutSentenceEntries() async throws {
        let cache = TranslationCache()
        let text = "We go now. Stay close."
        _ = try await withGame(cache, game: { "One" }).translateAll([text], fallback: local)
        let lines = withGame(cache, game: { "One" }).spokenLines(for: text, fallback: { _ in [] })
        XCTAssertEqual(lines, [SpokenLine(english: text, turkish: "[tr] " + text)])
        XCTAssertTrue(withGame(cache, game: { "Two" }).spokenLines(for: text, fallback: { _ in [] }).isEmpty)
    }

    func testGameCacheScreenBatchesKeepTheInitialGame() async throws {
        let box = GameBox()
        box.value = "One"
        let cache = TranslationCache()
        let texts = (0...AITranslationCore.screenBatch).map { "Menu item \($0)" }
        FakeAI.onRequest = { box.value = "Two" }
        let core = withGame(cache, game: { box.reads += 1; return box.value })
        let result = try await core.translateAll(texts, fallback: local)
        XCTAssertEqual(result, texts.map { "[tr] " + $0 })
        XCTAssertEqual(box.reads, 1)
        XCTAssertEqual(FakeAI.requests.count, 2)
        XCTAssertTrue(user(0).hasPrefix("Game: One\n"))
        XCTAssertTrue(user(1).hasPrefix("Game: One\n"))
        _ = try await withGame(cache, game: { "One" }).translateAll(texts, fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)
        _ = try await withGame(cache, game: { "Two" }).translateAll(texts, fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 4)
    }

    // MARK: - İstek

    func testGeminiRequest() async throws {
        let translator = make(.gemini)
        let result = try await translator.translate("KRATOS: We go now.", fallback: local)
        XCTAssertEqual(result, "KRATOS: [tr] We go now.")
        let (request, body) = FakeAI.requests[0]
        XCTAssertEqual(request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), secret)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let system = ((body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(system, AIRequest.systemPrompt)
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int, AIRequest.maxOutputTokens)
        // Flash-Lite zaten en az düşünmeyle çalışır; düşünme ayarı gönderilmez.
        XCTAssertNil((body["generationConfig"] as? [String: Any])?["thinkingConfig"])
        // Konuşmacı etiketi gönderilmez; yalnız cümle gider.
        XCTAssertTrue(user(0).hasSuffix("[\"We go now.\"]"))
        XCTAssertFalse(user(0).contains("KRATOS"))
    }

    /// #287: konuşan etiketinden öğrenilen ad, sonraki cümlede geçince istemde "çevirme" diye adıyla söylenir; görev
    /// sözcükleri ("Soldier") ve küçük harfle geçen sözcük ("ghostly") söylenmez.
    func testLearnedSpeakerNamesAreNamedInThePrompt() async throws {
        let translator = make(.gemini)
        _ = try await translator.translate("PRICE: Move.", fallback: local)
        XCTAssertFalse(user(0).contains("Character names"))
        _ = try await translator.translate("SOLDIER: Price, get down!", fallback: local)
        XCTAssertTrue(user(1).contains("Character names (keep them exactly as written, do not translate them): Price\n"))
        XCTAssertFalse(user(1).contains("Soldier"))
        _ = try await translator.translate("It looks ghostly, price is high.", fallback: local)
        XCTAssertFalse(user(2).contains("Character names"))
    }

    /// Model cümleyi çevirmeden geri verirse cümle yerel çeviriyle yeniden denenir ve yanıt önbelleğe yazılmaz (#245:
    /// qwen2.5:3b "You think I'm on the run?" cümlesini olduğu gibi döndürdü, hat onu Türkçe sanıp göstermedi). Yerel
    /// çeviri de aynı kalırsa (ad) modelin yanıtı kalır ve önbelleğe yazılır.
    func testEchoedSentenceIsRetriedLocallyAndNotCached() async throws {
        FakeAI.replyText = #"["You think I'm on the run?"]"#
        let core = make(.openAI)
        var asked: [String] = []
        let local: (String) async throws -> String = { text in
            asked.append(text)
            return "yerel: " + text
        }
        let first = try await core.translate("Tommy: You think I'm on the run?", fallback: local)
        XCTAssertEqual(first, "Tommy: yerel: You think I'm on the run?")
        XCTAssertEqual(asked, ["You think I'm on the run?"])
        _ = try await core.translate("Tommy: You think I'm on the run?", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)

        FakeAI.replyText = #"["Thomas Angelo."]"#
        let names = make(.openAI)
        let same: (String) async throws -> String = { $0 }
        let name = try await names.translate("Thomas Angelo.", fallback: same)
        XCTAssertEqual(name, "Thomas Angelo.")
        _ = try await names.translate("Thomas Angelo.", fallback: same)
        XCTAssertEqual(FakeAI.requests.count, 3)
    }

    /// Model dizide cümleyi boş bırakırsa (#296) cümle yerel çeviriyle denenir; yerel çeviri de boşsa cümle olduğu gibi
    /// kalır. İki durumda da boş yanıt önbelleğe yazılmaz (Windows: EmptyItemIsRetriedLocallyAndNotCached).
    func testEmptyItemIsRetriedLocallyAndNotCached() async throws {
        FakeAI.replyText = #"[""]"#
        let core = make(.openAI)
        var asked: [String] = []
        let local: (String) async throws -> String = { text in
            asked.append(text)
            return "yerel: " + text
        }
        let first = try await core.translate("Doesn't 00k good.", fallback: local)
        XCTAssertEqual(first, "yerel: Doesn't 00k good.")
        XCTAssertEqual(asked, ["Doesn't 00k good."])
        _ = try await core.translate("Doesn't 00k good.", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)

        let blank = make(.openAI)
        let empty: (String) async throws -> String = { _ in "" }
        let kept = try await blank.translate("Doesn't 00k good.", fallback: empty)
        XCTAssertEqual(kept, "Doesn't 00k good.")
        _ = try await blank.translate("Doesn't 00k good.", fallback: empty)
        XCTAssertEqual(FakeAI.requests.count, 4)
    }

    func testOpenAIRequest() async throws {
        _ = try await make(.openAI).translate("Run!", fallback: local)
        let (request, body) = FakeAI.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, AIRequest.maxOutputTokens)
        let messages = body["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["developer", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, AIRequest.systemPrompt)
    }

    func testTranslatorWarmUpDoesNotSpendAIRequestOrSeedFirstSubtitleContext() async throws {
        let fallback = WarmupFallback()
        let budget = RequestBudget(perMinute: 1)
        let translator = AITranslator(provider: .openAI, key: secret, model: nil, fallback: fallback,
                                      session: FakeAI.session(), budget: budget)

        await translator.warmUp()
        XCTAssertEqual(FakeAI.requests.count, 0)
        XCTAssertEqual(fallback.warmUpCalls, 1)

        _ = try await translator.translate("First real subtitle.")

        XCTAssertEqual(FakeAI.requests.count, 1)
        XCTAssertFalse(user(0).contains("Hello"))
        XCTAssertTrue(user(0).hasSuffix("[\"First real subtitle.\"]"))
    }

    func testClaudeRequest() async throws {
        _ = try await make(.claude).translate("Run!", fallback: local)
        let (request, body) = FakeAI.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), secret)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, AIRequest.maxOutputTokens)
        XCTAssertEqual(body["system"] as? String, AIRequest.systemPrompt)
        XCTAssertNil(body["temperature"])
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    }

    /// Effort ve düşünme ayarı listedeki modelden gelir, adından tahmin edilmez.
    func testPerModelParametersAreSent() async throws {
        _ = try await make(.openAI, model: "gpt-6.1-terra").translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests[0].body["model"] as? String, "gpt-6.1-terra")
        XCTAssertEqual(FakeAI.requests[0].body["reasoning_effort"] as? String, "none")

        _ = try await make(.claude, model: "claude-sonnet-5-5").translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests[1].body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual((FakeAI.requests[1].body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual((FakeAI.requests[1].body["thinking"] as? [String: Any])?["type"] as? String, "between_tools")

        _ = try await make(.gemini, model: "gemini-3.6-flash").translate("Run!", fallback: local)
        XCTAssertTrue(FakeAI.requests[2].request.url!.absoluteString.contains("/models/gemini-3.6-flash:generateContent"))
        let config = FakeAI.requests[2].body["generationConfig"] as? [String: Any]
        XCTAssertEqual((config?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "LOW")
    }

    /// Listede olmayan kayıtlı model (eski ayar, elle yazılmış ad, listeden çıkarılan model) varsayılana döner.
    func testUnknownModelFallsBackToDefault() async throws {
        _ = try await make(.openAI, model: "gpt-4o").translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests[0].body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(AIProvider.gemini.model("").id, "gemini-3.5-flash-lite")
        XCTAssertEqual(AIProvider.claude.model(nil).id, "claude-haiku-5-5")
        XCTAssertEqual(AIProvider.gemini.engineID(model: "gemini-3.5-flash-lite"), "gemini:gemini-3.5-flash-lite")
        XCTAssertEqual(AIProvider.openAI.engineID(model: AIProvider.openAI.defaultModel.id), "openai:gpt-6-luna")
    }

    /// Ayarlar'da (Mac, iPhone) seçilen Gemini modeli isteğe gider; dakikalık hak modelin sınırıdır (flash-lite 15,
    /// 3.6 flash 10). Kayıt yoksa ilk model kullanılır.
    func testSelectedGeminiModelGoesToTheRequest() async throws {
        var settings = UserSettings()
        XCTAssertEqual(settings.model(for: .gemini), "gemini-3.5-flash-lite")
        XCTAssertEqual(RequestBudget.shared(provider: .gemini, model: AIProvider.gemini.model(settings.geminiModel))?.perMinute, 15)
        settings.geminiModel = "gemini-3.6-flash"
        let chosen = AIProvider.gemini.model(settings.model(for: .gemini))
        XCTAssertEqual(RequestBudget.shared(provider: .gemini, model: chosen)?.perMinute, 10)
        let saved = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.geminiModel, "gemini-3.6-flash")

        _ = try await make(.gemini, model: saved.model(for: .gemini)).translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests[0].request.url?.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent")
    }

    /// Liste Windows ile ortak dosyadan okunur; her hizmette önerilen hızlı model ilk sıradadır.
    func testCatalogIsTheSharedFile() throws {
        for provider in AIProvider.cloud {
            XCTAssertGreaterThanOrEqual(provider.models.count, 2, provider.rawValue)
            XCTAssertEqual(provider.defaultModel.label, "Fast and cheap (recommended)")
            XCTAssertEqual(Set(provider.models.map(\.id)).count, provider.models.count)
        }
        XCTAssertEqual(AIProvider.gemini.defaultModel, AIModel(id: "gemini-3.5-flash-lite", label: "Fast and cheap (recommended)",
                                                               freeTier: true, requestsPerMinute: 15))
        XCTAssertEqual(AIProvider.claude.defaultModel.thinking, "disabled")
        // Depodaki dosya, uygulamaya giden kopyayla aynıdır; Windows da bu dosyayı gömer.
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CouchSubsCore/Resources/ai-models.json")
        let parsed = AIModel.parse(try Data(contentsOf: file))
        XCTAssertEqual(parsed, AIModel.catalog)
        XCTAssertEqual(Set(parsed.keys), Set(AIProvider.cloud.map(\.rawValue)))
        // Yerel modelin listesi yoktur; model adını kullanıcı yazar.
        XCTAssertTrue(AIProvider.local.models.isEmpty)
        XCTAssertEqual(AIProvider.local.defaultModel.id, "qwen2.5:7b")
    }

    // MARK: - Yerel model (Ollama, LM Studio)

    private func makeLocal(_ baseURL: String = LocalAIServer.ollamaURL, model: String = "qwen2.5:7b", key: String = "",
                           cache: TranslationCache = TranslationCache()) -> AITranslationCore {
        AITranslationCore(provider: .local, key: key, model: model, server: LocalAIServer(baseURL: baseURL, model: model),
                          session: FakeAI.session(), cache: cache, budget: RequestBudget(perMinute: 1000))
    }

    /// OpenAI uyumlu en sade istek: system + user, temperature, max_tokens, stream false; bulut hizmetine özel alan gitmez.
    func testLocalRequest() async throws {
        let result = try await makeLocal().translate("KRATOS: We go now.", fallback: local)
        XCTAssertEqual(result, "KRATOS: [tr] We go now.")
        let (request, body) = FakeAI.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // Anahtar boşsa Authorization başlığı hiç gitmez.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(body["model"] as? String, "qwen2.5:7b")
        XCTAssertEqual(body["temperature"] as? Double, AIRequest.localTemperature)
        XCTAssertEqual(body["max_tokens"] as? Int, AIRequest.maxOutputTokens)
        XCTAssertEqual(body["stream"] as? Bool, false)
        // Ollama'da düşünme kapalı (#295).
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertEqual(Set(body.keys), ["model", "messages", "temperature", "max_tokens", "stream", "think", "reasoning_effort", "keep_alive"])
        // Model bellekte kalır; uzun sessizlikten sonra ilk satır yükleme beklemez (#306).
        XCTAssertEqual(body["keep_alive"] as? String, "24h")
        // Aynı satır her seferinde aynı çevrilsin (#306).
        XCTAssertEqual(body["temperature"] as? Double, 0)
        let messages = body["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, AIRequest.systemPrompt)
        XCTAssertTrue(user(0).hasSuffix("[\"We go now.\"]"))
    }

    /// LM Studio adresi ve isteğe bağlı anahtar (yalnız doluysa Bearer olarak gider).
    func testLocalRequestWithKeyAndLMStudio() async throws {
        _ = try await makeLocal(LocalAIServer.lmStudioURL, model: "qwen2.5-7b-instruct", key: " lm-key ").translate("Run!", fallback: local)
        let (request, body) = FakeAI.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer lm-key")
        XCTAssertEqual(body["model"] as? String, "qwen2.5-7b-instruct")
        // Düşünme alanları ve keep_alive yalnız Ollama'ya gider.
        XCTAssertNil(body["think"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["keep_alive"])
        XCTAssertEqual(body["temperature"] as? Double, 0)
    }

    /// Ek talimat (#306) bütün yapay zekâ hizmetlerinde sistem talimatının sonuna eklenir; boşsa hiçbir şey değişmez.
    func testInstructionIsAppendedToSystemPrompt() throws {
        func system(_ provider: AIProvider, _ instruction: String?) throws -> String? {
            let request = AIRequest.make(provider: provider, key: "k", model: provider.defaultModel, sentences: ["Run!"], context: [],
                                         instruction: instruction)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            switch provider {
            case .gemini:
                return (((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"]) as? String
            case .claude: return json["system"] as? String
            case .openAI, .local: return (json["messages"] as? [[String: Any]])?.first?["content"] as? String
            }
        }
        for provider in AIProvider.allCases {
            XCTAssertEqual(try system(provider, nil), AIRequest.systemPrompt)
            XCTAssertEqual(try system(provider, "  \n "), AIRequest.systemPrompt)
            XCTAssertEqual(try system(provider, " Translate swear words without softening them.\n"),
                           AIRequest.systemPrompt + "\n\nTranslate swear words without softening them.")
        }
        XCTAssertEqual(AIRequest.instruction(String(repeating: "a", count: 5000))?.count, AIRequest.maxInstructionLength)
        XCTAssertNil(AIRequest.instructionTag(" "))
        XCTAssertEqual(AIRequest.instructionTag("Be blunt."), AIRequest.instructionTag(" Be blunt. "))
        XCTAssertNotEqual(AIRequest.instructionTag("Be blunt."), AIRequest.instructionTag("Be polite."))
    }

    /// Talimat değişince önbellekteki eski çeviri dönmez; talimat yoksa eski kayıtlar geçerli kalır.
    func testInstructionSeparatesCache() async throws {
        let cache = TranslationCache()
        func make(_ instruction: String?) -> AITranslationCore {
            AITranslationCore(provider: .openAI, key: secret, session: FakeAI.session(), cache: cache,
                              budget: RequestBudget(perMinute: 1000), instruction: instruction)
        }
        _ = try await make(nil).translate("Run!", fallback: local)
        _ = try await make("").translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 1)
        _ = try await make("Be blunt.").translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)
        let messages = FakeAI.requests[1].body["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue((messages.first?["content"] as? String ?? "").hasSuffix("\n\nBe blunt."))
        _ = try await make("Be blunt.").translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)
        _ = try await make("Be polite.").translate("Run!", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 3)
    }

    /// Ayarlarda elle yazılmış "localhost" istekte 127.0.0.1 olur (Windows'ta IPv6 gecikmesi, #295); başka adrese dokunulmaz.
    func testLocalhostIsSentAsIPv4() {
        XCTAssertEqual(LocalAIServer.ollamaURL, "http://127.0.0.1:11434/v1")
        let cases: [(String, String)] = [
            ("http://localhost:11434/v1", "http://127.0.0.1:11434/v1/chat/completions"),
            ("LOCALHOST:11434", "http://127.0.0.1:11434/v1/chat/completions"),
            ("https://localhost:8443/api/v1", "https://127.0.0.1:8443/api/v1/chat/completions"),
            ("http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1/chat/completions"),
            ("http://192.168.1.20:11434/v1", "http://192.168.1.20:11434/v1/chat/completions"),
            ("http://localhost.example.com:11434/v1", "http://localhost.example.com:11434/v1/chat/completions"),
            ("http://[::1]:11434/v1", "http://[::1]:11434/v1/chat/completions"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(LocalAIServer(baseURL: text, model: "m")?.chatURL.absoluteString, expected, text)
        }
        // Kullanıcıya gösterilen adres yazdığı gibi kalır.
        XCTAssertEqual(LocalAIServer(baseURL: "localhost:11434", model: "m")?.address, "http://localhost:11434")
    }

    /// Eski Ollama düşünmeyi kapatan alanı 400 ile reddederse alansız yeniden denenir; sonraki isteklerde hiç gönderilmez.
    func testOldOllamaRejectingThinkFieldFallsBack() async throws {
        FakeAI.rejectThinking = true
        let core = makeLocal()
        let first = try await core.translate("Run!", fallback: local)
        XCTAssertEqual(first, "[tr] Run!")
        XCTAssertNil(core.lastFailure)
        XCTAssertEqual(FakeAI.requests.count, 2)
        XCTAssertEqual(FakeAI.requests[0].body["think"] as? Bool, false)
        XCTAssertNil(FakeAI.requests[1].body["think"])
        XCTAssertNil(FakeAI.requests[1].body["reasoning_effort"])
        // Oturum boyunca hatırlanır: yeni çevirmen de alanı göndermez, tek istek gider.
        _ = try await makeLocal().translate("Hide!", fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 3)
        XCTAssertNil(FakeAI.requests[2].body["think"])
    }

    /// Kullanıcının yazdığı adres düzeltilir: şema, "/v1", sondaki "/" ve yapıştırılmış "/chat/completions".
    func testLocalServerAddress() {
        let cases: [(String, String?)] = [
            ("http://localhost:11434/v1", "http://localhost:11434/v1"),
            ("  http://localhost:11434/v1/  ", "http://localhost:11434/v1"),
            ("localhost:11434", "http://localhost:11434/v1"),
            ("http://127.0.0.1:1234", "http://127.0.0.1:1234/v1"),
            ("http://localhost:1234/v1/chat/completions", "http://localhost:1234/v1"),
            ("https://ai.example.com/openai/v1", "https://ai.example.com/openai/v1"),
            ("", nil), ("ftp://localhost:11434", nil), ("http://", nil), ("local host", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(LocalAIServer.normalize(text)?.absoluteString, expected, text)
        }
        XCTAssertNil(LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: "  "))
        let server = LocalAIServer(baseURL: "localhost:11434", model: " qwen2.5:7b ")!
        XCTAssertEqual(server.model, "qwen2.5:7b")
        XCTAssertEqual(server.address, "http://localhost:11434")
        XCTAssertEqual(server.kind, .ollama)
        XCTAssertEqual(LocalAIServer(baseURL: LocalAIServer.lmStudioURL, model: "m")?.kind, .lmStudio)
        XCTAssertEqual(LocalAIServer(baseURL: "http://192.168.1.20:8080/v1", model: "m")?.kind, .other)
        // Yazılan model adı listeye bakılmadan kullanılır; boşsa varsayılan.
        XCTAssertEqual(AIProvider.local.model("llama3.1:8b").id, "llama3.1:8b")
        XCTAssertEqual(AIProvider.local.model(" ").id, "qwen2.5:7b")
        XCTAssertNil(RequestBudget.shared(provider: .local, model: AIProvider.local.defaultModel))
    }

    /// Önbellekteki motor adında sunucu ve model vardır; farklı yerel modellerin çevirileri karışmaz.
    func testLocalEngineIDIncludesServerAndModel() {
        let ollama = LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: "qwen2.5:7b")!
        XCTAssertEqual(ollama.engineID, "local:127.0.0.1:11434/qwen2.5:7b")
        let named = LocalAIServer(baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b")!
        XCTAssertEqual(named.engineID, "local:localhost:11434/qwen2.5:7b")
        XCTAssertEqual(LocalAIServer(baseURL: "http://LOCALHOST:11434/v1/", model: "qwen2.5:7b")!.engineID, named.engineID)
        XCTAssertNotEqual(LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: "qwen2.5:14b")!.engineID, ollama.engineID)
        XCTAssertNotEqual(LocalAIServer(baseURL: LocalAIServer.lmStudioURL, model: "qwen2.5:7b")!.engineID, ollama.engineID)
        XCTAssertNotEqual(LocalAIServer(baseURL: "http://192.168.1.20:11434/v1", model: "qwen2.5:7b")!.engineID, ollama.engineID)
        // Bulut hizmetlerinin adları değişmez.
        XCTAssertFalse(AIProvider.cloud.map { $0.engineID(model: $0.defaultModel.id) }.contains(ollama.engineID))
    }

    /// Düşünen yerel modeller yanıtın başına <think>…</think> koyar; yalnız sonrası okunur.
    func testLocalThinkingIsSkipped() async throws {
        FakeAI.replyText = "<think>\nThe user wants [\"x\"] translated…\n</think>\n\n[\"Koş!\"]"
        let result = try await makeLocal().translate("Run!", fallback: local)
        XCTAssertEqual(result, "Koş!")
        XCTAssertEqual(try AIRequest.translations(from: "<think>…</think>Gidelim.", count: 1), ["Gidelim."])
    }

    /// Yerel modellerin bitiş işaretleri (`</s>`, `<|im_end|>`) ekranda kalmaz; sondaki fazla virgül diziyi bozmaz.
    func testLocalControlTokensAndTrailingComma() throws {
        XCTAssertEqual(try AIRequest.translations(from: "[\"Yere yat!\"]</s>", count: 1), ["Yere yat!"])
        XCTAssertEqual(try AIRequest.translations(from: "[Yere yat!]</s>", count: 1), ["Yere yat!"])
        XCTAssertEqual(try AIRequest.translations(from: "Defol buradan!<|im_end|>", count: 1), ["Defol buradan!"])
        XCTAssertEqual(try AIRequest.translations(from: "<s>[\"Bir.\", \"İki.\",]<|eot_id|>", count: 2), ["Bir.", "İki."])
        XCTAssertEqual(try AIRequest.translations(from: "[\"<b> etiketi kalır\"]", count: 1), ["<b> etiketi kalır"])
    }

    /// Sunucu kapalıysa ya da model indirilmemişse o satır ücretsiz çeviriyle gelir, durum bildirilir.
    func testLocalFailuresFallBack() async throws {
        FakeAI.timeout = true
        let down = makeLocal()
        let first = try await down.translate("Run!", fallback: local)
        XCTAssertEqual(first, "yerel: Run!")
        XCTAssertEqual(down.lastFailure, .busy)

        FakeAI.timeout = false
        // Ollama'nın indirilmemiş model yanıtı.
        FakeAI.failure = (404, #"{"error":{"message":"model \"qwen2.5:7b\" not found, try pulling it first","type":"api_error"}}"#)
        let missing = makeLocal()
        let second = try await missing.translate("Run!", fallback: local)
        XCTAssertEqual(second, "yerel: Run!")
        XCTAssertEqual(missing.lastFailure, .modelRejected)
    }

    /// "Bağlantıyı dene": anahtarsız çalışır; sunucunun hatası olduğu gibi döner.
    func testLocalTestWorksWithoutKey() async {
        let server = LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: "qwen2.5:7b")
        let result = await AITranslationCore.test(provider: .local, key: "", model: "qwen2.5:7b", server: server, session: FakeAI.session())
        XCTAssertEqual(result, .success("KRATOS: [tr] We go now. [tr] Stay close, boy."))
        XCTAssertNil(FakeAI.requests[0].request.value(forHTTPHeaderField: "Authorization"))

        FakeAI.timeout = true
        let down = await AITranslationCore.test(provider: .local, key: "", model: "qwen2.5:7b", server: server, session: FakeAI.session())
        XCTAssertEqual(down, .failure(.busy))
    }

    /// Yerel modelde buluttan uzun beklenir; deneme modeli belleğe yükleyeceği için daha da uzun.
    func testLocalTimeouts() {
        XCTAssertEqual(AITranslationCore.makeSession(provider: .gemini).configuration.timeoutIntervalForRequest, AITranslationCore.timeout)
        XCTAssertEqual(AITranslationCore.makeSession(provider: .local).configuration.timeoutIntervalForRequest, AITranslationCore.localTimeout)
        XCTAssertGreaterThan(AITranslationCore.localTimeout, AITranslationCore.timeout)
        XCTAssertGreaterThan(AITranslationCore.localTestTimeout, AITranslationCore.localTimeout)
    }

    /// Son gösterilen 3 satır ve çevirileri bağlam olarak gider; satırın kendisi ve tekrar okunan satır girmez.
    func testContextIsTheLastThreeShownLinesWithTranslations() async throws {
        let translator = make(.claude)
        for line in ["One.", "Two.", "Two.", "Three.", "Four.", "Five."] { _ = try await translator.translate(line, fallback: local) }
        XCTAssertEqual(FakeAI.requests.count, 5)
        XCTAssertFalse(user(0).contains("Previous subtitles"))
        XCTAssertTrue(user(1).contains("English: One.\nTurkish: [tr] One."))
        XCTAssertTrue(user(4).contains("English: Two.\nTurkish: [tr] Two.\nEnglish: Three.\nTurkish: [tr] Three.\nEnglish: Four.\nTurkish: [tr] Four."))
        XCTAssertFalse(user(4).contains("English: One."))
        XCTAssertFalse(user(4).contains("English: Five."))
    }

    func testContextDoesNotCrossGameChanges() async throws {
        let game = GameBox()
        game.value = "First game"
        let translator = withGame(TranslationCache(), game: { game.value })

        _ = try await translator.translate("This belongs to the first game.", fallback: local)
        game.value = "Second game"
        let secondTranslation = try await translator.translate("This belongs to the second game.", fallback: local)

        XCTAssertTrue(user(1).hasPrefix("Game: Second game\n"))
        XCTAssertFalse(user(1).contains("English: This belongs to the first game."))

        _ = try await translator.translate("Another line here.", fallback: local)
        XCTAssertTrue(user(2).contains("English: This belongs to the second game.\nTurkish: \(secondTranslation)"))
    }

    func testSeveralSentencesGoAsOneArray() async throws {
        let translator = make(.gemini)
        let result = try await translator.translate("We go now. Stay close.\nATREUS: Yes, father.", fallback: local)
        XCTAssertEqual(result, "[tr] We go now. [tr] Stay close.\nATREUS: [tr] Yes, father.")
        XCTAssertEqual(FakeAI.requests.count, 1)
        XCTAssertTrue(user(0).hasSuffix("[\"We go now.\",\"Stay close.\",\"Yes, father.\"]"))
        XCTAssertEqual(translator.spokenLines(for: "We go now. Stay close.\nATREUS: Yes, father.") { _ in [] }.last?.speaker, "ATREUS")
    }

    // MARK: - Yanıt

    func testReplyParsing() throws {
        XCTAssertEqual(try AIRequest.translations(from: "```json\n[\"Gidelim.\", \"Yakın dur.\"]\n```", count: 2), ["Gidelim.", "Yakın dur."])
        XCTAssertEqual(try AIRequest.translations(from: "“Gidelim.”", count: 1), ["Gidelim."])
        XCTAssertThrowsError(try AIRequest.translations(from: "[\"Tek\"]", count: 2))
        XCTAssertThrowsError(try AIRequest.translations(from: "Gidelim. Yakın dur.", count: 2))
        XCTAssertThrowsError(try AIRequest.text(provider: .gemini, from: Data(#"{"promptFeedback":{"blockReason":"OTHER"}}"#.utf8)))
        XCTAssertEqual(try AIRequest.text(provider: .openAI, from: Data(#"{"choices":[{"message":{"content":"Koş!"}}]}"#.utf8)), "Koş!")
    }

    /// Tırnaksız dizi (#27): bazı yerel modeller `[Hareket etmemiz lazım.]` döndürür; köşeli parantezler ekranda kalmaz.
    func testUnquotedArrayForOneSentence() throws {
        XCTAssertEqual(try AIRequest.translations(from: "[Hareket etmemiz lazım.]", count: 1), ["Hareket etmemiz lazım."])
        XCTAssertEqual(try AIRequest.translations(from: "[Dur, bekle, gitme.]", count: 1), ["Dur, bekle, gitme."])
        XCTAssertEqual(try AIRequest.translations(from: "<think>\nKısa bir cümle.\n</think>\n[Geri çekil lan!]", count: 1),
                       ["Geri çekil lan!"])
        XCTAssertEqual(try AIRequest.translations(from: "```json\n[Yerinden kıpırdama.]\n```", count: 1), ["Yerinden kıpırdama."])
        // İçi tırnaklı ama kaçışsız: JSON değil, yine de dış katman soyulur.
        XCTAssertEqual(try AIRequest.translations(from: "[\"Ona \"dur\" dedim.\"]", count: 1), ["Ona \"dur\" dedim."])
        // Köşeli parantez yalnız başta: düz metin olduğu gibi kalır.
        XCTAssertEqual(try AIRequest.translations(from: "[gülüyor] Hadi gidelim.", count: 1), ["[gülüyor] Hadi gidelim."])
    }

    func testUnquotedArrayForSeveralSentences() throws {
        XCTAssertEqual(try AIRequest.translations(from: "[Satır bir., Satır iki.]", count: 2), ["Satır bir.", "Satır iki."])
        XCTAssertEqual(try AIRequest.translations(from: "[\n  Gidelim.,\n  Yakın dur.\n]", count: 2), ["Gidelim.", "Yakın dur."])
        XCTAssertEqual(try AIRequest.translations(from: "<think>…</think>[Koş!, Hemen!]", count: 2), ["Koş!", "Hemen!"])
        // Sayı tutmazsa parti her zamanki geri dönüşe gider.
        XCTAssertThrowsError(try AIRequest.translations(from: "[Satır bir.]", count: 2))
        XCTAssertThrowsError(try AIRequest.translations(from: "[Bir., İki., Üç.]", count: 2))
    }

    /// Cümle içi virgül bölünmez: önce cümle sonundan sonra gelen virgül denenir, düz virgül yalnız sayı tam tutarsa.
    func testUnquotedArrayKeepsCommasInsideSentences() throws {
        XCTAssertEqual(try AIRequest.translations(from: "[Evet, efendim., Hayır, gitmiyorum.]", count: 2),
                       ["Evet, efendim.", "Hayır, gitmiyorum."])
        XCTAssertEqual(try AIRequest.translations(from: "[Dur, bekle, gitme!, Tamam.]", count: 2), ["Dur, bekle, gitme!", "Tamam."])
        XCTAssertEqual(try AIRequest.translations(from: "[Sakin ol, dostum.\nBen hallederim, merak etme.]", count: 2),
                       ["Sakin ol, dostum.", "Ben hallederim, merak etme."])
        XCTAssertThrowsError(try AIRequest.translations(from: "[Dur, bekle, gitme.]", count: 2))
        XCTAssertEqual(try AIRequest.translations(from: "[Hey, Sen]", count: 2), ["Hey", "Sen"])
    }

    /// Tırnaksız yanıtla birden çok cümle yerel çeviriye düşmez.
    func testUnquotedReplyIsUsedInsteadOfFallback() async throws {
        FakeAI.replyText = "[Gidelim., Yakın dur.]"
        let result = try await makeLocal().translate("We go now. Stay close.", fallback: local)
        XCTAssertEqual(result, "Gidelim. Yakın dur.")
    }

    /// "Ekranı çevir"in tek isteği de tırnaksız yanıtı okur; oyun adı orada da gider.
    func testScreenRequestReadsUnquotedReplyAndSendsGame() async throws {
        FakeAI.replyText = "[Haritayı aç., Kamptan ayrıl.]"
        let core = AITranslationCore(provider: .local, key: "", model: "qwen2.5:7b",
                                     server: LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: "qwen2.5:7b"),
                                     session: FakeAI.session(), cache: TranslationCache(), budget: RequestBudget(perMinute: 1000),
                                     game: { "Ghost of Yōtei" })
        let result = try await core.translateAll(["Open the map.", "Leave the camp."], fallback: local)
        XCTAssertEqual(result, ["Haritayı aç.", "Kamptan ayrıl."])
        XCTAssertTrue(user(0).hasPrefix("Game: Ghost of Yōtei\n\n"))
    }

    /// Oyun biliniyorsa (paket eşleşmesi) istemde "Game:" satırı olarak gider; bilinmiyorsa hiç gitmez.
    func testGameNameIsSentWhenKnown() async throws {
        let box = GameBox()
        let core = AITranslationCore(provider: .local, key: "", model: "qwen2.5:7b",
                                     server: LocalAIServer(baseURL: LocalAIServer.ollamaURL, model: "qwen2.5:7b"),
                                     session: FakeAI.session(), cache: TranslationCache(), budget: RequestBudget(perMinute: 1000),
                                     game: { box.value })
        _ = try await core.translate("Sit tight.", fallback: local)
        XCTAssertFalse(user(0).contains("Game:"))
        box.value = "Grand Theft Auto V"
        _ = try await core.translate("I'll handle the plastic.", fallback: local)
        XCTAssertTrue(user(1).hasPrefix("Game: Grand Theft Auto V\n\n"))
    }

    func testPlainTextReplyForOneSentence() async throws {
        FakeAI.replyText = "Koş!"
        let result = try await make(.openAI).translate("Run!", fallback: local)
        XCTAssertEqual(result, "Koş!")
    }

    func testFailureMapping() {
        let empty = Data()
        XCTAssertEqual(AIRequest.failure(status: 401, body: empty), .invalidKey)
        XCTAssertEqual(AIRequest.failure(status: 403, body: empty), .invalidKey)
        XCTAssertEqual(AIRequest.failure(status: 400, body: Data(#"{"error":{"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8)), .invalidKey)
        XCTAssertEqual(AIRequest.failure(status: 429, body: Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8)), .quotaExceeded)
        XCTAssertEqual(AIRequest.failure(status: 400, body: Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"#.utf8)), .quotaExceeded)
        XCTAssertEqual(AIRequest.failure(status: 404, body: empty), .modelRejected)
        XCTAssertEqual(AIRequest.failure(status: 400, body: Data("unknown model".utf8)), .modelRejected)
        // Hizmete ulaşıldı ama yoğun ya da arızalı: internet hatası değildir.
        XCTAssertEqual(AIRequest.failure(status: 529, body: empty), .busy)
        XCTAssertEqual(AIRequest.failure(status: 500, body: empty), .busy)
        XCTAssertEqual(AIRequest.failure(status: 503, body: Data(#"{"error":{"code":503,"message":"The model is overloaded. Please try again later.","status":"UNAVAILABLE"}}"#.utf8)), .busy)
        XCTAssertEqual(AIRequest.failure(status: 504, body: empty), .busy)
        XCTAssertEqual(AIRequest.failure(status: 408, body: empty), .busy)
        XCTAssertEqual(AIRequest.failure(status: 302, body: empty), .unreachable)
    }

    // MARK: - Hata ve yerel çeviri

    /// Kota biterse o satır yerel motorla çevrilir, bir süre hizmet denenmez, hata durumu bildirilir.
    func testFallsBackAndPausesOnError() async throws {
        FakeAI.failure = (429, #"{"error":{"message":"quota"}}"#)
        let cache = TranslationCache()
        let translator = make(.gemini, cache: cache)
        var reported: [AIFailure?] = []
        translator.onFailureChanged = { reported.append($0) }
        let first = try await translator.translate("Run!", fallback: local)
        let second = try await translator.translate("Hide!", fallback: local)
        XCTAssertEqual(first, "yerel: Run!")
        XCTAssertEqual(second, "yerel: Hide!")
        XCTAssertEqual(FakeAI.requests.count, 1)
        XCTAssertEqual(translator.lastFailure, .quotaExceeded)
        XCTAssertEqual(reported, [.quotaExceeded])
        // Yerel çeviri bu motorun önbelleğine yazılmaz.
        XCTAssertNil(cache.value(for: "Run!"))
    }

    func testCachedSentencesSurviveServicePauseWithoutLocalWork() async throws {
        for failure in ["server", "timeout", "invalid-reply", "daily-quota", "minute-quota"] {
            FakeAI.requests = []
            FakeAI.timeout = failure == "timeout"
            switch failure {
            case "daily-quota":
                FakeAI.failure = (429, rateLimitBody(quotaId: "GenerateRequestsPerDayPerProjectPerModel-FreeTier"))
            case "minute-quota":
                FakeAI.failure = (429, rateLimitBody(quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"))
            case "invalid-reply": FakeAI.failure = (200, "{}")
            default: FakeAI.failure = (503, "{}")
            }
            let cache = TranslationCache()
            cache.store("Koş!", for: "Run!")
            cache.store("Saklan!", for: "Hide!")
            let translator = make(.gemini, cache: cache)
            var calls: [String] = []
            let fallback: (String) async throws -> String = { calls.append($0); return "yerel: " + $0 }
            let failed = try await translator.translate("Wait!", fallback: fallback)
            XCTAssertEqual(failed, "yerel: Wait!")
            let error = translator.lastFailure
            let cached = try await translator.translate("KRATOS: Run! Hide!", fallback: fallback)
            XCTAssertEqual(cached, "KRATOS: Koş! Saklan!", failure)
            XCTAssertEqual(FakeAI.requests.count, 1, failure)
            XCTAssertEqual(calls, ["Wait!"], failure)
            XCTAssertEqual(translator.lastFailure, error, failure)
            XCTAssertEqual(translator.spokenLines(for: "KRATOS: Run! Hide!") { _ in [] }.last?.speaker, "KRATOS")
            let missing = try await translator.translate("Run! Jump!", fallback: fallback)
            XCTAssertEqual(missing, "yerel: Run! Jump!")
            XCTAssertEqual(calls, ["Wait!", "Run! Jump!"])
            XCTAssertEqual(FakeAI.requests.count, 1)
            XCTAssertNil(cache.value(for: "Run! Jump!"))
        }
    }

    /// Yerel modelde hata sonrası bekleme kısadır: beklerken satır yerel çeviriye düşer, bekleme bitince model yeniden denenir.
    func testLocalModelPausesBrieflyAfterError() async throws {
        FakeAI.failure = (503, "{}")
        let translator = makeLocal()
        translator.errorPause = 0.2
        var calls: [String] = []
        let fallback: (String) async throws -> String = { calls.append($0); return "yerel: " + $0 }
        let first = try await translator.translate("Run!", fallback: fallback)
        XCTAssertEqual(first, "yerel: Run!")
        FakeAI.failure = nil
        let second = try await translator.translate("Hide!", fallback: fallback)
        XCTAssertEqual(second, "yerel: Hide!")
        XCTAssertEqual(FakeAI.requests.count, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        let third = try await translator.translate("Go!", fallback: fallback)
        XCTAssertEqual(third, "[tr] Go!")
        XCTAssertEqual(FakeAI.requests.count, 2)
        XCTAssertEqual(calls, ["Run!", "Hide!"])
    }

    /// Hata sonrası bekleme: yerel modelde birkaç saniye, bulut hizmetlerinde (kota) bir dakika.
    func testErrorPauseIsShortOnlyForLocalModel() {
        XCTAssertEqual(makeLocal().errorPause, AITranslationCore.localRetryAfter)
        XCTAssertLessThanOrEqual(AITranslationCore.localRetryAfter, 10)
        XCTAssertEqual(make(.gemini).errorPause, 60)
        XCTAssertEqual(AITranslationCore.retryAfter, 60)
    }

    func testTimeoutFallsBack() async throws {
        FakeAI.timeout = true
        let translator = make(.claude)
        let probe = TranslationProbe()
        let result = try await TranslationProbe.$current.withValue(probe) {
            try await translator.translate("Run!", fallback: local)
        }
        XCTAssertEqual(result, "yerel: Run!")
        XCTAssertTrue(probe.outcome().contains("ücretsiz yedek: claude hizmet durumu: busy"))
        // Zaman aşımı: hizmete ulaşıldı ama yanıt zamanında gelmedi; "internet bağlantınızı denetleyin" denmez.
        XCTAssertEqual(translator.lastFailure, .busy)
    }

    func testClaudeKeyTestHasABoundedTotalTimeout() {
        let session = AITranslationCore.makeKeyTestSession(provider: .claude)
        XCTAssertGreaterThan(session.configuration.timeoutIntervalForRequest, AITranslationCore.timeout)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, AITranslationCore.cloudKeyTestTimeout)
    }

    // MARK: - Ücretsiz katman

    /// Varsayılan Gemini modeli ücretsiz anahtarla çalışır ve dakikalık hakkı vardır; ücretli hizmetlerde hak yoktur.
    func testDefaultGeminiModelIsFreeTier() {
        let model = AIProvider.gemini.defaultModel
        XCTAssertTrue(model.freeTier)
        XCTAssertNotNil(model.requestsPerMinute)
        XCTAssertTrue(AIProvider.gemini.models.allSatisfy { $0.freeTier && ($0.requestsPerMinute ?? 0) > 0 })
        XCTAssertTrue(AIProvider.gemini.hasFreeTier)
        XCTAssertFalse(AIProvider.openAI.hasFreeTier)
        XCTAssertFalse(AIProvider.claude.hasFreeTier)
        XCTAssertNil(RequestBudget.shared(provider: .claude, model: AIProvider.claude.defaultModel))
        let shared = RequestBudget.shared(provider: .gemini, model: model)
        XCTAssertEqual(shared?.perMinute, model.requestsPerMinute)
        // Hat yeniden kurulsa da aynı hak kullanılır.
        XCTAssertTrue(shared === RequestBudget.shared(provider: .gemini, model: model))
        // Eski listede yeni alanlar olmayabilir.
        let old = AIModel.parse(Data(#"{"gemini":[{"id":"g","label":"L"}]}"#.utf8))["gemini"]?.first
        XCTAssertEqual(old, AIModel(id: "g", label: "L"))
        XCTAssertEqual(old?.freeTier, false)
    }

    func testGeminiPaidTierDefaultsOffAndSurvivesSettingsSerialization() throws {
        let legacy = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.geminiPaidTier)
        var enabled = legacy
        enabled.geminiPaidTier = true
        let restored = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(restored.geminiPaidTier)
    }

    func testGeminiPaidKeysSkipFreeTierBudgetAndFreeKeysStayIsolated() {
        let model = AIProvider.gemini.defaultModel
        let free = RequestBudget.shared(provider: .gemini, model: model, apiKey: "free-key-one")
        XCTAssertNotNil(free)
        XCTAssertTrue(free === RequestBudget.shared(provider: .gemini, model: model, apiKey: "free-key-one"))
        XCTAssertFalse(free === RequestBudget.shared(provider: .gemini, model: model, apiKey: "free-key-two"))
        let paid = RequestBudget.shared(provider: .gemini, model: model, apiKey: "paid-key", paidTier: true)
        XCTAssertNotNil(paid)
        XCTAssertFalse(paid === RequestBudget.shared(provider: .gemini, model: model, apiKey: "paid-key"))
        XCTAssertEqual(paid?.perMinute, Int.max)
        paid?.lower(to: 7) // the provider's actual 429 limit still applies
        XCTAssertEqual(paid?.perMinute, 7)
        XCTAssertTrue(paid === RequestBudget.shared(provider: .gemini, model: model, apiKey: "paid-key", paidTier: true))
    }

    /// Kayan bir dakikalık pencere: hak bitince istek verilmez, en eski istek pencereden çıkınca yeniden verilir.
    func testRequestBudgetSlidingWindow() {
        var time = Date(timeIntervalSince1970: 1000)
        let budget = RequestBudget(perMinute: 3) { time }
        XCTAssertTrue(budget.take())
        time += 20
        XCTAssertTrue(budget.take())
        XCTAssertTrue(budget.take())
        XCTAssertFalse(budget.take())
        time += 39
        XCTAssertFalse(budget.take())
        time += 1  // ilk istek 60 sn önceydi
        XCTAssertTrue(budget.take())
        XCTAssertFalse(budget.take())
        budget.lower(to: 1)
        XCTAssertEqual(budget.perMinute, 1)
        budget.lower(to: 50)  // yükseltmez
        XCTAssertEqual(budget.perMinute, 1)
        budget.lower(to: 0)
        XCTAssertEqual(budget.perMinute, 1)
    }

    /// Hak bitince istek gönderilmez, satır yerel çeviriyle gelir; hata bildirilmez, önbellekteki satır yine gelir.
    func testOverBudgetFallsBackSilently() async throws {
        let translator = make(.gemini, budget: RequestBudget(perMinute: 1))
        var reported: [AIFailure?] = []
        translator.onFailureChanged = { reported.append($0) }
        let first = try await translator.translate("Run!", fallback: local)
        XCTAssertFalse(translator.lastLineWasRateLimited)
        let second = try await translator.translate("Hide!", fallback: local)
        XCTAssertEqual(first, "[tr] Run!")
        XCTAssertEqual(second, "yerel: Hide!")
        XCTAssertTrue(translator.lastLineWasRateLimited)
        XCTAssertEqual(FakeAI.requests.count, 1)
        XCTAssertNil(translator.lastFailure)
        XCTAssertTrue(reported.isEmpty)
        // Önbellekteki satır hak harcamadan gelir.
        let again = try await translator.translate("Run!", fallback: local)
        XCTAssertEqual(again, "[tr] Run!")
        XCTAssertEqual(FakeAI.requests.count, 1)
    }

    /// Bir altyazının bütün cümleleri tek istekle gider; hak cümle başına değil istek başına sayılır.
    func testWholeSubtitleUsesOneRequestOfTheBudget() async throws {
        let translator = make(.gemini, budget: RequestBudget(perMinute: 1))
        let result = try await translator.translate("We go now. Stay close. Run!", fallback: local)
        XCTAssertEqual(result, "[tr] We go now. [tr] Stay close. [tr] Run!")
        XCTAssertEqual(FakeAI.requests.count, 1)
    }

    /// Dakikalık 429: uyarı çıkmaz, kısa beklenir, bildirilen daha düşük sınıra inilir.
    func testPerMinuteRateLimitIsSilentAndLowersTheBudget() async throws {
        FakeAI.failure = (429, rateLimitBody(quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"))
        let budget = RequestBudget(perMinute: 15)
        let translator = make(.gemini, budget: budget)
        var reported: [AIFailure?] = []
        translator.onFailureChanged = { reported.append($0) }
        let first = try await translator.translate("Run!", fallback: local)
        let second = try await translator.translate("Hide!", fallback: local)
        XCTAssertEqual(first, "yerel: Run!")
        XCTAssertEqual(second, "yerel: Hide!")
        XCTAssertEqual(FakeAI.requests.count, 1)
        XCTAssertNil(translator.lastFailure)
        XCTAssertTrue(reported.isEmpty)
        XCTAssertTrue(translator.lastLineWasRateLimited)
        XCTAssertEqual(budget.perMinute, 5)
    }

    /// Günlük sınır dolunca kullanıcıya söylenir (dakikalık beklemeyle geçmez).
    func testPerDayLimitIsReported() async throws {
        FakeAI.failure = (429, rateLimitBody(quotaId: "GenerateRequestsPerDayPerProjectPerModel-FreeTier", value: "1000"))
        let translator = make(.gemini)
        var reported: [AIFailure?] = []
        translator.onFailureChanged = { reported.append($0) }
        _ = try await translator.translate("Run!", fallback: local)
        XCTAssertEqual(reported, [.quotaExceeded])
    }

    func testRateLimitParsing() {
        let minute = AIRequest.rateLimit(status: 429, body: Data(rateLimitBody(quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier",
                                                                              value: "10", delay: "37.5s").utf8))
        XCTAssertEqual(minute, AIRateLimit(retryAfter: 37.5, requestsPerMinute: 10))
        // Token sınırı da dakikalıktır ama istek sınırını bildirmez.
        let tokens = AIRequest.rateLimit(status: 429, body: Data(rateLimitBody(quotaId: "GenerateContentInputTokensPerModelPerMinute-FreeTier",
                                                                              value: "250000").utf8))
        XCTAssertEqual(tokens, AIRateLimit(retryAfter: 3, requestsPerMinute: nil))
        XCTAssertNil(AIRequest.rateLimit(status: 429, body: Data(rateLimitBody(quotaId: "GenerateRequestsPerDayPerProjectPerModel-FreeTier").utf8)))
        XCTAssertNil(AIRequest.rateLimit(status: 429, body: Data(#"{"error":{"message":"quota"}}"#.utf8)))
        XCTAssertNil(AIRequest.rateLimit(status: 400, body: Data(rateLimitBody(quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier").utf8)))
        XCTAssertNil(AIRequest.rateLimit(status: 429, body: Data()))
        // Ayrıntısız 429 eskisi gibi kota hatasıdır.
        XCTAssertEqual(AIRequest.failure(status: 429, body: Data()), .quotaExceeded)
    }

    /// "Dene" dakikalık sınıra takılırsa anahtar geçerlidir, hizmet şu an yoğundur (kaydedilir); "bakiye kalmadı" denmez.
    /// Günlük sınır ise kota hatasıdır.
    func testTestReportsRateLimitAsBusy() async {
        FakeAI.failure = (429, rateLimitBody(quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"))
        let result = await AITranslationCore.test(provider: .gemini, key: secret, model: nil, session: FakeAI.session())
        XCTAssertEqual(result, .failure(.busy))

        FakeAI.failure = (429, rateLimitBody(quotaId: "GenerateRequestsPerDayPerProjectPerModel-FreeTier"))
        let daily = await AITranslationCore.test(provider: .gemini, key: secret, model: nil, session: FakeAI.session())
        XCTAssertEqual(daily, .failure(.quotaExceeded))
    }

    /// "Dene"de Gemini'nin 503 "overloaded" yanıtı yoğunluktur, internet hatası değildir.
    func testTestReportsOverloadAsBusy() async {
        FakeAI.failure = (503, #"{"error":{"code":503,"message":"The model is overloaded. Please try again later.","status":"UNAVAILABLE"}}"#)
        let result = await AITranslationCore.test(provider: .gemini, key: secret, model: nil, session: FakeAI.session())
        XCTAssertEqual(result, .failure(.busy))
    }

    // MARK: - Önbellek

    /// Önceki oturumda çevrilen satır ve cümleler hizmete hiç gitmez; yalnız yeni cümle gönderilir.
    func testPersistentCacheAcrossSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("couchsubs-ai-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.jsonl")
        _ = try await make(.openAI, cache: TranslationCache(file: file)).translate("KRATOS: We go now. Stay close.", fallback: local)
        FakeAI.requests = []

        let translator = make(.openAI, cache: TranslationCache(file: file))
        let again = try await translator.translate("KRATOS: We go now. Stay close.", fallback: local)
        XCTAssertEqual(again, "KRATOS: [tr] We go now. [tr] Stay close.")
        XCTAssertTrue(FakeAI.requests.isEmpty)
        let mixed = try await translator.translate("Stay close. Run!", fallback: local)
        XCTAssertEqual(mixed, "[tr] Stay close. [tr] Run!")
        XCTAssertEqual(FakeAI.requests.count, 1)
        XCTAssertTrue(user(0).hasSuffix("[\"Run!\"]"))
    }

    // MARK: - Deneme ve anahtarın gizliliği

    func testTestTranslatesTheSample() async {
        let result = await AITranslationCore.test(provider: .gemini, key: secret, model: nil, session: FakeAI.session())
        XCTAssertEqual(result, .success("KRATOS: [tr] We go now. [tr] Stay close, boy."))
    }

    /// Yapıştırırken araya giren görünmez karakterler (BOM, sıfır genişlikli boşluk, satır sonu, bölünmez boşluk, araya
    /// giren boşluk, yumuşak tire) her yerden silinip gönderilir; geriye görünür ASCII dışında karakter kalırsa istek hiç
    /// gönderilmez (Windows ve Android ile aynı kural).
    func testTestCleansInvisibleCharactersFromKey() async {
        let key = "AIzaSyFAKE-test_key_0123456789abcdefghij"
        let head = { (count: Int) in String(key.prefix(count)) }
        let tail = { (count: Int) in String(key.dropFirst(count)) }
        let pasted = ["\u{FEFF}\(key)\n", head(20) + "\u{200B}" + tail(20), head(10) + " " + tail(10),
                      head(10) + "\n" + tail(10), "\u{00A0}\(key)\u{200E}", head(5) + "\u{00AD}" + tail(5)]
        for typed in pasted {
            let result = await AITranslationCore.test(provider: .gemini, key: typed, model: nil, session: FakeAI.session())
            XCTAssertEqual(result, .success("KRATOS: [tr] We go now. [tr] Stay close, boy."))
        }
        XCTAssertEqual(FakeAI.requests.map { $0.request.value(forHTTPHeaderField: "x-goog-api-key") }, Array(repeating: key, count: pasted.count))

        FakeAI.requests = []
        let accented = await AITranslationCore.test(provider: .gemini, key: key.replacingOccurrences(of: "a", with: "á"), model: nil,
                                                    session: FakeAI.session())
        XCTAssertEqual(accented, .failure(.invalidKey))
        let blank = await AITranslationCore.test(provider: .gemini, key: "\u{200B} \n", model: nil, session: FakeAI.session())
        XCTAssertEqual(blank, .failure(.invalidKey))
        XCTAssertTrue(FakeAI.requests.isEmpty)
    }

    /// Anahtar hiçbir hata metninde ya da durumda görünmez.
    func testKeyNeverAppearsInErrors() async {
        FakeAI.failure = (401, #"{"error":{"message":"Incorrect API key provided: \#(secret)"}}"#)
        for provider in AIProvider.allCases {
            let result = await AITranslationCore.test(provider: provider, key: secret, model: nil, session: FakeAI.session())
            XCTAssertEqual(result, .failure(.invalidKey))
            if case .failure(let error) = result {
                XCTAssertFalse(String(describing: error).contains(secret))
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }
        FakeAI.failure = nil
        FakeAI.timeout = true
        let result = await AITranslationCore.test(provider: .openAI, key: secret, model: nil, session: FakeAI.session())
        XCTAssertEqual(result, .failure(.busy))
        let empty = await AITranslationCore.test(provider: .claude, key: "  ", model: nil, session: FakeAI.session())
        XCTAssertEqual(empty, .failure(.invalidKey))
    }

    // MARK: - Ekranı çevir

    /// Ücretsiz çeviri kurulu değil: yerel çeviriye düşen satır hata verir (Mac'te dil paketi, Windows'ta model yok).
    private struct MissingFree: TextTranslator {
        func translate(_ text: String) async throws -> String { throw TranslatorError.needsDownload }
    }

    /// Birbirine benzemeyen yazılar (benzer satırları yazı tanıma çöpü sayan süzgece takılmasın).
    private static let screenTexts = [
        "Find the blacksmith.", "Open the world map", "Collect three iron bars", "Talk to the old hunter", "Leave the camp quietly",
        "Upgrade your shield", "Rest at the campfire", "Follow the river north", "Climb the broken tower", "Defeat the wolf pack",
        "Search the abandoned mine", "Light the signal fire", "Cross the frozen lake", "Return to the village", "Repair the bridge",
        "Escort the merchant safely", "Hunt a wild boar", "Read the ancient runes", "Unlock the hidden vault", "Sharpen your axe",
    ]

    private func screen(_ count: Int) -> Reading {
        Reading(lines: (0..<count).map { index in
            // İki sütun, satırlar arası boşluk geniş: her satır ayrı grup.
            let top = 0.02 + Double(index / 2) * 0.09, left = index % 2 == 0 ? 0.05 : 0.55
            return TextLine(Self.screenTexts[index], box: TextBox(left: left, top: top, right: left + 0.35, bottom: top + 0.03))
        })
    }

    /// Bildirilen hata (Gemini seçiliyken "Ekranı çevir" hiçbir şey göstermiyordu): parça başına istek gidince 20 satırlık
    /// ekran dakikada 15 isteklik hakkı bitiriyor, yerel çeviri kurulu değilse bütün ekran hata veriyordu. Yerel çeviri
    /// yokken hak artık satırı düşürmez; istek yine gönderilir (429 gelirse hizmetin beklemesi uygulanır).
    func testScreenOneRequestPerParagraphWithoutLocalStillSendsEveryParagraph() async throws {
        let budget = RequestBudget(perMinute: 15)
        let translator = AITranslator(provider: .gemini, key: secret, model: nil, fallback: MissingFree(), session: FakeAI.session(),
                                      budget: budget)
        for text in Self.screenTexts {
            let translated = try await translator.translate(text)
            XCTAssertEqual(translated, "[tr] " + text)
        }
        XCTAssertEqual(FakeAI.requests.count, Self.screenTexts.count)
    }

    /// Düzeltme: ekranın bütün parçaları tek istekte gider ve hepsi çevrilir; canlı altyazı dakikalık hakkı bitirmiş olsa da.
    func testScreenIsTranslatedInOneRequestEvenWhenTheBudgetIsUsedUp() async throws {
        let budget = RequestBudget(perMinute: 15)
        for _ in 0..<15 { XCTAssertTrue(budget.take()) }
        let translator = AITranslator(provider: .gemini, key: secret, model: nil, fallback: MissingFree(), session: FakeAI.session(),
                                      budget: budget)
        var reported: [Int] = []
        let items = try await ScreenTranslation.translate(screen(20), using: translator) { reported.append($0.count) }
        XCTAssertEqual(FakeAI.requests.count, 1)
        XCTAssertEqual(items.count, 20)
        XCTAssertEqual(Set(items.map(\.translation)), Set(Self.screenTexts.map { "[tr] " + $0 }))
        XCTAssertEqual(reported, [20])
        let config = FakeAI.requests[0].body["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["maxOutputTokens"] as? Int, AIRequest.screenOutputTokens)
        // Çevrilenler önbelleğe girer: yeniden basınca istek gitmez.
        _ = try await ScreenTranslation.translate(screen(20), using: translator)
        XCTAssertEqual(FakeAI.requests.count, 1)
    }

    /// Kalabalık ekran birkaç isteğe bölünür; sıra korunur.
    func testCrowdedScreenIsSplitIntoBatches() async throws {
        let core = make(.gemini)
        let texts = (0..<(AITranslationCore.screenBatch + 5)).map { "Line \($0) of the menu" }
        let result = try await core.translateAll(texts, fallback: local)
        XCTAssertEqual(FakeAI.requests.count, 2)
        XCTAssertEqual(result, texts.map { "[tr] " + $0 })
    }

    /// Hizmet çeviremezse parçalar yerel çeviriyle gelir ve hata bildirilir; yerel çeviri de yoksa hata yukarı çıkar.
    func testScreenFailureFallsBackOrThrows() async throws {
        FakeAI.failure = (500, "{}")
        let core = make(.gemini)
        var reported: [AIFailure?] = []
        core.onFailureChanged = { reported.append($0) }
        let result = try await core.translateAll(["Open the map", "Leave the camp"], fallback: local)
        XCTAssertEqual(result, ["yerel: Open the map", "yerel: Leave the camp"])
        XCTAssertEqual(reported, [.busy])

        let translator = AITranslator(provider: .claude, key: secret, model: nil, fallback: MissingFree(), session: FakeAI.session(),
                                      budget: RequestBudget(perMinute: 1000))
        do {
            _ = try await ScreenTranslation.translate(screen(3), using: translator)
            XCTFail("hata beklenir")
        } catch {
            XCTAssertEqual(error as? TranslatorError, .needsDownload)
            XCTAssertEqual(translator.lastFailure, .busy)
        }
    }

    /// Yanıttaki dizi eksikse parçalar karışmaz: hepsi yerel çeviriye düşer.
    func testScreenReplyWithWrongCountFallsBack() async throws {
        FakeAI.replyText = #"["[tr] bir"]"#
        let result = try await make(.openAI).translateAll(["One thing", "Another thing"], fallback: local)
        XCTAssertEqual(result, ["yerel: One thing", "yerel: Another thing"])
    }

    // --- Yerel çeviri yokken ---

    private struct NoLocal: Error {}
    private func noLocal(_ text: String) async throws -> String { throw NoLocal() }

    /// Dakikalık hak uygulamanın temkinli tahminidir. Yerel çeviri yokken hak bitince satır denenmeden düşüyordu;
    /// ara sahnede satırların yarısı hiç çevrilmiyordu. İstek yine gönderilmeli (Windows ve Android ile aynı).
    func testOverBudgetWithoutLocalStillSendsRequest() async throws {
        let translator = make(.gemini, budget: RequestBudget(perMinute: 1))
        let first = try await translator.translate("Run!", fallback: noLocal)
        let second = try await translator.translate("Hide!", fallback: noLocal)
        XCTAssertEqual([first, second], ["[tr] Run!", "[tr] Hide!"])
        XCTAssertEqual(FakeAI.requests.count, 2)
        XCTAssertFalse(translator.lastLineWasRateLimited)
    }

    /// Hata sonrası bir dakikalık beklemede yerel çeviri yoksa hizmet yine denenir; satır düşmez.
    func testErrorPauseWithoutLocalStillTriesService() async throws {
        let translator = make(.gemini)
        FakeAI.failure = (503, "{}")
        do { _ = try await translator.translate("Run!", fallback: noLocal); XCTFail("yerel çeviri yokken hata beklenirdi") } catch {}
        FakeAI.failure = nil
        let second = try await translator.translate("Hide!", fallback: noLocal)
        XCTAssertEqual(second, "[tr] Hide!")
        XCTAssertEqual(FakeAI.requests.count, 2)
    }

    /// Hizmetin dakikalık 429'undan sonraki kısa bekleme yerel çeviri olmasa da korunur.
    func testPerMinuteRateLimitPauseHoldsWithoutLocal() async throws {
        FakeAI.failure = (429, rateLimitBody(quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"))
        let translator = make(.gemini)
        do { _ = try await translator.translate("Run!", fallback: noLocal); XCTFail("hata beklenirdi") } catch {}
        do { _ = try await translator.translate("Hide!", fallback: noLocal); XCTFail("hata beklenirdi") } catch {}
        XCTAssertEqual(FakeAI.requests.count, 1)
    }
}

private final class GameBox: @unchecked Sendable {
    var value: String?
    var reads = 0
}

extension AITranslationTests {
    /// Ekran çevirisi isteğinde yazı başına karakter bütçesi (özgün uzunluk × 1,15, en az 4); küfür yumuşatılmaz. Windows
    /// AiTranslatorTests ve Android LocalAiTest ile aynı.
    func testScreenRequestCarriesCharacterBudget() {
        XCTAssertEqual(AIRequest.screenLimits(["MAP", "SET DESTINATION", "Keep an eye on the party."]), [4, 18, 29])
        let message = AIRequest.userMessage(sentences: ["MAP", "SET DESTINATION"], context: [], limits: [4, 18])
        XCTAssertTrue(message.contains(AIRequest.limitsNote + "\n[4,18]"))
        XCTAssertTrue(AIRequest.limitsNote.contains("never censor or soften profanity"))
        XCTAssertFalse(AIRequest.userMessage(sentences: ["MAP"], context: []).contains(AIRequest.limitsNote))
    }
}
