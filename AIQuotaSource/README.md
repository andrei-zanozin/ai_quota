# AI Quota

A native macOS menu bar app showing quota consumption, for example `9%`.
Click it to see spent, maximum, remaining, and the last successful update.

Requires macOS 14 or newer. The included app is built for the architecture of this Mac and signed locally for development; it is not notarized for public distribution.

## Run

Open `AI Quota.app` from the parent folder. The app prompts for connection settings and a bearer token every launch. Paste only the token, without `Bearer `. The token stays in memory and is never stored in preferences or files. Endpoint, proxy URL, and refresh interval settings are saved locally.

`example.com` is a placeholder and is deliberately not contacted. Replace it with the real HTTPS endpoint. Choose **Preview demo** to try the interface without making any network requests.

The endpoint receives a GET request:

```
Authorization: Bearer <your session token>
Accept: application/json
```

The API response includes:

```json
{"info":{"spend":22.02092000999998,"max_budget":500.0}}
```

Percentage = spent / maximum × 100, rounded to the nearest whole percent. Maximum must be positive; spent must be nonnegative. Over-budget values remain visible, such as `110%`. Both amounts are in USD. The app reads `info.spend` and `info.max_budget` and ignores other response fields. This example displays `4%` used, `22.02 USD` spent, and `477.98 USD` remaining.

## Proxy

Enter `http://proxy.company.com:8080` for an HTTP CONNECT proxy, or `https://proxy.company.com:8443` for a TLS connection to the proxy. Leaving it blank uses the Mac's system proxy settings. Explicitly configured proxies have failover disabled. Certificates use the normal system trust rules by default.

Enter the proxy username and password in their separate fields when your proxy requires login. Leave both blank for a proxy without authentication. Credentials require an explicit proxy URL. The username and password stay in memory; neither is saved. The API’s bearer token remains separate from proxy authentication.

## Certificate validation

**Connection… → Skip certificate validation** accepts untrusted certificates for the configured API and explicit HTTPS proxy. It is off at launch and is not saved. Enabling it can expose the bearer token and proxy credentials to impersonation. HTTPS and TLS 1.2 or newer remain required; redirects remain blocked.

The app’s ATS exception permits custom certificate handling. The session delegate and proxy TLS options bypass validation only when the checkbox is enabled. No system trust settings are changed.

## Refresh and errors

Refresh happens immediately after connecting, then at the interval configured in **Connection… → Refresh interval (min)**. The default is 5 minutes. Enter a positive whole number of minutes; the value is saved after a successful connection. Before macOS sleeps, polling stops and any active request is canceled. Manual refreshes are also blocked during sleep. On wake, the app refreshes immediately and resumes the configured refresh schedule, preserving the previous quota while reconnecting. Authentication failures still require reconnecting via **Connection…**. This follows system sleep; a Mac kept awake in closed-display mode continues refreshing. **Refresh** checks manually. Connection errors preserve the last successful budget; a dot next to the percentage marks stale data. The panel displays the error and previous update time. HTTP 401/403 pauses requests until you enter a new token via **Connection…**. HTTP 407 or a macOS proxy authentication error pauses requests until you correct the proxy login via **Connection…**. Redirects are rejected; configure the final endpoint URL.

## Build

Apple Command Line Tools are sufficient; no external dependencies are required:

```
zsh build.sh
```

Apple documents the networking APIs used here: [proxy configurations](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/proxyconfigurations) and [HTTP CONNECT with optional TLS](https://developer.apple.com/documentation/network/proxyconfiguration/init%28httpconnectproxy%3Atlsoptions%3A%29).

## Validation

The source includes mocked networking tests in `ClientTests.swift`. They check the request, budget parsing, error handling, proxy configuration, proxy login validation, and refresh interval validation. They do not validate connectivity with your real API or corporate proxy.

Run them with `zsh test.sh`.

The app compiled successfully and the mocked tests passed on the build machine. A local API test with simulated sleep/wake notifications verified request cancellation, blocked refresh/reconnect during sleep, one immediate refresh on wake, and preservation of authentication failures and demo mode. A timed local API test verified the configured one-minute automatic refresh, manual refresh, interval changes, and sleep/wake behavior. Physical lid-close sleep was not tested. A local HTTP CONNECT proxy test also verified Basic username/password authentication using dummy credentials; the test stopped before contacting any API. A local self-signed TLS test verified that direct connections and authenticated HTTP/HTTPS proxies reject untrusted certificates by default and succeed when certificate validation is skipped; custom API trust handling also rejects a mismatched challenge host. Interactive visual inspection was not completed because Computer Use access was not approved. The real API and proxy have not been tested.
