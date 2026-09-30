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
        guard case .rateLimited(let retry) = classify(429, body, retryAfter: "7") else { return XCTFail("expected rateLimited") }
        XCTAssertEqual(retry, 7)
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
}
