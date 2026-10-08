import AppKit
import SwiftUI

// Select the property wrapper; Command Line Tools do not include SwiftUI macro plugins.
private typealias ViewState<Value> = State<Value>

@MainActor
final class QuotaModel: ObservableObject {
    @Published var quota: Quota?
    @Published var updated: Date?
    @Published var error: String?
    @Published var loading = false
    @Published var demo = false
    private var request: URLRequest?
    private var session: URLSession?
    private var poller: Task<Void, Never>?
    private var activeRequest: Task<Quota, Error>?
    private var sleeping = false
    private var refreshInterval: UInt64 = 300_000_000_000
    private let notifications = NSWorkspace.shared.notificationCenter
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var authenticationFailed = false

    init() {
        observers = [
            notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(true) }
            },
            notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(false) }
            }
        ]
    }

    deinit {
        poller?.cancel()
        activeRequest?.cancel()
        observers.forEach { notifications.removeObserver($0) }
    }

    private func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        if sleeping { stopPolling() } else { startPolling() }
    }

    private func stopPolling() {
        poller?.cancel()
        poller = nil
        activeRequest?.cancel()
        activeRequest = nil
        generation = UUID()
        loading = false
    }

    var label: String { (quota?.label ?? "—") + (error != nil && quota != nil ? " ·" : "") }

    func connect(settings: ConnectionSettings, token: String) throws {
        let interval = try settings.refreshIntervalNanoseconds()
        let request = try QuotaClient.request(settings: settings, token: token)
        let configuration = try settings.configuration()
        reset()
        refreshInterval = interval
        self.request = request
        session = URLSession(configuration: configuration, delegate: ConnectionDelegate(skipCertificateValidation: settings.skipCertificateValidation, host: request.url?.host), delegateQueue: nil)
        startPolling()
    }

    private func startPolling() {
        guard !sleeping, !authenticationFailed, request != nil, session != nil, poller == nil else { return }
        let interval = refreshInterval
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: interval) }
                catch { break }
            }
        }
    }

    func preview() {
        reset()
        demo = true
        quota = Quota(spent: 9, maximum: 100)
        updated = Date()
    }

    private func reset() {
        stopPolling()
        session?.invalidateAndCancel()
        session = nil
        request = nil
        authenticationFailed = false
        quota = nil
        updated = nil
        error = nil
        demo = false
    }

    func refresh() async {
        guard !sleeping, !loading, !authenticationFailed, let request, let session else { return }
        let current = generation
        loading = true
        let task = Task {
            try Task.checkCancellation()
            return try await QuotaClient.fetch(request: request, session: session)
        }
        activeRequest = task
        do {
            let result = try await task.value
            guard current == generation, !Task.isCancelled else { return }
            quota = result
            updated = Date()
            error = nil
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            switch error {
            case QuotaError.authentication, QuotaError.proxyAuthentication: authenticationFailed = true
            default: break
            }
            // Never display the server's response body or a request containing the token.
            self.error = error is QuotaError ? error.localizedDescription : "Cannot reach the API. Check the connection and proxy settings."
        }
        activeRequest = nil
        loading = false
    }
}

struct DetailsView: View {
    @ObservedObject var model: QuotaModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("AI quota", systemImage: "chart.pie")
                    .font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                if model.demo { Text("DEMO").font(.caption.bold()).foregroundStyle(.secondary) }
            }
            if let quota = model.quota {
                HStack(alignment: .firstTextBaseline) {
                    Text(quota.label).font(.system(size: 38, weight: .semibold, design: .rounded))
                    Text("used").foregroundStyle(.secondary)
                }
                ProgressView(value: min(quota.percentage / 100, 1))
                    .tint(quota.percentage >= 90 ? .orange : .accentColor)
                VStack(spacing: 10) {
                    row("Spent", quota.spent, unit: quota.unit)
                    row("Maximum", quota.maximum, unit: quota.unit)
                    row("Remaining", quota.remaining, unit: quota.unit)
                }
                if let updated = model.updated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(model.loading ? "Checking consumption…" : "Connect to see your consumption.")
                    .foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if model.quota != nil {
                    Text("Showing the last successful update.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.loading || model.demo || model.updated == nil && model.error == nil)
                Button("Connection…") {
                    openWindow(id: "connection")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.controlSize(.small)
        }
        .padding(20)
        .frame(width: 330)
    }

    private func row(_ title: String, _ value: Double, unit: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(value.formatted(.number.precision(.fractionLength(0...2)))) \(unit)").monospacedDigit()
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: QuotaModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? "https://example.com"
    @ViewState private var proxy = UserDefaults.standard.string(forKey: "proxy") ?? ""
    @ViewState private var refreshMinutes = String(UserDefaults.standard.object(forKey: "refreshMinutes") as? Int ?? 5)
    @ViewState private var proxyUsername = ""
    @ViewState private var proxyPassword = ""
    @ViewState private var skipCertificateValidation = false
    @ViewState private var token = ""
    @ViewState private var error: String?
    @ViewState private var firstLaunch = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect AI quota").font(.title2.bold())
            Text("Your bearer token and proxy password are kept only for this session. Leave the proxy blank to use your Mac’s settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("API endpoint", text: $endpoint)
                TextField("HTTP/HTTPS proxy", text: $proxy)
                TextField("Proxy username", text: $proxyUsername)
                SecureField("Proxy password", text: $proxyPassword)
                SecureField("Bearer token", text: $token)
                TextField("Refresh interval (min)", text: $refreshMinutes)
                Toggle("Skip certificate validation", isOn: $skipCertificateValidation)
                    .toggleStyle(.checkbox)
                    .help("Accept untrusted API and HTTPS proxy certificates. This can expose your credentials to impersonation.")
            }
            if let error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Preview demo") { token = ""; proxyPassword = ""; model.preview(); dismiss() }
                Spacer()
                Button("Connect") {
                    do {
                        guard let minutes = Int(refreshMinutes.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                            throw QuotaError.message("Enter a positive whole number of minutes for the refresh interval.")
                        }
                        try model.connect(settings: ConnectionSettings(endpoint: endpoint, proxy: proxy, proxyUsername: proxyUsername, proxyPassword: proxyPassword, skipCertificateValidation: skipCertificateValidation, refreshMinutes: minutes), token: token)
                        UserDefaults.standard.set(endpoint, forKey: "endpoint")
                        UserDefaults.standard.set(proxy, forKey: "proxy")
                        UserDefaults.standard.set(minutes, forKey: "refreshMinutes")
                        token = ""
                        proxyPassword = ""
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 440)
        .onAppear {
            proxyPassword = ""
            token = ""
            error = nil
            if firstLaunch && CommandLine.arguments.contains("--demo") {
                model.preview()
                dismiss()
            } else { NSApplication.shared.activate(ignoringOtherApps: true) }
            firstLaunch = false
        }
        .onDisappear { token = ""; proxyPassword = ""; error = nil }
    }
}

@main
struct AIQuotaApp: App {
    @StateObject private var model = QuotaModel()

    var body: some Scene {
        Window("AI Quota", id: "connection") {
            ConnectionView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        MenuBarExtra {
            DetailsView(model: model)
        } label: {
            Text(model.label)
                .monospacedDigit()
                .help(model.demo ? "AI quota — demo data" : model.error ?? "AI quota consumption")
                .accessibilityLabel("AI quota: \(model.label)")
        }
        .menuBarExtraStyle(.window)
    }
}
