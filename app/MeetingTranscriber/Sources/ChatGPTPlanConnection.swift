import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Credentials for the official Sign in with ChatGPT local-app flow. Tokens are
/// stored only in the user's macOS Keychain, never in Sawti's repository or logs.
struct ChatGPTPlanCredentials: Codable, Sendable {
    let clientID: String
    let hostID: String
    let subject: String
    let email: String?
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let scopes: [String]
    let expiresAt: Date

    var permitsPlanUsage: Bool {
        scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke")
    }

    var registration: ChatGPTPlanRegistration {
        ChatGPTPlanRegistration(
            clientID: clientID,
            hostID: hostID,
            subject: subject,
            email: email,
        )
    }

    static func decode(_ value: String) -> Self? {
        guard let data = value.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    func encode() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try String(decoding: encoder.encode(self), as: UTF8.self)
    }
}

/// Retained registration identity lets a user reconnect to the same approved
/// ChatGPT client after signing out, without keeping renewable API credentials.
struct ChatGPTPlanRegistration: Codable, Sendable {
    let clientID: String
    let hostID: String
    let subject: String
    let email: String?
}

struct ChatGPTPlanModel: Decodable, Hashable, Identifiable, Sendable {
    let slug: String
    let displayName: String
    let visibility: String

    var id: String {
        slug
    }

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case visibility
    }
}

/// ChatGPT account credential store. Refresh is single-flight so the live
/// assistant and notes can safely share rotating refresh tokens in parallel.
actor ChatGPTPlanCredentialStore {
    private let keychainAccount: String
    private let registrationAccount: String
    private var cachedCredentials: ChatGPTPlanCredentials?
    private var refreshTask: Task<ChatGPTPlanCredentials, any Error>?
    private var credentialGeneration = 0

    init(keychainAccount: String = "chatGPTPlanCredentials") {
        self.keychainAccount = keychainAccount
        registrationAccount = "\(keychainAccount).registration"
    }

    func validCredentials() async throws -> ChatGPTPlanCredentials {
        let current = cachedCredentials ?? Self.load(keychainAccount: keychainAccount)
        guard let current else { throw ChatGPTPlanError.notConnected }
        guard current.permitsPlanUsage else { throw ChatGPTPlanError.planUsageNotAuthorized }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current }
        let refreshGeneration = credentialGeneration
        if let refreshTask {
            let refreshed = try await refreshTask.value
            guard credentialGeneration == refreshGeneration else { throw ChatGPTPlanError.notConnected }
            return refreshed
        }

        let task = Task { try await ChatGPTPlanOAuth.refresh(current) }
        refreshTask = task
        defer {
            if credentialGeneration == refreshGeneration {
                refreshTask = nil
            }
        }
        let refreshed = try await task.value
        guard credentialGeneration == refreshGeneration else { throw ChatGPTPlanError.notConnected }
        Self.save(refreshed, keychainAccount: keychainAccount)
        cachedCredentials = refreshed
        return refreshed
    }

    func replace(with credentials: ChatGPTPlanCredentials) {
        credentialGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        Self.save(credentials, keychainAccount: keychainAccount)
        Self.saveRegistration(credentials.registration, keychainAccount: registrationAccount)
        cachedCredentials = credentials
    }

    func registeredAccount() -> ChatGPTPlanRegistration? {
        Self.loadRegistration(keychainAccount: registrationAccount)
    }

    func clear() {
        credentialGeneration += 1
        KeychainHelper.delete(key: keychainAccount)
        cachedCredentials = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func models() async throws -> [ChatGPTPlanModel] {
        let credentials = try await validCredentials()
        guard let endpoint = URL(string: "https://api.openai.com/v1/models") else {
            throw ChatGPTPlanError.modelListUnavailable
        }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200 ... 299).contains(response.statusCode) else {
            throw ChatGPTPlanError.modelListUnavailable
        }
        let result = try JSONDecoder().decode(ModelList.self, from: data)
        return result.models.filter { $0.visibility == "list" }
    }

    static func load(keychainAccount: String) -> ChatGPTPlanCredentials? {
        ChatGPTPlanCredentials.decode(KeychainHelper.read(key: keychainAccount) ?? "")
    }

    static func save(_ credentials: ChatGPTPlanCredentials, keychainAccount: String) {
        guard let encoded = try? credentials.encode() else { return }
        KeychainHelper.save(key: keychainAccount, value: encoded)
    }

    private static func loadRegistration(keychainAccount: String) -> ChatGPTPlanRegistration? {
        guard let value = KeychainHelper.read(key: keychainAccount),
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatGPTPlanRegistration.self, from: data)
    }

    private static func saveRegistration(_ registration: ChatGPTPlanRegistration, keychainAccount: String) {
        guard let data = try? JSONEncoder().encode(registration) else { return }
        KeychainHelper.save(key: keychainAccount, value: String(decoding: data, as: UTF8.self))
    }

    private struct ModelList: Decodable {
        let models: [ChatGPTPlanModel]
    }
}

enum ChatGPTPlanError: LocalizedError {
    case notConnected
    case planUsageNotAuthorized
    case authorizationCancelled
    case callbackInvalid
    case callbackStateMismatch
    case tokenExchangeFailed(String)
    case credentialSaveFailed
    case identityValidationFailed
    case refreshFailed(String)
    case modelListUnavailable
    case inferenceFailed(String)
    case incompleteResponse
    case secureRandomUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected: "Sign in with ChatGPT to connect an account."
        case .planUsageNotAuthorized: "This ChatGPT connection has not authorized plan usage. Reconnect and allow the requested permission."
        case .authorizationCancelled: "ChatGPT sign-in was cancelled."
        case .callbackInvalid: "ChatGPT returned an invalid sign-in response. Try connecting again."
        case .callbackStateMismatch: "The sign-in response could not be verified. Try connecting again."
        case let .tokenExchangeFailed(message): "Could not complete ChatGPT sign-in: \(message)"
        case .credentialSaveFailed: "The ChatGPT connection could not be saved to this Mac’s Keychain."
        case .identityValidationFailed: "ChatGPT identity verification failed. No credentials were saved."
        case let .refreshFailed(message): "Could not refresh the ChatGPT connection: \(message)"
        case .modelListUnavailable: "Could not load the models available to this ChatGPT account."
        case let .inferenceFailed(message): "ChatGPT could not complete this request: \(message)"
        case .incompleteResponse: "ChatGPT ended the response before it was complete."
        case .secureRandomUnavailable: "Could not create secure sign-in values. Try connecting again."
        }
    }
}

/// Official OAuth authorization-code flow for locally hosted open-source apps.
/// Uses PKCE, state, nonce, a loopback callback, verified OIDC identity, and the
/// ChatGPT plan usage scope. Does not read Codex or ChatGPT desktop credentials.
enum ChatGPTPlanOAuth {
    private static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    private static let authorizationEndpoint = "https://auth.openai.com/api/accounts/authorize"
    private static let tokenEndpoint = "https://auth.openai.com/api/accounts/oauth/token"
    private static let jwksEndpoint = "https://auth.openai.com/.well-known/jwks.json"
    private static let discoveryEndpoint = "https://auth.openai.com/.well-known/openid-configuration"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    static func authorize(
        existing: ChatGPTPlanRegistration?,
        idTokenHint: String? = nil,
    ) async throws -> ChatGPTPlanCredentials {
        let callbackServer = try LoopbackCallbackServer()
        let port = try await callbackServer.start()
        defer { callbackServer.stop() }

        let redirectURI = "http://127.0.0.1:\(port)/auth/callback"
        let state = try randomToken()
        let nonce = try randomToken()
        let verifier = try randomToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString
        let hostID = existing?.hostID ?? stableHostID()
        let clientID = existing?.clientID ?? "dynamic_agent_client"

        guard let endpoint = URL(string: authorizationEndpoint),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ChatGPTPlanError.callbackInvalid
        }
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
        ]
        if let existing {
            if let idTokenHint {
                queryItems.append(URLQueryItem(name: "id_token_hint", value: idTokenHint))
            }
            if let email = existing.email {
                queryItems.append(URLQueryItem(name: "login_hint", value: email))
            }
        } else {
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: "Sawti"))
        }
        components.queryItems = queryItems
        guard let authorizationURL = components.url,
              await MainActor.run(body: { NSWorkspace.shared.open(authorizationURL) }) else {
            throw ChatGPTPlanError.callbackInvalid
        }

        let callback = try await callbackServer.waitForCallback()
        guard let response = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw ChatGPTPlanError.callbackInvalid
        }
        let values = Dictionary(response.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        guard values["state"] == state else { throw ChatGPTPlanError.callbackStateMismatch }
        if values["error"] == "access_denied" { throw ChatGPTPlanError.authorizationCancelled }
        guard let code = values["code"], !code.isEmpty else { throw ChatGPTPlanError.callbackInvalid }

        let issuedClientID = existing?.clientID ?? values["client_id"]
        guard let issuedClientID, !issuedClientID.isEmpty,
              existing == nil || values["client_id"].map({ $0 == issuedClientID }) ?? true else {
            throw ChatGPTPlanError.callbackInvalid
        }
        let token = try await exchangeCode(
            code,
            clientID: issuedClientID,
            verifier: verifier,
            redirectURI: redirectURI,
        )
        guard let idToken = token.idToken,
              let refreshToken = token.refreshToken,
              let grantedScope = token.scope else {
            throw ChatGPTPlanError.tokenExchangeFailed("ChatGPT did not return the required credentials and permissions")
        }
        let grantedScopes = grantedScope.split(whereSeparator: \.isWhitespace).map(String.init)
        guard grantedScopes.contains("chatgpt.tokens.use.direct"), grantedScopes.contains("resource.invoke") else {
            throw ChatGPTPlanError.planUsageNotAuthorized
        }
        let identity = try await verifyIdentity(
            idToken,
            expectedClientID: issuedClientID,
            expectedNonce: nonce,
        )
        if let existing, identity.subject != existing.subject {
            throw ChatGPTPlanError.identityValidationFailed
        }
        guard let accessToken = token.accessToken, let lifetime = token.expiresIn else {
            throw ChatGPTPlanError.tokenExchangeFailed("ChatGPT did not return an access token")
        }
        return ChatGPTPlanCredentials(
            clientID: issuedClientID,
            hostID: hostID,
            subject: identity.subject,
            email: identity.email,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            scopes: grantedScopes,
            expiresAt: Date().addingTimeInterval(TimeInterval(lifetime)),
        )
    }

    static func refresh(_ credentials: ChatGPTPlanCredentials) async throws -> ChatGPTPlanCredentials {
        guard let tokenURL = URL(string: tokenEndpoint) else {
            throw ChatGPTPlanError.refreshFailed("The token service address is invalid.")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "client_id": credentials.clientID,
            "refresh_token": credentials.refreshToken,
            "resource": resource,
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChatGPTPlanError.refreshFailed("Check your network connection and try again.")
        }
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode),
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              let accessToken = token.accessToken,
              let lifetime = token.expiresIn else {
            throw ChatGPTPlanError.refreshFailed("Reconnect the ChatGPT account if the connection has expired.")
        }
        guard token.scope.map({ $0.split(whereSeparator: \.isWhitespace).contains("chatgpt.tokens.use.direct") }) ?? credentials.permitsPlanUsage else {
            throw ChatGPTPlanError.planUsageNotAuthorized
        }
        return ChatGPTPlanCredentials(
            clientID: credentials.clientID,
            hostID: credentials.hostID,
            subject: credentials.subject,
            email: credentials.email,
            idToken: token.idToken ?? credentials.idToken,
            accessToken: accessToken,
            refreshToken: token.refreshToken ?? credentials.refreshToken,
            scopes: token.scope?.split(whereSeparator: \.isWhitespace).map(String.init) ?? credentials.scopes,
            expiresAt: Date().addingTimeInterval(TimeInterval(lifetime)),
        )
    }

    /// Revoke the renewable session before local sign-out. The caller still
    /// clears local tokens if revocation cannot be confirmed.
    static func revoke(_ credentials: ChatGPTPlanCredentials) async -> Bool {
        guard let discoveryURL = URL(string: discoveryEndpoint),
              let (discoveryData, discoveryResponse) = try? await URLSession.shared.data(from: discoveryURL),
              let http = discoveryResponse as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode),
              let discovery = try? JSONDecoder().decode(OIDCDiscovery.self, from: discoveryData),
              let endpoint = URL(string: discovery.revocationEndpoint) else { return false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "token": credentials.refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": credentials.clientID,
        ])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse else { return false }
        return (200 ... 299).contains(response.statusCode)
    }

    private static func exchangeCode(
        _ code: String,
        clientID: String,
        verifier: String,
        redirectURI: String,
    ) async throws -> TokenResponse {
        guard let tokenURL = URL(string: tokenEndpoint) else {
            throw ChatGPTPlanError.tokenExchangeFailed("The token service address is invalid.")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "resource": resource,
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode) else {
                throw ChatGPTPlanError.tokenExchangeFailed("The authorization code was rejected. Start a fresh sign-in.")
            }
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch let error as ChatGPTPlanError {
            throw error
        } catch {
            throw ChatGPTPlanError.tokenExchangeFailed("The token response could not be verified.")
        }
    }

    private static func verifyIdentity(
        _ token: String,
        expectedClientID: String,
        expectedNonce: String,
    ) async throws -> VerifiedIdentity {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let headerData = Data(base64URL: String(parts[0])),
              let claimsData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])),
              let header = try? JSONDecoder().decode(JWTHeader.self, from: headerData),
              header.alg == "RS256",
              let claims = try? JSONDecoder().decode(JWTClaims.self, from: claimsData),
              claims.issuer == issuer,
              claims.audience.contains(expectedClientID),
              claims.audience.count == 1 || claims.authorizedParty == expectedClientID,
              claims.expiresAt > Date().timeIntervalSince1970,
              claims.nonce == expectedNonce,
              !claims.subject.isEmpty else {
            throw ChatGPTPlanError.identityValidationFailed
        }

        guard let jwksURL = URL(string: jwksEndpoint) else {
            throw ChatGPTPlanError.identityValidationFailed
        }
        let jwksData: Data
        do {
            (jwksData, _) = try await URLSession.shared.data(from: jwksURL)
        } catch {
            throw ChatGPTPlanError.identityValidationFailed
        }
        guard let keys = try? JSONDecoder().decode(JWKS.self, from: jwksData).keys,
              let jwk = keys.first(where: {
                  $0.keyID == header.kid
                      && $0.keyType == "RSA"
                      && ($0.use == nil || $0.use == "sig")
                      && ($0.algorithm == nil || $0.algorithm == "RS256")
              }),
              let modulus = Data(base64URL: jwk.modulus),
              let exponent = Data(base64URL: jwk.exponent) else {
            throw ChatGPTPlanError.identityValidationFailed
        }

        let keyAttributes = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8,
        ] as CFDictionary
        guard let publicKey = SecKeyCreateWithData(
            rsaPublicKeyDER(modulus: modulus, exponent: exponent) as CFData,
            keyAttributes,
            nil,
        ) else { throw ChatGPTPlanError.identityValidationFailed }
        let signedBytes = Data("\(parts[0]).\(parts[1])".utf8)
        var verificationError: Unmanaged<CFError>?
        guard SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signedBytes as CFData,
            signature as CFData,
            &verificationError,
        ) else { throw ChatGPTPlanError.identityValidationFailed }
        return VerifiedIdentity(subject: claims.subject, email: claims.email)
    }

    private static func stableHostID() -> String {
        let key = "chatGPTPlanHostID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(identifier, forKey: key)
        return identifier
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTPlanError.secureRandomUnavailable
        }
        return Data(bytes).base64URLString
    }

    private static func formBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func integer(_ data: Data) -> Data {
            var bytes = Data(data.drop(while: { $0 == 0 }))
            if bytes.isEmpty { bytes = Data([0]) }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return der(tag: 0x02, contents: bytes)
        }
        return der(tag: 0x30, contents: integer(modulus) + integer(exponent))
    }

    private static func der(tag: UInt8, contents: Data) -> Data {
        var output = Data([tag])
        if contents.count < 128 {
            output.append(UInt8(contents.count))
        } else {
            var length = contents.count
            var encoded = [UInt8]()
            while length > 0 {
                encoded.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            }
            output.append(0x80 | UInt8(encoded.count))
            output.append(contentsOf: encoded)
        }
        output.append(contents)
        return output
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?
        let scope: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case scope
            case expiresIn = "expires_in"
        }
    }

    private struct JWTHeader: Decodable {
        let alg: String
        let kid: String
    }

    private struct JWTClaims: Decodable {
        let issuer: String
        let subject: String
        let expiresAt: Double
        let nonce: String
        let email: String?
        let authorizedParty: String?
        private let audienceValue: AudienceValue

        enum CodingKeys: String, CodingKey {
            case issuer = "iss"
            case subject = "sub"
            case expiresAt = "exp"
            case nonce
            case email
            case authorizedParty = "azp"
            case audienceValue = "aud"
        }

        var audience: [String] {
            switch audienceValue {
            case let .single(value): [value]
            case let .multiple(values): values
            }
        }
    }

    private enum AudienceValue: Decodable {
        case single(String)
        case multiple([String])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                self = .single(single)
            } else {
                self = try .multiple(container.decode([String].self))
            }
        }
    }

    private struct JWKS: Decodable {
        let keys: [JWK]
    }

    private struct OIDCDiscovery: Decodable {
        let revocationEndpoint: String

        enum CodingKeys: String, CodingKey {
            case revocationEndpoint = "revocation_endpoint"
        }
    }

    private struct JWK: Decodable {
        let keyID: String
        let keyType: String
        let use: String?
        let algorithm: String?
        let modulus: String
        let exponent: String

        enum CodingKeys: String, CodingKey {
            case keyID = "kid"
            case keyType = "kty"
            case use
            case algorithm = "alg"
            case modulus = "n"
            case exponent = "e"
        }
    }

    private struct VerifiedIdentity {
        let subject: String
        let email: String?
    }
}

/// Shared AI provider using the user's eligible ChatGPT plan through the
/// supported Responses API. ChatGPT conversations and account history are not
/// accessed. Requests explicitly disable server-side response storage.
struct ChatGPTPlanResponsesGenerator: ProtocolGenerating, AITextGenerating {
    let model: String
    let language: String
    let thinkingEffort: AIThinkingEffort
    let credentialStore: ChatGPTPlanCredentialStore
    let session: URLSession

    init(
        model: String,
        language: String,
        credentialStore: ChatGPTPlanCredentialStore,
        thinkingEffort: AIThinkingEffort = .automatic,
        session: URLSession = .shared,
    ) {
        self.model = model
        self.language = language
        self.thinkingEffort = thinkingEffort
        self.credentialStore = credentialStore
        self.session = session
    }

    func generate(
        transcript: String,
        title _: String,
        diarized: Bool,
        meetingStartTime: Date?,
    ) async throws -> String {
        let instructions = ProtocolGenerator.buildSystemPrompt(
            diarized: diarized,
            language: language,
            meetingStartTime: meetingStartTime,
        )
        return try await generateText(systemPrompt: instructions, userPrompt: transcript)
    }

    func generateText(systemPrompt: String, userPrompt: String) async throws -> String {
        try await generateText(systemPrompt: systemPrompt, userPrompt: userPrompt, imageData: nil)
    }

    var supportsImageInput: Bool {
        true
    }

    func generateText(systemPrompt: String, userPrompt: String, imageData: Data?) async throws -> String {
        let credentials = try await credentialStore.validCredentials()
        let inputContent: [[String: Any]] = if let imageData {
            [
                ["type": "input_text", "text": userPrompt],
                [
                    "type": "input_image",
                    "image_url": "data:image/jpeg;base64,\(imageData.base64EncodedString())",
                    "detail": "high",
                ],
            ]
        } else {
            [["type": "input_text", "text": userPrompt]]
        }
        var body: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": [["role": "user", "content": inputContent]],
            "store": false,
            "stream": true,
        ]
        if let effort = AIThinkingEffort.requestValue(
            for: thinkingEffort,
            model: model,
            provider: .chatGPTPlan,
        ) {
            body["reasoning"] = ["effort": effort]
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        guard let endpoint = URL(string: "https://api.openai.com/v1/responses") else {
            throw ChatGPTPlanError.inferenceFailed("The Responses API address is invalid.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        request.timeoutInterval = 1800

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatGPTPlanError.inferenceFailed("The service returned an invalid response.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            var details = "HTTP \(http.statusCode)"
            for try await line in bytes.lines {
                if details.count > 1000 { break }
                details += "\n\(line)"
            }
            throw ChatGPTPlanError.inferenceFailed(details)
        }

        var text = ""
        var completed = false
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let eventData = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard eventData != "[DONE]",
                  let json = eventData.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
            case "response.completed":
                completed = true
            case "response.failed":
                let response = event["response"] as? [String: Any]
                let error = response?["error"] as? [String: Any]
                throw ChatGPTPlanError.inferenceFailed(
                    error?["message"] as? String ?? error?["code"] as? String ?? "The request failed.",
                )
            case "response.incomplete":
                throw ChatGPTPlanError.incompleteResponse
            default:
                break
            }
        }
        guard completed else { throw ChatGPTPlanError.incompleteResponse }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw ChatGPTPlanError.incompleteResponse }
        return result
    }
}

private final class LoopbackCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let callbacks: AsyncStream<URL>
    private let callbackContinuation: AsyncStream<URL>.Continuation
    private let startup = NSLock()
    private var startupContinuation: CheckedContinuation<UInt16, any Error>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let pair = AsyncStream<URL>.makeStream()
        callbacks = pair.stream
        callbackContinuation = pair.continuation
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            startup.lock()
            startupContinuation = continuation
            startup.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port?.rawValue else {
                        self.finishStart(.failure(ChatGPTPlanError.callbackInvalid))
                        return
                    }
                    self.finishStart(.success(port))
                case let .failed(error):
                    self.finishStart(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: DispatchQueue(label: "com.sawti.chatgpt-loopback"))
        }
    }

    func waitForCallback() async throws -> URL {
        for await callback in callbacks {
            return callback
        }
        throw ChatGPTPlanError.callbackInvalid
    }

    func stop() {
        listener.cancel()
        callbackContinuation.finish()
    }

    private func finishStart(_ result: Result<UInt16, any Error>) {
        startup.lock()
        let continuation = startupContinuation
        startupContinuation = nil
        startup.unlock()
        guard let continuation else { return }
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.sawti.chatgpt-callback"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self,
                  let data,
                  let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first else {
                self?.reply(connection, status: "400 Bad Request", message: "Invalid response. Return to Sawti and try again.")
                return
            }
            let fields = firstLine.split(separator: " ")
            guard fields.count >= 2,
                  fields[0] == "GET",
                  fields[1].hasPrefix("/auth/callback"),
                  let url = URL(string: "http://127.0.0.1\(fields[1])") else {
                self.reply(connection, status: "404 Not Found", message: "This local address is only for Sawti sign-in.")
                return
            }
            self.reply(connection, status: "200 OK", message: "Sign-in received. You can return to Sawti.")
            self.callbackContinuation.yield(url)
        }
    }

    private func reply(_ connection: NWConnection, status: String, message: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Sawti</title><p>\(message)</p>"
        let data = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
            .utf8)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: normalized)
    }
}
