import XCTest
@testable import IysCodeMovilCore

final class ProviderErrorTests: XCTestCase {
    private func classify(_ status: Int, _ body: String, retryAfter: String? = nil, provider: String = "OpenAI API") -> ModelProviderError {
        RemoteModelProvider.classifyHTTPError(status: status, retryAfter: retryAfter, body: Data(body.utf8), provider: provider)
    }

    func testOpenAIInsufficientQuotaIsNotARateLimit() {
        let body = #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#
        guard case .quotaExceeded(let provider, let detail) = classify(429, body) else { return XCTFail("expected quotaExceeded") }
        XCTAssertEqual(provider, "OpenAI API")
        XCTAssertTrue(detail?.contains("current quota") ?? false)
        let text = classify(429, body).localizedDescription
        XCTAssertTrue(text.contains("ChatGPT Plus"), "OpenAI users are told the subscription is not API credit")
        XCTAssertFalse(text.contains("limitó las solicitudes"))
    }

    func testRealRateLimitKeepsRetryAfter() {
        let body = #"{"error":{"message":"Rate limit reached for requests","type":"requests","code":"rate_limit_exceeded"}}"#
        guard case .rateLimited(let retry, let detail) = classify(429, body, retryAfter: "7") else { return XCTFail("expected rateLimited") }
        XCTAssertEqual(retry, 7)
        XCTAssertEqual(detail, "Rate limit reached for requests")
        XCTAssertTrue(classify(429, body).localizedDescription.contains("Rate limit reached"), "the provider's own sentence is shown")
    }

    func testOpenRouterPaymentRequiredAndGeminiArrayFormat() {
        guard case .quotaExceeded = classify(402, #"{"error":{"message":"Insufficient credits","code":402}}"#, provider: "OpenRouter") else {
            return XCTFail("402 is a billing problem")
        }
        let gemini = #"[{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED"}}]"#
        guard case .quotaExceeded = classify(429, gemini, provider: "Google Gemini") else { return XCTFail("Gemini quota body") }
        let geminiPerMinute = #"[{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}]"#
        guard case .rateLimited = classify(429, geminiPerMinute, provider: "Google Gemini") else { return XCTFail("per-minute limit") }
    }

    func testOtherErrorsCarryTheProviderMessage() {
        guard case .authenticationFailed = classify(401, #"{"error":{"message":"Incorrect API key provided"}}"#) else { return XCTFail() }
        guard case .modelNotFound(let m) = classify(404, #"{"error":{"message":"The model `gpt-9` does not exist","code":"model_not_found"}}"#) else { return XCTFail() }
        XCTAssertTrue(m.contains("gpt-9"))
        guard case .invalidRequest(let r) = classify(400, #"{"error":{"message":"max_tokens is too large"}}"#) else { return XCTFail() }
        XCTAssertTrue(r.contains("max_tokens"))
        guard case .networkError(let n) = classify(503, "upstream unavailable") else { return XCTFail() }
        XCTAssertTrue(n.contains("upstream unavailable"))
    }

    func testRequestLargerThanTheTokenLimitIsNotAWait() {
        let tpm = #"{"error":{"message":"Request too large for gpt-4o in organization org-x on tokens per min (TPM): Limit 30000, Requested 45210.","type":"tokens","param":null,"code":"rate_limit_exceeded"}}"#
        guard case .requestTooLarge(_, let detail) = classify(429, tpm) else { return XCTFail("expected requestTooLarge") }
        XCTAssertTrue(detail?.contains("Requested 45210") ?? false)
        XCTAssertNil(RemoteModelProvider.retryDelay(after: classify(429, tpm), attempt: 0), "retrying the same request cannot help")
        let context = #"{"error":{"message":"This model's maximum context length is 128000 tokens.","code":"context_length_exceeded"}}"#
        guard case .requestTooLarge = classify(400, context) else { return XCTFail("context overflow") }
        guard case .requestTooLarge = classify(413, "payload too large") else { return XCTFail("413") }
    }

    func testTransientErrorsAreRetriedWithBackoff() {
        let limited = ModelProviderError.rateLimited(retryAfter: nil, detail: nil)
        XCTAssertNotNil(RemoteModelProvider.retryDelay(after: limited, attempt: 0))
        XCTAssertNil(RemoteModelProvider.retryDelay(after: limited, attempt: RemoteModelProvider.maxRetries))
        XCTAssertEqual(RemoteModelProvider.retryDelay(after: .rateLimited(retryAfter: 3, detail: nil), attempt: 1), 3)
        XCTAssertNil(RemoteModelProvider.retryDelay(after: .rateLimited(retryAfter: 600, detail: nil), attempt: 0),
                     "a long Retry-After is reported, not silently waited out")
        XCTAssertNotNil(RemoteModelProvider.retryDelay(after: classify(503, "upstream unavailable"), attempt: 0))
        XCTAssertNil(RemoteModelProvider.retryDelay(after: .authenticationFailed, attempt: 0))
        XCTAssertNil(RemoteModelProvider.retryDelay(after: .quotaExceeded(provider: "OpenAI API", detail: nil), attempt: 0))
        XCTAssertNil(RemoteModelProvider.retryDelay(after: classify(400, #"{"error":{"message":"bad"}}"#), attempt: 0))
    }

    func testOpenAIReasoningModelsAreDetected() {
        for id in ["o1", "o3-mini", "o4-mini", "gpt-5", "gpt-5-mini", "openai/o3"] {
            XCTAssertTrue(RemoteModelProvider.isOpenAIReasoningModel(id), id)
        }
        for id in ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-5-chat-latest", "openai/gpt-oss-20b"] {
            XCTAssertFalse(RemoteModelProvider.isOpenAIReasoningModel(id), id)
        }
    }

    func testToolArgumentsKeepBooleansAndNestedJSON() {
        let args = ToolArgumentDecoding.flatten(#"{"path":"src","recursive":true,"hidden":false,"depth":2,"ratio":1.5,"tags":["a","b"],"none":null}"#)
        XCTAssertEqual(args["recursive"], "true", "used to be \"1\", so recursive listings never ran")
        XCTAssertEqual(args["hidden"], "false")
        XCTAssertEqual(args["depth"], "2")
        XCTAssertEqual(args["ratio"], "1.5")
        XCTAssertEqual(args["tags"], #"["a","b"]"#)
        XCTAssertEqual(args["none"], "")
        XCTAssertEqual(ToolArgumentDecoding.flatten("not json"), [:])
    }
}
