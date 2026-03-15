// NotionClient.swift – V1-05 → V1-12 → V1-FIX Notion REST API Client
// NotionGate · Notion
//
// Actor-based HTTP client with:
// - Rate limiting at 3 req/sec (token bucket)
// - Exponential backoff on 429 / transient errors
// - Max 3 retries per request
// - Token resolution: NOTION_API_TOKEN env var → config file fallback
// PKT-320: Updated env var to NOTION_API_TOKEN, added config file fallback,
//          added validate() method for startup health check
// PKT-332: Added verbose diagnostic logging to token resolver for cold-boot debugging

import Foundation

// MARK: - Token Resolution

/// Resolves the Notion API token from environment or config file.
/// Priority: NOTION_API_TOKEN env var → NOTION_API_KEY env var (legacy) → config file
public enum NotionTokenResolver {

    /// Status of the Notion API token.
    public enum TokenStatus: Sendable {
        case available(source: String)
        case missing
    }

    /// Config file path: ~/.config/notion-gate/config.json
    public static let configFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.config/notion-gate/config.json"
        print("[TokenResolver] Config file path resolved: \(path)")
        return path
    }()

    /// Resolve the API token from all sources.
    /// Priority: NOTION_API_TOKEN env → NOTION_API_KEY env (legacy) → config file
    public static func resolve() -> (token: String, source: String)? {
        print("[TokenResolver] Starting token resolution...")

        // 1. NOTION_API_TOKEN environment variable (primary)
        if let token = ProcessInfo.processInfo.environment["NOTION_API_TOKEN"],
           !token.isEmpty {
            print("[TokenResolver] ✅ Found token via env:NOTION_API_TOKEN")
            return (token, "env:NOTION_API_TOKEN")
        }
        print("[TokenResolver] env:NOTION_API_TOKEN — not set or empty")

        // 2. NOTION_API_KEY environment variable (legacy/backward compat)
        if let token = ProcessInfo.processInfo.environment["NOTION_API_KEY"],
           !token.isEmpty {
            print("[TokenResolver] ✅ Found token via env:NOTION_API_KEY (legacy)")
            return (token, "env:NOTION_API_KEY")
        }
        print("[TokenResolver] env:NOTION_API_KEY — not set or empty")

        // 3. Config file fallback: ~/.config/notion-gate/config.json
        print("[TokenResolver] Trying config file fallback...")
        if let token = readFromConfigFile() {
            print("[TokenResolver] ✅ Found token via config file")
            return (token, "config:\(configFilePath)")
        }
        print("[TokenResolver] ❌ All 3 sources exhausted — token not found")

        return nil
    }

    /// Check token availability without resolving the full token.
    public static func checkStatus() -> TokenStatus {
        if let result = resolve() {
            return .available(source: result.source)
        }
        return .missing
    }

    /// Read token from config file.
    /// Expected format: { "notion_api_token": "ntn_..." }
    private static func readFromConfigFile() -> String? {
        let path = configFilePath

        // Step 1: Check file exists
        guard FileManager.default.fileExists(atPath: path) else {
            print("[TokenResolver] Config file does not exist at: \(path)")
            return nil
        }
        print("[TokenResolver] Config file exists at: \(path)")

        // Step 2: Read file contents
        guard let data = FileManager.default.contents(atPath: path) else {
            print("[TokenResolver] Config file exists but FileManager.contents() returned nil — possible permission issue")
            return nil
        }
        print("[TokenResolver] Config file read: \(data.count) bytes")

        // Step 3: Parse JSON
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let rawContent = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            print("[TokenResolver] Config file JSON parse failed. Raw content: \(rawContent.prefix(200))")
            return nil
        }
        print("[TokenResolver] Config file parsed — keys: \(json.keys.sorted())")

        // Step 4: Check both key names
        if let token = json["notion_api_token"] as? String, !token.isEmpty {
            print("[TokenResolver] Key 'notion_api_token' found — token length: \(token.count)")
            return token
        }
        if let token = json["notion_api_key"] as? String, !token.isEmpty {
            print("[TokenResolver] Key 'notion_api_key' found (legacy) — token length: \(token.count)")
            return token
        }

        print("[TokenResolver] Config file has no 'notion_api_token' or 'notion_api_key' key, or value is empty. Available keys: \(json.keys.sorted())")
        return nil
    }
}

// MARK: - NotionClient Actor

/// Thread-safe Notion REST API client with rate limiting and retry logic.
public actor NotionClient {

    private let apiKey: String
    private let tokenSource: String
    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"
    private let maxRequestsPerSecond: Double = 3.0
    private let maxRetries = 3
    private var lastRequestTime: ContinuousClock.Instant?
    private let session: URLSession

    /// Initialize with a Notion integration API key.
    /// Resolution order: explicit parameter → NOTION_API_TOKEN env → NOTION_API_KEY env → config file
    public init(apiKey: String? = nil) throws {
        if let key = apiKey, !key.isEmpty {
            self.apiKey = key
            self.tokenSource = "explicit"
        } else if let resolved = NotionTokenResolver.resolve() {
            self.apiKey = resolved.token
            self.tokenSource = resolved.source
        } else {
            throw NotionClientError.missingAPIKey
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        print("[NotionClient] Initialized — token source: \(tokenSource)")
    }

    /// Returns the source of the resolved token (for diagnostics).
    public func getTokenSource() -> String {
        return tokenSource
    }

    // MARK: - Validation

    /// Validate the token by making a lightweight API call (search with empty query, 1 result).
    /// Returns true if the API responds with 200, false otherwise.
    public func validate() async -> (success: Bool, message: String) {
        do {
            let body: [String: Any] = ["query": "", "page_size": 1]
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await request(method: "POST", path: "/search", body: bodyData)
            if (200...299).contains(response.statusCode) {
                return (true, "Connected (token source: \(tokenSource))")
            } else {
                return (false, "HTTP \(response.statusCode)")
            }
        } catch {
            return (false, error.localizedDescription)
        }
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
