// NotionClient.swift – V1-05 Notion REST API Client
// KeeprBridge · Notion
//
// Actor-based HTTP client with:
// - Rate limiting at 3 req/sec (token bucket)
// - Exponential backoff on 429 / transient errors
// - Max 3 retries per request

import Foundation

// MARK: - NotionClient Actor

/// Thread-safe Notion REST API client with rate limiting and retry logic.
public actor NotionClient {

    private let apiKey: String
    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"
    private let maxRequestsPerSecond: Double = 3.0
    private let maxRetries = 3
    private var lastRequestTime: ContinuousClock.Instant?
    private let session: URLSession

    /// Initialize with a Notion integration API key.
    /// Reads from NOTION_API_KEY environment variable if not provided.
    public init(apiKey: String? = nil) throws {
        if let key = apiKey {
            self.apiKey = key
        } else if let envKey = ProcessInfo.processInfo.environment["NOTION_API_KEY"] {
            self.apiKey = envKey
        } else {
            throw NotionClientError.missingAPIKey
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Rate Limiting

    /// Enforce rate limit: sleep if needed to stay under 3 req/sec.
    private func rateLimit() async {
        if let last = lastRequestTime {
            let minInterval = Duration.milliseconds(Int(1000.0 / maxRequestsPerSecond))
            let elapsed = ContinuousClock.now - last
            if elapsed < minInterval {
                try? await Task.sleep(for: minInterval - elapsed)
            }
        }
        lastRequestTime = .now
    }

    // MARK: - Core Request

    /// Execute an HTTP request with rate limiting and exponential backoff.
    private func request(
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            await rateLimit()

            guard let url = URL(string: baseURL + path) else {
                throw NotionClientError.invalidResponse
            }

            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body = body { req.httpBody = body }

            do {
                let (data, response) = try await session.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NotionClientError.invalidResponse
                }

                // Rate limited — exponential backoff
                if httpResponse.statusCode == 429 {
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    let delay: Double
                    if let retrySeconds = retryAfter.flatMap({ Double($0) }) {
                        delay = retrySeconds
                    } else {
                        delay = Double(1 << attempt) * 0.5
                    }
                    try await Task.sleep(for: .seconds(delay))
                    lastError = NotionClientError.httpError(429, "Rate limited")
                    continue
                }

                // Server errors — retry with backoff
                if httpResponse.statusCode >= 500 {
                    let delay = Double(1 << attempt) * 0.5
                    try await Task.sleep(for: .seconds(delay))
                    let body = String(data: data, encoding: .utf8) ?? ""
                    lastError = NotionClientError.httpError(httpResponse.statusCode, body)
                    continue
                }

                return (data, httpResponse)
            } catch let error as NotionClientError {
                throw error
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    let delay = Double(1 << attempt) * 0.5
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw lastError ?? NotionClientError.maxRetriesExceeded
    }

    // MARK: - API Methods

    /// Search Notion workspace.
    public func search(query: String, pageSize: Int = 10) async throws -> Data {
        let body: [String: Any] = ["query": query, "page_size": pageSize]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await request(method: "POST", path: "/search", body: bodyData)
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// Retrieve a page by ID.
    public func getPage(pageId: String) async throws -> Data {
        let cleanId = pageId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(method: "GET", path: "/pages/\(cleanId)")
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// Retrieve child blocks of a page or block.
    public func getBlocks(blockId: String, pageSize: Int = 100) async throws -> Data {
        let cleanId = blockId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(
            method: "GET",
            path: "/blocks/\(cleanId)/children?page_size=\(pageSize)"
        )
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }

    /// Update page properties.
    public func updatePage(pageId: String, properties: Data) async throws -> Data {
        let cleanId = pageId.replacingOccurrences(of: "-", with: "")
        let (data, response) = try await request(
            method: "PATCH",
            path: "/pages/\(cleanId)",
            body: properties
        )
        guard (200...299).contains(response.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NotionClientError.httpError(response.statusCode, msg)
        }
        return data
    }
}
