import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "ClaudeUsageService")

@MainActor @Observable
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    var currentUsage: QuotaPeriod?
    var isLoading = false
    var error: String?
    var isConnected = false

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let authFailureStatusCodes: Set<Int> = [401, 403]
    private static let maxBackoffInterval: TimeInterval = 600

    private static let userAgent: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let deadline = DispatchTime.now() + .seconds(2)
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            if done.wait(timeout: deadline) == .timedOut {
                process.terminate()
                return "claude-code/0.0.0"
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").first, !version.isEmpty {
                return "claude-code/\(version)"
            }
        } catch {}
        return "claude-code/0.0.0"
    }()

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 60
    private var consecutiveRateLimits = 0
    private var cachedToken: String?

    private init() {}

    func connectAndStartPolling() {
        AppSettings.isUsageEnabled = true
        error = nil
        stopPolling()

        Task {
            guard let accessToken = KeychainManager.getAccessToken() else {
                error = "Keychain access required"
                isConnected = false
                AppSettings.isUsageEnabled = false
                return
            }
            cachedToken = accessToken
            await performFetch(with: accessToken, userInitiated: true)
        }
    }

    func startPolling() {
        stopPolling()

        Task {
            guard let accessToken = KeychainManager.getCachedOAuthToken() else {
                logger.info("No cached token, user must connect manually")
                isConnected = false
                AppSettings.isUsageEnabled = false
                return
            }
            AppSettings.isUsageEnabled = true
            cachedToken = accessToken
            await performFetch(with: accessToken)
        }
    }

    func retryNow() {
        guard !isLoading else { return }
        error = nil
        stopPolling()
        Task {
            guard let accessToken = cachedToken else {
                connectAndStartPolling()
                return
            }
            consecutiveRateLimits = 0
            await performFetch(with: accessToken, userInitiated: true)
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func schedulePollTimer(interval: TimeInterval? = nil) {
        pollTimer?.invalidate()
        let baseInterval = interval ?? pollInterval
        let jitter = Double.random(in: -2...2)
        let effectiveInterval = max(10, baseInterval + jitter)
        pollTimer = Timer.scheduledTimer(withTimeInterval: effectiveInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchUsage()
            }
        }
        logger.info("Next usage poll in \(Int(effectiveInterval))s")
    }

    private func fetchUsage() async {
        guard let accessToken = cachedToken else {
            logger.warning("No cached token available, stopping polling")
            stopPolling()
            return
        }

        await performFetch(with: accessToken)
    }

    private func performFetch(with accessToken: String, userInitiated: Bool = false) async {
        if userInitiated { isLoading = true }

        defer { if userInitiated { isLoading = false } }

        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Invalid response"
                schedulePollTimer()
                return
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 429 {
                    consecutiveRateLimits += 1
                    let exponentialDelay = pollInterval * pow(2.0, Double(consecutiveRateLimits))
                    var backoffDelay = min(exponentialDelay, Self.maxBackoffInterval)
                    if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                       let retrySeconds = TimeInterval(retryAfter) {
                        backoffDelay = min(max(backoffDelay, retrySeconds), Self.maxBackoffInterval)
                    }
                    if currentUsage == nil {
                        error = "Rate limited, retrying in \(Int(backoffDelay))s"
                    } else {
                        error = nil
                    }
                    logger.warning("Rate limited (429), backing off \(Int(backoffDelay))s (attempt \(self.consecutiveRateLimits))")
                    schedulePollTimer(interval: backoffDelay)
                    return
                }

                if Self.authFailureStatusCodes.contains(httpResponse.statusCode) {
                    cachedToken = nil
                    KeychainManager.clearCachedOAuthToken()

                    if let freshToken = KeychainManager.refreshAccessTokenSilently(),
                       freshToken != accessToken {
                        consecutiveRateLimits = 0
                        cachedToken = freshToken
                        logger.info("Token refreshed silently from Claude Code keychain")
                        await performFetch(with: freshToken)
                        return
                    }

                    error = "Token expired"
                    isConnected = false
                    stopPolling()
                } else {
                    error = "HTTP \(httpResponse.statusCode)"
                    schedulePollTimer()
                }
                logger.warning("API error: HTTP \(httpResponse.statusCode)")
                return
            }

            let usageResponse = try JSONDecoder().decode(UsageResponse.self, from: data)
            consecutiveRateLimits = 0
            isConnected = true
            error = nil
            currentUsage = usageResponse.fiveHour
            logger.info("Usage fetched: \(self.currentUsage?.usagePercentage ?? 0)%")
            schedulePollTimer()

        } catch {
            self.error = "Network error"
            logger.error("Fetch failed: \(error.localizedDescription)")
            schedulePollTimer()
        }
    }
}
