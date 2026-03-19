import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "ClaudeUsageService")

enum ClaudeUsageRecoveryAction: Equatable {
    case none
    case retry
    case reconnect
}

struct ClaudeUsageRecoverySnapshot: Codable, Equatable {
    let oauthBackoffUntil: Date?
    let oauthHeadersFallbackProbeUntil: Date?
    let isHeadersFallbackActive: Bool
    let didSucceedWithHeadersFallbackInOAuthBackoff: Bool
    let lastGoodUsage: QuotaPeriod?
}

protocol ClaudeUsagePollTimer {
    func invalidate()
}

struct ClaudeUsageServiceDependencies {
    var fetchUsage: (URLRequest) async throws -> (Data, URLResponse)
    var getAccessToken: () -> String?
    var getCachedOAuthToken: () -> String?
    var getOAuthCredentials: (_ allowInteraction: Bool) -> ClaudeOAuthCredentials?
    var cacheOAuthToken: (_ token: String) -> Void
    var refreshAccessTokenSilently: () -> String?
    var clearCachedOAuthToken: () -> Void
    var loadRecoverySnapshot: () -> ClaudeUsageRecoverySnapshot?
    var saveRecoverySnapshot: (ClaudeUsageRecoverySnapshot) -> Void
    var clearRecoverySnapshot: () -> Void
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
        getOAuthCredentials: { allowInteraction in
            KeychainManager.getOAuthCredentials(allowInteraction: allowInteraction)
        },
        cacheOAuthToken: { token in
            KeychainManager.cacheOAuthToken(token)
        },
        refreshAccessTokenSilently: {
            KeychainManager.refreshAccessTokenSilently()
        },
        clearCachedOAuthToken: {
            KeychainManager.clearCachedOAuthToken()
        },
        loadRecoverySnapshot: {
            AppSettings.claudeUsageRecoverySnapshot
        },
        saveRecoverySnapshot: { snapshot in
            AppSettings.claudeUsageRecoverySnapshot = snapshot
        },
        clearRecoverySnapshot: {
            AppSettings.claudeUsageRecoverySnapshot = nil
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
    private static let headersFallbackOAuthProbeInterval: TimeInterval = 600
    private static let headersFallbackRefreshInterval: TimeInterval = 60

    private let dependencies: ClaudeUsageServiceDependencies
    private var resolvedUserAgent: String?
    private var pollTimer: (any ClaudeUsagePollTimer)?
    private let pollInterval: TimeInterval = 60
    private var consecutiveRateLimits = 0
    private var cachedToken: String?
    private var preferHeadersFallback = false
    private var oauthRecheckCounter = 0
    private var oauthBackoffUntil: Date?
    private var oauthHeadersFallbackProbeUntil: Date?
    private var isHeadersFallbackActive = false
    private var didAttemptHeadersFallbackInOAuthBackoff = false
    private var didSucceedWithHeadersFallbackInOAuthBackoff = false

    init() {
        self.dependencies = .live
    }

    init(dependencies: ClaudeUsageServiceDependencies) {
        self.dependencies = dependencies
    }

    func connectAndStartPolling() {
        AppSettings.isUsageEnabled = true
        clearTransientState()
        clearOAuthBackoffState()
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
            let accessToken: String
            let silentCredentials = dependencies.getOAuthCredentials(false)

            if let cachedToken = dependencies.getCachedOAuthToken() {
                if let silentCredentials, silentCredentials.accessToken != cachedToken {
                    accessToken = silentCredentials.accessToken
                    dependencies.cacheOAuthToken(accessToken)
                    logger.info("Startup adopted Claude Code credential token over mismatched cached token")
                } else {
                    accessToken = cachedToken
                }
            } else if let silentCredentials {
                accessToken = silentCredentials.accessToken
                dependencies.cacheOAuthToken(accessToken)
                logger.info("Recovered cached OAuth token from Claude Code credentials for background polling")
            } else {
                logger.info("No cached token, user must connect manually")
                isConnected = false
                AppSettings.isUsageEnabled = false
                clearOAuthBackoffState()
                clearTransientState()
                return
            }

            AppSettings.isUsageEnabled = true
            cachedToken = accessToken

            restoreRecoverySnapshotIfNeeded()

            if isHeadersFallbackActive {
                if let remainingProbe = activeHeadersFallbackProbeRemaining() {
                    scheduleHeadersFallbackActiveTimer(remainingProbe: remainingProbe)
                } else {
                    await performFetch(with: accessToken)
                }
                return
            }

            if let remainingBackoff = activeOAuthBackoffRemaining() {
                presentOAuthBackoffState(
                    remaining: remainingBackoff,
                    usingHeadersFallback: didSucceedWithHeadersFallbackInOAuthBackoff
                )
                scheduleBackoffTimer(remaining: remainingBackoff)
                return
            }

            await performFetch(with: accessToken)
        }
    }

    func retryNow() {
        guard !isLoading else { return }
        if isHeadersFallbackActive {
            logger.info("Headers fallback is active, keeping current usage and waiting for the next refresh or OAuth probe")
            if let remainingProbe = activeHeadersFallbackProbeRemaining() {
                scheduleHeadersFallbackActiveTimer(remainingProbe: remainingProbe)
            } else {
                Task {
                    guard let accessToken = cachedToken else {
                        connectAndStartPolling()
                        return
                    }
                    await performFetch(with: accessToken, userInitiated: true)
                }
            }
            return
        }
        if let remainingBackoff = activeOAuthBackoffRemaining() {
            logger.info("OAuth backoff active, honoring retry cooldown window")
            Task {
                guard let accessToken = cachedToken else {
                    connectAndStartPolling()
                    return
                }
                await handleRetryDuringOAuthBackoff(
                    with: accessToken,
                    remaining: remainingBackoff
                )
            }
            return
        }

        clearTransientState()
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

    private func schedulePollTimer(interval: TimeInterval? = nil, minimumInterval: TimeInterval? = nil) {
        pollTimer?.invalidate()
        let baseInterval = interval ?? pollInterval
        let jitter = dependencies.pollJitter()
        let effectiveInterval = max(10, baseInterval + jitter, minimumInterval ?? 0)
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

        if isHeadersFallbackActive {
            if let remainingProbe = activeHeadersFallbackProbeRemaining() {
                logger.info("Refreshing usage via active headers fallback while OAuth probe is \(Int(remainingProbe))s away")
                await refreshActiveHeadersFallback(with: accessToken)
            } else {
                logger.info("Headers fallback OAuth probe due, retrying OAuth")
                await performFetch(with: accessToken)
            }
            return
        }

        if let remainingBackoff = activeOAuthBackoffRemaining() {
            logger.info("Skipping OAuth fetch while active backoff remains for \(Int(remainingBackoff))s")
            presentOAuthBackoffState(
                remaining: remainingBackoff,
                usingHeadersFallback: didSucceedWithHeadersFallbackInOAuthBackoff
            )
            scheduleBackoffTimer(remaining: remainingBackoff)
            return
        }

        await performFetch(with: accessToken)
    }

    private enum FetchResult {
        case success
        case handled
        case enterprise403
        case noHeadersFallback
    }

    private enum OAuth403Classification {
        case authScopeFailure(rawMessage: String, errorType: String?, requestID: String?)
        case enterpriseFallback(errorType: String?, requestID: String?)
    }

    private struct AnthropicErrorEnvelope: Decodable {
        let error: AnthropicErrorDetail?
        let requestID: String?

        enum CodingKeys: String, CodingKey {
            case error
            case requestID = "request_id"
        }
    }

    private struct AnthropicErrorDetail: Decodable {
        let type: String?
        let message: String?
    }

    private enum PreflightResult {
        case proceed(String)
        case handled
    }

    // Internal for unit tests that verify service state transitions directly.
    func performFetch(
        with accessToken: String,
        userInitiated: Bool = false,
        allow403EmptyHeadersRecovery: Bool = true,
        allowPreflightRefreshRecovery: Bool = true,
        allow401RefreshRecovery: Bool = true
    ) async {
        if userInitiated { isLoading = true }

        defer { if userInitiated { isLoading = false } }

        guard let userAgent = resolveUserAgent() else {
            presentReconnectRequired("Claude CLI not found")
            stopPolling()
            return
        }

        let preflight = await preflightCredentials(
            for: accessToken,
            userInitiated: userInitiated,
            allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
            allow401RefreshRecovery: allow401RefreshRecovery
        )
        let effectiveAccessToken: String
        switch preflight {
        case let .proceed(token):
            effectiveAccessToken = token
        case .handled:
            return
        }

        if preferHeadersFallback {
            oauthRecheckCounter += 1
            if oauthRecheckCounter < Self.oauthRecheckInterval {
                _ = await fetchViaHeaders(
                    with: effectiveAccessToken,
                    userAgent: userAgent,
                    userInitiated: userInitiated,
                    allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
                    allow401RefreshRecovery: allow401RefreshRecovery
                )
                return
            }
            oauthRecheckCounter = 0
        }

        let result = await fetchViaOAuth(
            with: effectiveAccessToken,
            userAgent: userAgent,
            userInitiated: userInitiated,
            allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
            allow401RefreshRecovery: allow401RefreshRecovery
        )

        if case .enterprise403 = result {
            preferHeadersFallback = true
            oauthRecheckCounter = 0
            let fallbackResult = await fetchViaHeaders(
                with: effectiveAccessToken,
                userAgent: userAgent,
                userInitiated: userInitiated,
                allowMissingHeadersRetry: false,
                allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
                allow401RefreshRecovery: allow401RefreshRecovery
            )
            if case .noHeadersFallback = fallbackResult {
                preferHeadersFallback = false
                if allow403EmptyHeadersRecovery {
                    await recoverFromEmptyHeadersFallback(afterOAuth403With: effectiveAccessToken, userInitiated: userInitiated)
                } else {
                    presentReconnectRequired("Claude authentication needs attention. Reconnect Claude Code.")
                    stopPolling()
                }
            }
        }
    }

    private func fetchViaOAuth(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool,
        allowPreflightRefreshRecovery: Bool,
        allow401RefreshRecovery: Bool
    ) async -> FetchResult {
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

                    beginOAuthBackoff(delay: backoffDelay)

                    if !didAttemptHeadersFallbackInOAuthBackoff {
                        didAttemptHeadersFallbackInOAuthBackoff = true
                        let hadCurrentUsage = currentUsage != nil
                        let fallbackResult = await fetchViaHeaders(
                            with: accessToken,
                            userAgent: userAgent,
                            userInitiated: userInitiated,
                            allowMissingHeadersRetry: false,
                            oauthBackoffDelay: backoffDelay,
                            allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
                            allow401RefreshRecovery: allow401RefreshRecovery
                        )
                        if case .success = fallbackResult {
                            logger.info(
                                "Rate limited (429), using headers fallback with \(Int(Self.headersFallbackRefreshInterval))s refreshes and OAuth re-probe in \(Int(Self.headersFallbackOAuthProbeInterval))s"
                            )
                            return .handled
                        }
                        if hadCurrentUsage {
                            clearTransientState()
                            beginHeadersFallbackProbeWindow()
                            logger.info("Keeping last good usage visible after OAuth 429 while waiting for refreshed headers")
                            scheduleHeadersFallbackActiveTimer()
                            return .handled
                        }
                    }

                    logger.warning("Rate limited (429), backing off \(Int(backoffDelay))s (attempt \(self.consecutiveRateLimits))")
                    presentOAuthBackoffState(remaining: backoffDelay, usingHeadersFallback: false)
                    scheduleBackoffTimer(remaining: backoffDelay)
                    return .handled
                }

                if httpResponse.statusCode == 403 {
                    return handleOAuthForbidden(data: data, response: httpResponse)
                }

                if httpResponse.statusCode == 401 {
                    await handleAuthFailure(
                        currentToken: accessToken,
                        userInitiated: userInitiated,
                        allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
                        allow401RefreshRecovery: allow401RefreshRecovery
                    )
                    return .handled
                }

                clearOAuthBackoffState()
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
            clearOAuthBackoffState()
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
    private func fetchViaHeaders(
        with accessToken: String,
        userAgent: String,
        userInitiated: Bool,
        allowMissingHeadersRetry: Bool = true,
        oauthBackoffDelay: TimeInterval? = nil,
        activeFallbackRefresh: Bool = false,
        allowPreflightRefreshRecovery: Bool = true,
        allow401RefreshRecovery: Bool = true
    ) async -> FetchResult {
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
                if activeFallbackRefresh {
                    return handleActiveHeadersFallbackMiss(logMessage: "Headers fallback returned invalid response during active fallback refresh")
                }
                if oauthBackoffDelay != nil {
                    logger.warning("Headers fallback returned invalid response during OAuth backoff")
                    return .noHeadersFallback
                }
                presentRetryableIssue(
                    noUsageMessage: "Invalid response, retrying in \(Int(pollInterval))s",
                    staleMessage: "Stale response, retrying in \(Int(pollInterval))s"
                )
                schedulePollTimer()
                return .handled
            }

            if httpResponse.statusCode == 401 {
                await handleAuthFailure(
                    currentToken: accessToken,
                    userInitiated: userInitiated,
                    allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
                    allow401RefreshRecovery: allow401RefreshRecovery
                )
                return .handled
            }

            guard let utilization = parseHeaderUtilization(from: httpResponse) else {
                if activeFallbackRefresh {
                    return handleActiveHeadersFallbackMiss(logMessage: "No unified rate limit headers in active fallback refresh response")
                }
                logger.debug("No unified rate limit headers in response")
                if allowMissingHeadersRetry {
                    presentRetryableIssue(
                        noUsageMessage: "No rate limit headers, retrying in \(Int(pollInterval))s",
                        staleMessage: "Stale, retrying in \(Int(pollInterval))s"
                    )
                    schedulePollTimer()
                }
                return .noHeadersFallback
            }

            let resetDate = parseHeaderResetDate(from: httpResponse)
            let usage = QuotaPeriod(utilization: (utilization * 100).rounded(), resetDate: resetDate)
            isConnected = true
            currentUsage = usage

            if activeFallbackRefresh {
                didSucceedWithHeadersFallbackInOAuthBackoff = true
                clearTransientState()
                persistRecoverySnapshotIfNeeded()
                logger.info("Usage refreshed via active headers fallback: \(usage.usagePercentage)%")
                scheduleHeadersFallbackActiveTimer()
                return .success
            }

            if oauthBackoffDelay != nil {
                didSucceedWithHeadersFallbackInOAuthBackoff = true
                clearTransientState()
                beginHeadersFallbackProbeWindow()
                logger.info("Usage fetched via headers during OAuth backoff: \(usage.usagePercentage)%")
                scheduleHeadersFallbackActiveTimer()
                return .success
            }

            consecutiveRateLimits = 0
            clearOAuthBackoffState()
            clearTransientState()
            logger.info("Usage fetched via headers: \(usage.usagePercentage)%")
            schedulePollTimer()
            return .success

        } catch {
            if activeFallbackRefresh {
                return handleActiveHeadersFallbackMiss(logMessage: "Headers fetch failed during active fallback refresh: \(error.localizedDescription)")
            }
            if oauthBackoffDelay != nil {
                logger.error("Headers fetch failed during OAuth backoff: \(error.localizedDescription)")
                return .noHeadersFallback
            }
            presentRetryableIssue(
                noUsageMessage: "Network error, retrying in \(Int(pollInterval))s",
                staleMessage: "Stale network data, retrying in \(Int(pollInterval))s"
            )
            logger.error("Headers fetch failed: \(error.localizedDescription)")
            schedulePollTimer()
            return .handled
        }
    }

    private func refreshActiveHeadersFallback(with accessToken: String) async {
        guard let userAgent = resolveUserAgent() else {
            presentReconnectRequired("Claude CLI not found")
            stopPolling()
            return
        }

        _ = await fetchViaHeaders(
            with: accessToken,
            userAgent: userAgent,
            userInitiated: false,
            allowMissingHeadersRetry: false,
            activeFallbackRefresh: true
        )
    }

    private func handleAuthFailure(
        currentToken: String,
        userInitiated: Bool,
        allowPreflightRefreshRecovery: Bool,
        allow401RefreshRecovery: Bool
    ) async {
        cachedToken = nil
        clearOAuthBackoffState()
        preferHeadersFallback = false
        oauthRecheckCounter = 0
        dependencies.clearCachedOAuthToken()

        if allow401RefreshRecovery,
           let freshToken = dependencies.refreshAccessTokenSilently(),
           freshToken != currentToken {
            consecutiveRateLimits = 0
            cachedToken = freshToken
            logger.info("Token refreshed silently from Claude Code keychain")
            await performFetch(
                with: freshToken,
                userInitiated: userInitiated,
                allowPreflightRefreshRecovery: allowPreflightRefreshRecovery,
                allow401RefreshRecovery: false
            )
            return
        }

        presentReconnectRequired("Token expired")
        stopPolling()
    }

    private func preflightCredentials(
        for accessToken: String,
        userInitiated: Bool,
        allowPreflightRefreshRecovery: Bool,
        allow401RefreshRecovery: Bool
    ) async -> PreflightResult {
        guard let credentials = dependencies.getOAuthCredentials(userInitiated) else {
            return .proceed(accessToken)
        }

        let usesCredentialMetadata: Bool
        let effectiveAccessToken: String

        if userInitiated {
            usesCredentialMetadata = true
            effectiveAccessToken = credentials.accessToken
            if effectiveAccessToken != accessToken {
                cachedToken = effectiveAccessToken
            }
        } else if credentials.accessToken == accessToken {
            usesCredentialMetadata = true
            effectiveAccessToken = accessToken
        } else {
            usesCredentialMetadata = false
            effectiveAccessToken = accessToken
            logger.info("Silent OAuth credential metadata token mismatch; using cached token")
        }

        if usesCredentialMetadata,
           !credentials.scopes.isEmpty,
           !credentials.scopes.contains("user:profile") {
            presentReconnectRequired("Claude OAuth permissions missing. Reconnect Claude Code.")
            stopPolling()
            return .handled
        }

        if usesCredentialMetadata,
           let expiresAt = credentials.expiresAt,
           expiresAt <= dependencies.now() {
            logger.info("Local OAuth credential metadata shows expired token before request")

            if allowPreflightRefreshRecovery,
               let freshToken = dependencies.refreshAccessTokenSilently(),
               freshToken != effectiveAccessToken {
                cachedToken = freshToken
                consecutiveRateLimits = 0
                logger.info("Token refreshed silently from local credential preflight")
                await performFetch(
                    with: freshToken,
                    userInitiated: userInitiated,
                    allowPreflightRefreshRecovery: false,
                    allow401RefreshRecovery: allow401RefreshRecovery
                )
                return .handled
            }

            presentReconnectRequired("Token expired")
            stopPolling()
            return .handled
        }

        return .proceed(effectiveAccessToken)
    }

    private func recoverFromEmptyHeadersFallback(afterOAuth403With currentToken: String, userInitiated: Bool) async {
        logger.info("OAuth 403 with empty headers fallback triggered silent refresh recovery")
        cachedToken = nil
        clearOAuthBackoffState()
        dependencies.clearCachedOAuthToken()

        if let freshToken = dependencies.refreshAccessTokenSilently(),
           freshToken != currentToken {
            cachedToken = freshToken
            consecutiveRateLimits = 0
            await performFetch(
                with: freshToken,
                userInitiated: userInitiated,
                allow403EmptyHeadersRecovery: false
            )
            return
        }

        presentReconnectRequired("Claude authentication needs attention. Reconnect Claude Code.")
        stopPolling()
    }

    private func handleOAuthForbidden(data: Data, response: HTTPURLResponse) -> FetchResult {
        let classification = classifyOAuth403(data: data, response: response)

        switch classification {
        case let .authScopeFailure(rawMessage, errorType, requestID):
            let errorTypeLog = errorType ?? "unknown"
            let requestIDLog = requestID ?? "none"
            logger.warning(
                "OAuth 403 requires reconnect - errorType: \(errorTypeLog, privacy: .public), requestID: \(requestIDLog, privacy: .public), message: \(rawMessage, privacy: .public)"
            )
            presentReconnectRequired("Claude OAuth permissions missing. Reconnect Claude Code.")
            stopPolling()
            return .handled

        case let .enterpriseFallback(errorType, requestID):
            let errorTypeLog = errorType ?? "unknown"
            let requestIDLog = requestID ?? "none"
            logger.info(
                "OAuth 403 trying headers fallback - errorType: \(errorTypeLog, privacy: .public), requestID: \(requestIDLog, privacy: .public)"
            )
            return .enterprise403
        }
    }

    private func classifyOAuth403(data: Data, response: HTTPURLResponse) -> OAuth403Classification {
        guard !data.isEmpty,
              let envelope = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) else {
            return .enterpriseFallback(
                errorType: nil,
                requestID: response.value(forHTTPHeaderField: "request-id")
            )
        }

        let errorType = envelope.error?.type?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestID = envelope.requestID ?? response.value(forHTTPHeaderField: "request-id")

        guard errorType == "permission_error",
              let message,
              isExplicitOAuthScopeFailure(message: message) else {
            return .enterpriseFallback(errorType: errorType, requestID: requestID)
        }

        return .authScopeFailure(
            rawMessage: message,
            errorType: errorType,
            requestID: requestID
        )
    }

    private func isExplicitOAuthScopeFailure(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("user:profile")
            || normalized.contains("missing scope")
            || normalized.contains("scope requirement")
            || (normalized.contains("oauth") && normalized.contains("scope"))
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

    private func activeOAuthBackoffRemaining() -> TimeInterval? {
        guard let oauthBackoffUntil else {
            return nil
        }

        let remaining = oauthBackoffUntil.timeIntervalSince(dependencies.now())
        if remaining > 0 {
            return remaining
        }

        clearOAuthBackoffState()
        return nil
    }

    private func activeHeadersFallbackProbeRemaining() -> TimeInterval? {
        guard isHeadersFallbackActive,
              let currentProbeUntil = oauthHeadersFallbackProbeUntil else {
            return nil
        }

        let remaining = currentProbeUntil.timeIntervalSince(dependencies.now())
        if remaining > 0 {
            return remaining
        }
        return nil
    }

    private func beginOAuthBackoff(delay: TimeInterval) {
        let now = dependencies.now()
        let newBackoffUntil = now.addingTimeInterval(delay)
        isHeadersFallbackActive = false
        oauthHeadersFallbackProbeUntil = nil
        didSucceedWithHeadersFallbackInOAuthBackoff = false

        if let currentBackoffUntil = oauthBackoffUntil,
           currentBackoffUntil > now {
            oauthBackoffUntil = max(currentBackoffUntil, newBackoffUntil)
            return
        }

        oauthBackoffUntil = newBackoffUntil
        didAttemptHeadersFallbackInOAuthBackoff = false
        didSucceedWithHeadersFallbackInOAuthBackoff = false
        persistRecoverySnapshotIfNeeded()
    }

    private func clearOAuthBackoffState() {
        oauthBackoffUntil = nil
        oauthHeadersFallbackProbeUntil = nil
        isHeadersFallbackActive = false
        didAttemptHeadersFallbackInOAuthBackoff = false
        didSucceedWithHeadersFallbackInOAuthBackoff = false
        dependencies.clearRecoverySnapshot()
    }

    private func beginHeadersFallbackProbeWindow() {
        oauthBackoffUntil = nil
        consecutiveRateLimits = 0
        isHeadersFallbackActive = true
        oauthHeadersFallbackProbeUntil = dependencies.now().addingTimeInterval(Self.headersFallbackOAuthProbeInterval)
        didAttemptHeadersFallbackInOAuthBackoff = false
        didSucceedWithHeadersFallbackInOAuthBackoff = true
        persistRecoverySnapshotIfNeeded()
    }

    private func scheduleBackoffTimer(remaining: TimeInterval) {
        let baseInterval = max(remaining, pollInterval)
        schedulePollTimer(interval: baseInterval, minimumInterval: remaining)
    }

    private func scheduleHeadersFallbackActiveTimer(remainingProbe: TimeInterval? = nil) {
        let probeRemaining = remainingProbe ?? activeHeadersFallbackProbeRemaining()
        guard let probeRemaining else {
            clearOAuthBackoffState()
            schedulePollTimer()
            return
        }
        let nextInterval = min(Self.headersFallbackRefreshInterval, probeRemaining)
        schedulePollTimer(interval: nextInterval, minimumInterval: nextInterval)
    }

    private func presentOAuthBackoffState(remaining: TimeInterval, usingHeadersFallback: Bool) {
        recoveryAction = .retry
        let roundedDelay = Int(ceil(remaining))

        if currentUsage == nil {
            error = "Rate limited, retrying in \(roundedDelay)s"
            statusMessage = nil
            isUsageStale = false
            return
        }

        error = nil
        statusMessage = usingHeadersFallback
            ? "Fallback due to rate limit, retry in \(roundedDelay)s"
            : "Stale, retrying in \(roundedDelay)s"
        isUsageStale = true
    }

    private func handleRetryDuringOAuthBackoff(with accessToken: String, remaining: TimeInterval) async {
        if !didAttemptHeadersFallbackInOAuthBackoff {
            guard let userAgent = resolveUserAgent() else {
                presentReconnectRequired("Claude CLI not found")
                stopPolling()
                return
            }

            didAttemptHeadersFallbackInOAuthBackoff = true
            let fallbackResult = await fetchViaHeaders(
                with: accessToken,
                userAgent: userAgent,
                userInitiated: true,
                allowMissingHeadersRetry: false,
                oauthBackoffDelay: remaining
            )
            if case .success = fallbackResult {
                return
            }
        }

        presentOAuthBackoffState(
            remaining: remaining,
            usingHeadersFallback: didSucceedWithHeadersFallbackInOAuthBackoff
        )
        scheduleBackoffTimer(remaining: remaining)
    }

    private func handleActiveHeadersFallbackMiss(logMessage: String) -> FetchResult {
        logger.warning("\(logMessage, privacy: .public)")

        guard currentUsage != nil else {
            clearOAuthBackoffState()
            presentRetryableIssue(
                noUsageMessage: "No rate limit headers, retrying in \(Int(pollInterval))s",
                staleMessage: "Stale, retrying in \(Int(pollInterval))s"
            )
            schedulePollTimer()
            return .handled
        }

        didSucceedWithHeadersFallbackInOAuthBackoff = true
        clearTransientState()
        persistRecoverySnapshotIfNeeded()
        scheduleHeadersFallbackActiveTimer()
        return .handled
    }

    private func restoreRecoverySnapshotIfNeeded() {
        guard let snapshot = dependencies.loadRecoverySnapshot() else {
            return
        }

        let now = dependencies.now()
        let hasActiveHeadersFallback = snapshot.isHeadersFallbackActive
            && snapshot.oauthHeadersFallbackProbeUntil.map({ $0 > now }) ?? false
        let hasActiveOAuthBackoff = snapshot.oauthBackoffUntil.map({ $0 > now }) ?? false

        guard hasActiveHeadersFallback || hasActiveOAuthBackoff else {
            dependencies.clearRecoverySnapshot()
            return
        }

        currentUsage = isUsageStillValid(snapshot.lastGoodUsage, now: now) ? snapshot.lastGoodUsage : nil
        oauthBackoffUntil = hasActiveOAuthBackoff ? snapshot.oauthBackoffUntil : nil
        oauthHeadersFallbackProbeUntil = hasActiveHeadersFallback ? snapshot.oauthHeadersFallbackProbeUntil : nil
        isHeadersFallbackActive = hasActiveHeadersFallback
        didSucceedWithHeadersFallbackInOAuthBackoff = snapshot.didSucceedWithHeadersFallbackInOAuthBackoff
        didAttemptHeadersFallbackInOAuthBackoff = false

        if hasActiveHeadersFallback, currentUsage != nil {
            isConnected = true
            clearTransientState()
            logger.info("Restored active headers fallback recovery state from persistence")
        } else if hasActiveOAuthBackoff {
            logger.info("Restored OAuth backoff recovery state from persistence")
        }
    }

    private func persistRecoverySnapshotIfNeeded() {
        guard let snapshot = makeRecoverySnapshot() else {
            dependencies.clearRecoverySnapshot()
            return
        }
        dependencies.saveRecoverySnapshot(snapshot)
    }

    private func makeRecoverySnapshot() -> ClaudeUsageRecoverySnapshot? {
        guard oauthBackoffUntil != nil
            || (isHeadersFallbackActive && oauthHeadersFallbackProbeUntil != nil) else {
            return nil
        }

        let usageToPersist = isUsageStillValid(currentUsage, now: dependencies.now()) ? currentUsage : nil
        return ClaudeUsageRecoverySnapshot(
            oauthBackoffUntil: oauthBackoffUntil,
            oauthHeadersFallbackProbeUntil: oauthHeadersFallbackProbeUntil,
            isHeadersFallbackActive: isHeadersFallbackActive,
            didSucceedWithHeadersFallbackInOAuthBackoff: didSucceedWithHeadersFallbackInOAuthBackoff,
            lastGoodUsage: usageToPersist
        )
    }

    private func isUsageStillValid(_ usage: QuotaPeriod?, now: Date) -> Bool {
        guard let usage, let resetDate = usage.resetDate else {
            return false
        }
        return resetDate > now
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
