import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "ClaudeUsageService")

enum ClaudeUsageRecoveryAction: Equatable {
    case none
    case retry
    case reconnect
}

protocol ClaudeUsagePollTimer {
    func invalidate()
}

struct ClaudeUsageServiceDependencies {
    var fetchUsage: (URLRequest) async throws -> (Data, URLResponse)
    var getAccessToken: () -> String?
    var getCachedOAuthToken: () -> String?
    var refreshAccessTokenSilently: () -> String?
    var clearCachedOAuthToken: () -> Void
    var resolveUserAgent: () -> String?
    var pollJitter: () -> Double
    var now: () -> Date
    var schedulePoll: @MainActor (TimeInterval, @escaping () -> Void) -> any ClaudeUsagePollTimer
}

private struct LivePollTimer: ClaudeUsagePollTimer {
    let timer: Timer

    func invalidate() {
        timer.invalidate()
    }
}

private enum ClaudeCLIResolver {
    static func resolveUserAgent() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let knownPaths = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]

        for claudePath in knownPaths where FileManager.default.isExecutableFile(atPath: claudePath) {
            guard let version = resolveVersion(at: claudePath) else { continue }
            return "claude-code/\(version)"
        }

        return nil
    }

    private static func resolveVersion(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            if done.wait(timeout: .now() + .seconds(2)) == .timedOut {
                process.terminate()
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ")
            guard let version = components.first, !version.isEmpty else { return nil }
            return version
        } catch {
            return nil
        }
    }
}

extension ClaudeUsageServiceDependencies {
    static let live = Self(
        fetchUsage: { request in
            try await URLSession.shared.data(for: request)
        },
        getAccessToken: {
            KeychainManager.getAccessToken()
        },
        getCachedOAuthToken: {
            KeychainManager.getCachedOAuthToken()
        },
        refreshAccessTokenSilently: {
            KeychainManager.refreshAccessTokenSilently()
        },
        clearCachedOAuthToken: {
            KeychainManager.clearCachedOAuthToken()
        },
        resolveUserAgent: {
            ClaudeCLIResolver.resolveUserAgent()
        },
        pollJitter: {
            Double.random(in: -2...2)
        },
        now: {
            Date()
        },
        schedulePoll: { interval, handler in
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                handler()
            }
            return LivePollTimer(timer: timer)
        }
    )
}

@MainActor @Observable
final class ClaudeUsageService {
    static let shared = ClaudeUsageService()

    var currentUsage: QuotaPeriod?
    var isLoading = false
    var error: String?
    var statusMessage: String?
    var isConnected = false
    var isUsageStale = false
    var recoveryAction: ClaudeUsageRecoveryAction = .none

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxBackoffInterval: TimeInterval = 600
    private static let oauthRecheckInterval = 10

    private let dependencies: ClaudeUsageServiceDependencies
    private var resolvedUserAgent: String?
    private var pollTimer: (any ClaudeUsagePollTimer)?
    private let pollInterval: TimeInterval = 60
    private var consecutiveRateLimits = 0
    private var lastRateLimitTime: Date?
    private var cachedToken: String?
    private var preferHeadersFallback = false
    private var oauthRecheckCounter = 0

    init() {
        self.dependencies = .live
    }

    init(dependencies: ClaudeUsageServiceDependencies) {
        self.dependencies = dependencies
    }

    func connectAndStartPolling() {
        AppSettings.isUsageEnabled = true
        clearTransientState()
        preferHeadersFallback = false
        oauthRecheckCounter = 0
        stopPolling()

        Task {
            guard let accessToken = dependencies.getAccessToken() else {
                presentReconnectRequired("Keychain access required")
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
            guard let accessToken = dependencies.getCachedOAuthToken() else {
                logger.info("No cached token, user must connect manually")
                isConnected = false
                AppSettings.isUsageEnabled = false
                clearTransientState()
                return
            }
            AppSettings.isUsageEnabled = true
            cachedToken = accessToken
            await performFetch(with: accessToken)
        }
    }

    func retryNow() {
        guard !isLoading else { return }
        if let lastRL = lastRateLimitTime, dependencies.now().timeIntervalSince(lastRL) < 10 {
            recoveryAction = .retry
            statusMessage = "Please wait before retrying again"
            logger.info("Retry cooldown active, ignoring tap")
            return
        }
        clearTransientState()
        consecutiveRateLimits = 0
        stopPolling()
        Task {
            guard let accessToken = cachedToken else {
                connectAndStartPolling()
                return
            }
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
        let jitter = dependencies.pollJitter()
        let effectiveInterval = max(10, baseInterval + jitter)
        pollTimer = dependencies.schedulePoll(effectiveInterval) { [weak self] in
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

    private enum FetchResult {
        case success
        case handled
        case enterprise403
    }

    // Internal for unit tests that verify service state transitions directly.
    func performFetch(with accessToken: String, userInitiated: Bool = false) async {
        if userInitiated { isLoading = true }

        defer { if userInitiated { isLoading = false } }

        guard let userAgent = resolveUserAgent() else {
            presentReconnectRequired("Claude CLI not found")
            stopPolling()
            return
        }

        if preferHeadersFallback {
            oauthRecheckCounter += 1
            if oauthRecheckCounter < Self.oauthRecheckInterval {
                await fetchViaHeaders(with: accessToken, userAgent: userAgent, userInitiated: userInitiated)
                return
            }
            oauthRecheckCounter = 0
        }

        let result = await fetchViaOAuth(with: accessToken, userAgent: userAgent, userInitiated: userInitiated)

        if case .enterprise403 = result {
            preferHeadersFallback = true
            oauthRecheckCounter = 0
            await fetchViaHeaders(with: accessToken, userAgent: userAgent, userInitiated: userInitiated)
        }
    }

    private func fetchViaOAuth(with accessToken: String, userAgent: String, userInitiated: Bool) async -> FetchResult {
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        logger.info("Fetching usage via OAuth — User-Agent: \(userAgent)")

        do {
            let (data, response) = try await dependencies.fetchUsage(request)

            guard let httpResponse = response as? HTTPURLResponse else {
                presentRetryableIssue(
                    noUsageMessage: "Invalid response, retrying in \(Int(pollInterval))s",
                    staleMessage: "Stale response, retrying in \(Int(pollInterval))s"
                )
                schedulePollTimer()
                return .handled
            }

            guard httpResponse.statusCode == 200 else {
                let headers = httpResponse.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                logger.warning("OAuth HTTP \(httpResponse.statusCode) — headers: \(headers)")

                if httpResponse.statusCode == 429 {
                    let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
                    logger.warning("429 response body: \(body)")
                    lastRateLimitTime = dependencies.now()
                    consecutiveRateLimits += 1

                    if consecutiveRateLimits >= 3,
                       let freshToken = dependencies.refreshAccessTokenSilently(),
                       freshToken != accessToken {
                        cachedToken = freshToken
                        consecutiveRateLimits = 0
                        logger.info("Token refreshed after persistent 429s")
                        await performFetch(with: freshToken, userInitiated: userInitiated)
                        return .handled
                    }

                    let exponentialDelay = pollInterval * pow(2.0, Double(consecutiveRateLimits))
                    var backoffDelay = min(exponentialDelay, Self.maxBackoffInterval)
                    if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                       let retrySeconds = TimeInterval(retryAfter), retrySeconds > 0 {
                        backoffDelay = min(max(backoffDelay, retrySeconds), Self.maxBackoffInterval)
                    }

                    presentRetryableIssue(
                        noUsageMessage: "Rate limited, retrying in \(Int(backoffDelay))s",
                        staleMessage: "Stale, retrying in \(Int(backoffDelay))s"
                    )
                    logger.warning("Rate limited (429), backing off \(Int(backoffDelay))s (attempt \(self.consecutiveRateLimits))")
                    schedulePollTimer(interval: backoffDelay)
                    return .handled
                }

                if httpResponse.statusCode == 403 {
                    logger.info("OAuth returned 403 — enterprise account, trying headers fallback")
                    return .enterprise403
                }

                if httpResponse.statusCode == 401 {
                    await handleAuthFailure(currentToken: accessToken, userInitiated: userInitiated)
                    return .handled
                }

                presentRetryableIssue(
                    noUsageMessage: "HTTP \(httpResponse.statusCode), retrying in \(Int(pollInterval))s",
                    staleMessage: "Stale (HTTP \(httpResponse.statusCode)), retrying in \(Int(pollInterval))s"
                )
                schedulePollTimer()
                logger.warning("API error: HTTP \(httpResponse.statusCode)")
                return .handled
            }

            let usageResponse = try JSONDecoder().decode(UsageResponse.self, from: data)
            consecutiveRateLimits = 0
            lastRateLimitTime = nil
            isConnected = true
            preferHeadersFallback = false
            clearTransientState()
            currentUsage = usageResponse.fiveHour
            logger.info("Usage fetched via OAuth: \(self.currentUsage?.usagePercentage ?? 0)%")
            schedulePollTimer()
            return .success

        } catch {
            presentRetryableIssue(
                noUsageMessage: "Network error, retrying in \(Int(pollInterval))s",
                staleMessage: "Stale network data, retrying in \(Int(pollInterval))s"
            )
            logger.error("OAuth fetch failed: \(error.localizedDescription)")
            schedulePollTimer()
            return .handled
        }
    }

    @discardableResult
    private func fetchViaHeaders(with accessToken: String, userAgent: String, userInitiated: Bool) async -> FetchResult {
        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "x"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        logger.info("Fetching usage via headers fallback")

        do {
            let (_, response) = try await dependencies.fetchUsage(request)

            guard let httpResponse = response as? HTTPURLResponse else {
                presentRetryableIssue(
                    noUsageMessage: "Invalid response, retrying in \(Int(pollInterval))s",
                    staleMessage: "Stale response, retrying in \(Int(pollInterval))s"
                )
                schedulePollTimer()
                return .handled
            }

            if httpResponse.statusCode == 401 {
                await handleAuthFailure(currentToken: accessToken, userInitiated: userInitiated)
                return .handled
            }

            guard let utilization = parseHeaderUtilization(from: httpResponse) else {
                logger.debug("No unified rate limit headers in response")
                presentRetryableIssue(
                    noUsageMessage: "No rate limit headers, retrying in \(Int(pollInterval))s",
                    staleMessage: "Stale, retrying in \(Int(pollInterval))s"
                )
                schedulePollTimer()
                return .handled
            }

            let resetDate = parseHeaderResetDate(from: httpResponse)
            let usage = QuotaPeriod(utilization: (utilization * 100).rounded(), resetDate: resetDate)
            consecutiveRateLimits = 0
            lastRateLimitTime = nil
            isConnected = true
            clearTransientState()
            currentUsage = usage
            logger.info("Usage fetched via headers: \(usage.usagePercentage)%")
            schedulePollTimer()
            return .success

        } catch {
            presentRetryableIssue(
                noUsageMessage: "Network error, retrying in \(Int(pollInterval))s",
                staleMessage: "Stale network data, retrying in \(Int(pollInterval))s"
            )
            logger.error("Headers fetch failed: \(error.localizedDescription)")
            schedulePollTimer()
            return .handled
        }
    }

    private func handleAuthFailure(currentToken: String, userInitiated: Bool) async {
        cachedToken = nil
        preferHeadersFallback = false
        oauthRecheckCounter = 0
        dependencies.clearCachedOAuthToken()

        if let freshToken = dependencies.refreshAccessTokenSilently(),
           freshToken != currentToken {
            consecutiveRateLimits = 0
            cachedToken = freshToken
            logger.info("Token refreshed silently from Claude Code keychain")
            await performFetch(with: freshToken, userInitiated: userInitiated)
            return
        }

        presentReconnectRequired("Token expired")
        stopPolling()
    }

    private func parseHeaderUtilization(from response: HTTPURLResponse) -> Double? {
        guard let value = response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-utilization") else {
            return nil
        }
        return Double(value.trimmingCharacters(in: .whitespaces))
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic = ISO8601DateFormatter()

    private func parseHeaderResetDate(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-reset"),
              !value.isEmpty else {
            return nil
        }
        if let epoch = TimeInterval(value) {
            return Date(timeIntervalSince1970: epoch)
        }
        return Self.isoFractional.date(from: value) ?? Self.isoBasic.date(from: value)
    }

    private func resolveUserAgent() -> String? {
        if let resolvedUserAgent {
            return resolvedUserAgent
        }

        guard let resolved = dependencies.resolveUserAgent() else {
            return nil
        }

        resolvedUserAgent = resolved
        logger.info("User-Agent resolved: \(resolved)")
        return resolved
    }

    private func clearTransientState() {
        error = nil
        statusMessage = nil
        isUsageStale = false
        recoveryAction = .none
    }

    private func presentRetryableIssue(noUsageMessage: String, staleMessage: String) {
        recoveryAction = .retry
        if currentUsage == nil {
            error = noUsageMessage
            statusMessage = nil
            isUsageStale = false
        } else {
            error = nil
            statusMessage = staleMessage
            isUsageStale = true
        }
    }

    private func presentReconnectRequired(_ message: String) {
        recoveryAction = .reconnect
        isConnected = false
        if currentUsage == nil {
            error = message
            statusMessage = nil
            isUsageStale = false
        } else {
            error = nil
            statusMessage = message
            isUsageStale = true
        }
    }
}
