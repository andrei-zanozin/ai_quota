import Foundation
import Network

final class MockProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var seen: URLRequest?
    static var failure: Error?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen = request
        if let error = Self.failure {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
enum ClientTests {
    static func check(_ value: Bool, _ description: String) {
        if !value { fatalError(description) }
    }

    static func rejects(_ description: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection: \(description)") }
        catch { check(error is QuotaError, description) }
    }

    static func main() async throws {
        let valid = Data(#"{"info":{"spend":22.02092000999998,"max_budget":500.0,"extra":"ignored"},"extra":true}"#.utf8)
        let quota = try Quota.decode(valid)
        check(quota.spent == 22.02092000999998 && quota.maximum == 500 && quota.unit == "USD", "Nested API budgets are in USD; extra fields are ignored")
        check(quota.label == "4%" && abs(quota.remaining - 477.97907999) < 0.000001, "API sample percentage and remaining")
        let over = try Quota.decode(Data(#"{"info":{"spend":110,"max_budget":100}}"#.utf8))
        check(over.label == "110%" && over.remaining == 0, "Over-budget consumption remains visible")
        let zero = try Quota.decode(Data(#"{"info":{"spend":0,"max_budget":100}}"#.utf8))
        check(zero.label == "0%", "Zero consumption is valid")
        for json in [#"{"info":{"spend":9,"max_budget":0}}"#,
                     #"{"info":{"spend":-1,"max_budget":100}}"#,
                     #"{"info":{"spend":9,"max_budget":-1}}"#,
                     #"{"info":{"spend":9}}"#,
                     #"{"info":{"max_budget":100}}"#,
                     #"{"info":{"spend":"9","max_budget":100}}"#,
                     #"{"info":null}"#, #"{}"#, "<html>Error</html>"] {
            rejects("Invalid budget response") { _ = try Quota.decode(Data(json.utf8)) }
        }
        let settings = ConnectionSettings(endpoint: "https://quota.company.test/usage", proxy: "")
        let request = try QuotaClient.request(settings: settings, token: " test-token ")
        check(request.httpMethod == "GET", "GET request")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "Bearer header")
        check(request.value(forHTTPHeaderField: "Accept") == "application/json", "JSON accept header")
        for token in ["", "Bearer test-token", "test\r\ninjected"] {
            rejects("Invalid token") { _ = try QuotaClient.request(settings: settings, token: token) }
        }
        for endpoint in ["https://example.com", "http://quota.company.test", "garbage", "https://user:password@quota.company.test"] {
            rejects("Invalid or placeholder endpoint") { _ = try ConnectionSettings(endpoint: endpoint, proxy: "").endpointURL() }
        }
        let defaultInterval = try settings.refreshIntervalNanoseconds()
        check(settings.refreshMinutes == 5 && defaultInterval == 300_000_000_000, "Default refresh interval is five minutes")
        for (minutes, expected) in [(1, UInt64(60_000_000_000)), (10, UInt64(600_000_000_000))] {
            var custom = settings
            custom.refreshMinutes = minutes
            let interval = try custom.refreshIntervalNanoseconds()
            check(interval == expected, "Refresh minutes convert to the configured delay")
        }
        for minutes in [0, -1, Int.max] {
            var invalid = settings
            invalid.refreshMinutes = minutes
            rejects("Invalid refresh interval") { _ = try invalid.refreshIntervalNanoseconds() }
        }
        check(!settings.skipCertificateValidation, "Certificate validation is enabled by default")
        let system = try settings.configuration()
        check(system.tlsMinimumSupportedProtocolVersion == .TLSv12, "TLS 1.2 is required")
        check(system.proxyConfigurations.isEmpty, "Use system proxy when unset")
        check(system.urlCredentialStorage == nil && !system.httpShouldSetCookies, "Session does not persist credentials or cookies")
        for proxy in ["http://proxy.company.test:8080", "https://proxy.company.test:8443"] {
            let configuration = try ConnectionSettings(endpoint: settings.endpoint, proxy: proxy).configuration()
            check(configuration.proxyConfigurations.count == 1, "Explicit proxy configured")
            check(!configuration.proxyConfigurations[0].allowFailover, "No proxy bypass on failure")
            let login = ConnectionSettings(endpoint: settings.endpoint, proxy: proxy, proxyUsername: " test-user ", proxyPassword: " test-password ")
            let authenticated = try login.configuration()
            check(authenticated.proxyConfigurations.count == 1 && !authenticated.proxyConfigurations[0].allowFailover, "Authenticated proxy configured without failover")
            var bypass = login
            bypass.skipCertificateValidation = true
            let bypassConfiguration = try bypass.configuration()
            check(!bypassConfiguration.proxyConfigurations[0].allowFailover && bypassConfiguration.tlsMinimumSupportedProtocolVersion == .TLSv12, "Certificate bypass retains proxy routing and TLS minimum")
            let apiRequest = try QuotaClient.request(settings: login, token: "test-token")
            check(apiRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" && apiRequest.value(forHTTPHeaderField: "Proxy-Authorization") == nil, "Proxy credentials are separate from the API request")
        }
        for proxy in ["socks://host:1080", "http://host:0", "http://host:65536", "http://user:password@host:8080", "http://host/path"] {
            rejects("Invalid proxy URL") { _ = try ConnectionSettings(endpoint: settings.endpoint, proxy: proxy).configuration() }
        }
        for login in [ConnectionSettings(endpoint: settings.endpoint, proxy: "http://host:8080", proxyUsername: "user"),
                      ConnectionSettings(endpoint: settings.endpoint, proxy: "http://host:8080", proxyPassword: "password"),
                      ConnectionSettings(endpoint: settings.endpoint, proxy: "", proxyUsername: "user", proxyPassword: "password")] {
            rejects("Incomplete proxy login") { _ = try login.configuration() }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MockProtocol.status = 200
        MockProtocol.body = valid
        let result = try await QuotaClient.fetch(request: request, session: session)
        check(result.label == "4%" && result.spent == quota.spent && result.maximum == 500 && result.unit == "USD", "Mocked API response decoded")
        check(MockProtocol.seen?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "Header reaches URLSession")
        for code in [401, 403, 302, 407, 500] {
            MockProtocol.status = code
            do {
                _ = try await QuotaClient.fetch(request: request, session: session)
                fatalError("Expected HTTP \(code) failure")
            } catch {
                check(error is QuotaError, "Typed HTTP error")
                if code == 401 || code == 403 {
                    guard case QuotaError.authentication = error else { fatalError("Authentication classification") }
                }
                if code == 407 {
                    guard case QuotaError.proxyAuthentication = error else { fatalError("Proxy authentication classification") }
                }
            }
        }
        MockProtocol.failure = POSIXError(.EAUTH)
        do {
            _ = try await QuotaClient.fetch(request: request, session: session)
            fatalError("Expected macOS proxy authentication failure")
        } catch {
            guard case QuotaError.proxyAuthentication = error else { fatalError("macOS proxy authentication classification") }
        }
        MockProtocol.failure = URLError(.timedOut)
        do {
            _ = try await QuotaClient.fetch(request: request, session: session)
            fatalError("Expected network timeout")
        } catch {
            check((error as? URLError)?.code == .timedOut, "Network errors are preserved")
        }
        MockProtocol.failure = nil
        MockProtocol.status = 200
        MockProtocol.body = Data("not JSON".utf8)
        do {
            _ = try await QuotaClient.fetch(request: request, session: session)
            fatalError("Expected invalid JSON failure")
        } catch { check(error is QuotaError, "Bad response error") }
        print("PASS: budgets, request headers, endpoint validation, proxy configuration, and mocked HTTP responses.")
    }
}
