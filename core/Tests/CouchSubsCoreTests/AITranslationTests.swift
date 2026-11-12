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
        if Self.timeout {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let status = Self.failure?.status ?? 200
        let reply: Data
        if let failure = Self.failure {
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

/// Windows'taki AiTranslatorTests ile aynı durumlar.
final class AITranslationTests: XCTestCase {
    private let secret = "sk-SECRET-123"

    override func setUp() {
        FakeAI.requests = []
        FakeAI.failure = nil
        FakeAI.timeout = false
        FakeAI.replyText = nil
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
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        // Anahtar boşsa Authorization başlığı hiç gitmez.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(body["model"] as? String, "qwen2.5:7b")
        XCTAssertEqual(body["temperature"] as? Double, AIRequest.localTemperature)
        XCTAssertEqual(body["max_tokens"] as? Int, AIRequest.maxOutputTokens)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "temperature", "max_tokens", "stream"])
        let messages = body["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages[0]["content"] as? String, AIRequest.systemPrompt)
        XCTAssertTrue(user(0).hasSuffix("[\"We go now.\"]"))
    }

    /// LM Studio adresi ve isteğe bağlı anahtar (yalnız doluysa Bearer olarak gider).
    func testLocalRequestWithKeyAndLMStudio() async throws {
        _ = try await makeLocal(LocalAIServer.lmStudioURL, model: "qwen2.5-7b-instruct", key: " lm-key ").translate("Run!", fallback: local)
        let (request, body) = FakeAI.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:1234/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer lm-key")
        XCTAssertEqual(body["model"] as? String, "qwen2.5-7b-instruct")
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
        XCTAssertEqual(ollama.engineID, "local:localhost:11434/qwen2.5:7b")
        XCTAssertEqual(LocalAIServer(baseURL: "http://LOCALHOST:11434/v1/", model: "qwen2.5:7b")!.engineID, ollama.engineID)
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

    /// Sunucu kapalıysa ya da model indirilmemişse o satır ücretsiz çeviriyle gelir, durum bildirilir.
    func testLocalFailuresFallBack() async throws {
        FakeAI.timeout = true
        let down = makeLocal()
        let first = try await down.translate("Run!", fallback: local)
        XCTAssertEqual(first, "yerel: Run!")
        XCTAssertEqual(down.lastFailure, .unreachable)

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
        XCTAssertEqual(down, .failure(.unreachable))
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
        XCTAssertEqual(AIRequest.failure(status: 529, body: empty), .unreachable)
        XCTAssertEqual(AIRequest.failure(status: 500, body: empty), .unreachable)
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

    func testTimeoutFallsBack() async throws {
        FakeAI.timeout = true
        let translator = make(.claude)
        let result = try await translator.translate("Run!", fallback: local)
        XCTAssertEqual(result, "yerel: Run!")
        XCTAssertEqual(translator.lastFailure, .unreachable)
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

    /// "Kaydet ve dene" dakikalık sınıra takılırsa anahtar geçerlidir ama sınırdadır (kaydedilir).
    func testTestReportsRateLimitAsQuota() async {
        FakeAI.failure = (429, rateLimitBody(quotaId: "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"))
        let result = await AITranslationCore.test(provider: .gemini, key: secret, model: nil, session: FakeAI.session())
        XCTAssertEqual(result, .failure(.quotaExceeded))
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
        XCTAssertEqual(result, .failure(.unreachable))
        let empty = await AITranslationCore.test(provider: .claude, key: "  ", model: nil, session: FakeAI.session())
        XCTAssertEqual(empty, .failure(.invalidKey))
    }
}
