import Foundation
import Network
import Security

struct Quota: Decodable {
    let spent: Double
    let maximum: Double
    let unit = "USD"

    private enum CodingKeys: String, CodingKey { case spent = "spend", maximum = "max_budget" }

    var percentage: Double { spent / maximum * 100 }
    var label: String { String(format: "%.0f%%", percentage) }
    var remaining: Double { max(0, maximum - spent) }

    static func decode(_ data: Data) throws -> Quota {
        struct Response: Decodable { let info: Quota }
        let quota: Quota
        do { quota = try JSONDecoder().decode(Response.self, from: data).info }
        catch { throw QuotaError.message("Expected JSON with numeric info.spend and info.max_budget fields.") }
        guard quota.spent.isFinite, quota.spent >= 0,
              quota.maximum.isFinite, quota.maximum > 0,
              quota.percentage.isFinite else {
            throw QuotaError.message("The API returned invalid budgets. Maximum must be greater than zero.")
        }
        return quota
    }
}

enum QuotaError: LocalizedError {
    case message(String)
    case authentication
    case proxyAuthentication
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .authentication: return "Authentication failed. Enter a new bearer token."
        case .proxyAuthentication: return "Proxy authentication failed. Check the proxy username and password in Connection…"
        }
    }
}

struct ConnectionSettings {
    let endpoint: String
    let proxy: String
    var proxyUsername = ""
    var proxyPassword = ""
    var skipCertificateValidation = false
    var refreshMinutes = 5

    func refreshIntervalNanoseconds() throws -> UInt64 {
        guard refreshMinutes > 0, let minutes = UInt64(exactly: refreshMinutes),
              minutes <= UInt64.max / 60_000_000_000 else {
            throw QuotaError.message("Enter a positive whole number of minutes for the refresh interval.")
        }
        return minutes * 60_000_000_000
    }

    func endpointURL() throws -> URL {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw QuotaError.message("Enter a full HTTPS API URL, such as https://api.company.com/quota.")
        }
        guard host.lowercased() != "example.com" else {
            throw QuotaError.message("Replace example.com with your real API URL, or choose Preview demo.")
        }
        return url
    }

    func configuration() throws -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let address = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.isEmpty == proxyPassword.isEmpty else {
            throw QuotaError.message("Enter both the proxy username and password, or leave both blank.")
        }
        guard !address.isEmpty || username.isEmpty else {
            throw QuotaError.message("Enter the proxy URL to use a proxy username and password.")
        }
        if !address.isEmpty {
            guard let url = URL(string: address),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil,
                  url.path.isEmpty || url.path == "/",
                  url.query == nil, url.fragment == nil,
                  let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (scheme == "https" ? 443 : 80)) ?? 0),
                  port.rawValue > 0 else {
                throw QuotaError.message("Enter a proxy URL such as http://proxy.company.com:8080. Use the separate fields for the proxy username and password.")
            }
            let tls = scheme == "https" ? NWProtocolTLS.Options() : nil
            if skipCertificateValidation, let tls {
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
            }
            var proxy = ProxyConfiguration(
                httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(host), port: port),
                tlsOptions: tls
            )
            if !username.isEmpty { proxy.applyCredential(username: username, password: proxyPassword) }
            proxy.allowFailover = false
            configuration.proxyConfigurations = [proxy]
        }
        // An empty proxy list uses the Mac's existing system proxy settings.
        return configuration
    }
}

// Do not forward a bearer token to a redirect destination.
final class ConnectionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let skipCertificateValidation: Bool
    private let host: String?

    init(skipCertificateValidation: Bool = false, host: String? = nil) {
        self.skipCertificateValidation = skipCertificateValidation
        self.host = host?.lowercased()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if skipCertificateValidation,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host.lowercased() == host,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum QuotaClient {
    static func request(settings: ConnectionSettings, token: String) throws -> URLRequest {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.rangeOfCharacter(from: .newlines) == nil else {
            throw QuotaError.message("Enter the bearer token without the Bearer prefix.")
        }
        guard !token.lowercased().hasPrefix("bearer ") else {
            throw QuotaError.message("Paste only the token, without the Bearer prefix.")
        }
        var request = URLRequest(url: try settings.endpointURL())
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func fetch(request: URLRequest, session: URLSession) async throws -> Quota {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as POSIXError where error.code == .EAUTH { throw QuotaError.proxyAuthentication }
        guard let response = response as? HTTPURLResponse else {
            throw QuotaError.message("The API did not return an HTTP response.")
        }
        switch response.statusCode {
        case 200..<300: return try Quota.decode(data)
        case 401, 403: throw QuotaError.authentication
        case 300..<400: throw QuotaError.message("The API redirected the request. Configure the final HTTPS URL.")
        case 407: throw QuotaError.proxyAuthentication
        default: throw QuotaError.message("The API returned HTTP \(response.statusCode).")
        }
    }
}
