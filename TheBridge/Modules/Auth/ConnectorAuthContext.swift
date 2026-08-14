// ConnectorAuthContext.swift — WS-F S2 (PKT-800)
// TheBridge · Modules · Auth
//
// Bundles the bearer validator + scope gate + the RFC 9728 PRM pointer
// for the remote `/mcp` connector path, and owns the *one* place that
// turns a failed bearer check into an RFC 6750 `401 + WWW-Authenticate`
// challenge. This is the additive-isolation boundary object: an
// `SSEServer` holds it as an Optional that is `nil` in every default
// configuration (stdio-only — `BRIDGE_ENABLE_HTTP` unset), so the
// connector-auth code path is provably unreachable for stdio, legacy SSE
// (`/sse`+`/messages`), `/health`, the job callback, and local tool
// dispatch. It is non-nil ONLY when the streamableHTTP transport is gated
// on AND a key set is configured.

import Foundation

/// Connector authentication/authorization bundle for the `/mcp` path.
public struct ConnectorAuthContext: Sendable {
    public let validator: ConnectorBearerValidator
    public let scopeGate: ConnectorScopeGate
    /// WS-F S3: step-up consent on destructive connector tools.
    public let stepUpGate: ConnectorStepUpGate
    /// WS-F S3: confused-deputy isolation — binds the verified principal
    /// to its MCP session and rejects cross-client/token substitution.
    public let sessionBinding: ConnectorSessionBinding
    /// WS-F S3: redaction-asserting connector-auth diagnostics sink. The
    /// only place the connector path emits auth events; every detail is
    /// redacted before storage so the bearer-leak sweep can prove zero
    /// secret occurrences.
    public let diagnostics: ConnectorAuthDiagnostics
    /// Absolute URL of the RFC 9728 Protected Resource Metadata document,
    /// referenced from the `WWW-Authenticate` challenge so a client knows
    /// where to discover the authorization server.
    public let resourceMetadataURL: String

    /// Connector tool-authorization policy. DEFAULT false (2026-07-09, operator
    /// decision, reverting v3.9.8's one-day default) = full parity: an
    /// authenticated connector token may reach every tool, gated only by the
    /// per-tool SecurityGate at dispatch (WorkOS authenticates only the
    /// operator, and AuthKit issues scope-less tokens, so the ConnectorScopeGate
    /// allowlist would otherwise deny most of the catalog). The v3.9.8-era
    /// 36-tool allowlist remains available — pass strictScopes: true — for
    /// anyone who wants it back later, e.g. as a per-client Wave 4 ceiling.
    /// Independent of this flag: ToolRouter's Wave 1 broker (remote
    /// control-plane blocklist for shell/applescript/computer/credential +
    /// config-write tools, and the governed-session requirement for non-open
    /// tools) is origin-based, not scope-based, and stays fully active either
    /// way.
    public let strictScopes: Bool

    public init(
        validator: ConnectorBearerValidator,
        scopeGate: ConnectorScopeGate = ConnectorScopeGate(),
        stepUpGate: ConnectorStepUpGate = ConnectorStepUpGate(),
        sessionBinding: ConnectorSessionBinding = ConnectorSessionBinding(),
        diagnostics: ConnectorAuthDiagnostics = ConnectorAuthDiagnostics(),
        resourceMetadataURL: String,
        strictScopes: Bool = false
    ) {
        self.validator = validator
        self.scopeGate = scopeGate
        self.stepUpGate = stepUpGate
        self.sessionBinding = sessionBinding
        self.diagnostics = diagnostics
        self.resourceMetadataURL = resourceMetadataURL
        self.strictScopes = strictScopes
    }

    /// Coarse RFC 6750 challenge for tunnel callers. Detailed failure reasons
    /// stay in `TunnelAuthFailureAudit`; the public challenge intentionally
    /// does not distinguish expiration, issuer/audience, inactive OAuth, or
    /// revoked/absent credentials.
    public func wwwAuthenticateValue(correlationID: String) -> String {
        "Bearer error=\"invalid_token\", error_description=\"auth_failed\", "
            + "resource_metadata=\"\(resourceMetadataURL)\", "
            + "correlation_id=\"\(correlationID)\""
    }
}

extension BearerValidationError {
    /// Short, header-safe (no CR/LF/`"`) description for the
    /// `error_description` challenge parameter.
    var challengeDescription: String {
        let raw: String
        switch self {
        case .missingBearer: raw = "missing bearer token"
        case .malformedAuthorizationHeader: raw = "malformed Authorization header"
        case .signatureInvalid: raw = "signature verification failed"
        case .issuerMismatch: raw = "issuer not accepted"
        case .audienceMismatch: raw = "audience not accepted"
        case .expired: raw = "token expired"
        case .notYetValid: raw = "token not yet valid"
        case .subjectMissing: raw = "token subject missing"
        case .misconfigured: raw = "connector key set not configured"
        case .malformedToken: raw = "malformed token"
        }
        return raw.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
