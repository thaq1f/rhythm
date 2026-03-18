import Foundation
import XCTest
@testable import notchi

private struct TestPollTimer: ClaudeUsagePollTimer {
    func invalidate() {}
}

@MainActor
private final class PollSchedulerSpy {
    private(set) var intervals: [TimeInterval] = []

    func schedule(after interval: TimeInterval, handler: @escaping () -> Void) -> any ClaudeUsagePollTimer {
        intervals.append(interval)
        return TestPollTimer()
    }
}

@MainActor
final class ClaudeUsageServiceTests: XCTestCase {
    func testSuccessfulFetchClearsStaleStateAndSchedulesNormalPolling() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.1.77")
                return (self.makeSuccessPayload(utilization: 42), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.currentUsage = makeQuotaPeriod(utilization: 8)
        service.error = "Old error"
        service.statusMessage = "Stale, retrying in 120s"
        service.isUsageStale = true
        service.recoveryAction = .retry

        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testManualRetryResetsRateLimitCounter() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var responses: [(Data, URLResponse)] = [
            (Data(), makeResponse(statusCode: 429)),
            (Data(), makeResponse(statusCode: 429)),
            (Data(), makeResponse(statusCode: 429)),
            (Data(), makeResponse(statusCode: 429)),
        ]
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { _ in
                responses.removeFirst()
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()
        now = now.addingTimeInterval(20)
        await service.performFetch(with: "token")
        await service.performFetch(with: "token")
        now = now.addingTimeInterval(11)
        service.retryNow()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(service.error, "Rate limited, retrying in 120s")
        XCTAssertEqual(scheduler.intervals, [120, 240, 480, 120])
    }

    func testRateLimitWithoutCachedUsageShowsRetryState() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (Data(), self.makeResponse(statusCode: 429, headers: ["Retry-After": "0"]))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Rate limited, retrying in 120s")
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [120])
    }

    func testPositiveRetryAfterHeaderRaisesBackoffDelay() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                (Data(), self.makeResponse(statusCode: 429, headers: ["Retry-After": "300"]))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(service.error, "Rate limited, retrying in 300s")
        XCTAssertEqual(scheduler.intervals, [300])
    }

    func testRateLimitWithCachedUsageKeepsUsageButMarksItStale() async throws {
        let scheduler = PollSchedulerSpy()
        var responses: [(Data, URLResponse)] = [
            (makeSuccessPayload(utilization: 55), makeResponse(statusCode: 200)),
            (Data(), makeResponse(statusCode: 429)),
        ]
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { _ in
                responses.removeFirst()
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.statusMessage, "Stale, retrying in 120s")
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [60, 120])
    }

    func testRetryCooldownShowsVisibleFeedback() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { _ in
                (Data(), self.makeResponse(statusCode: 429))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()
        service.retryNow()

        XCTAssertEqual(service.statusMessage, "Please wait before retrying again")
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [120])
    }

    func testMissingClaudeCLIStopsBeforeSendingRequest() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCalled = false
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { nil },
            fetchUsage: { _ in
                fetchCalled = true
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertFalse(fetchCalled)
        XCTAssertEqual(service.error, "Claude CLI not found")
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testConnectAndStartPollingUsesInteractiveTokenLookup() async throws {
        let scheduler = PollSchedulerSpy()
        var getAccessTokenCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getAccessToken: {
                getAccessTokenCalls += 1
                return nil
            },
            fetchUsage: { _ in
                XCTFail("fetchUsage should not run without a token")
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(getAccessTokenCalls, 1)
        XCTAssertEqual(service.error, "Keychain access required")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
        XCTAssertFalse(AppSettings.isUsageEnabled)
    }

    func testStartPollingDisablesUsageWhenNoCachedTokenExists() async throws {
        let scheduler = PollSchedulerSpy()
        var getCachedTokenCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: {
                getCachedTokenCalls += 1
                return nil
            },
            fetchUsage: { _ in
                XCTFail("fetchUsage should not run without a cached token")
                return (Data(), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        AppSettings.isUsageEnabled = true
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(getCachedTokenCalls, 1)
        XCTAssertFalse(AppSettings.isUsageEnabled)
        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testUnauthorizedFetchRefreshesTokenOnceAndRecovers() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var clearCachedTokenCalls = 0
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "new-token"
            },
            clearCachedOAuthToken: {
                clearCachedTokenCalls += 1
            },
            fetchUsage: { request in
                let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                authHeaders.append(authHeader)
                if authHeader == "Bearer old-token" {
                    return (Data(), self.makeResponse(statusCode: 401))
                }
                return (self.makeSuccessPayload(utilization: 33), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(clearCachedTokenCalls, 1)
        XCTAssertEqual(authHeaders, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 33)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testThreeConsecutiveRateLimitsRefreshTokenAndRetry() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var authHeaders: [String] = []
        var responses: [(Data, URLResponse)] = [
            (Data(), makeResponse(statusCode: 429)),
            (Data(), makeResponse(statusCode: 429)),
            (Data(), makeResponse(statusCode: 429)),
            (makeSuccessPayload(utilization: 64), makeResponse(statusCode: 200)),
        ]
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "fresh-token"
            },
            fetchUsage: { request in
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "<missing>")
                return responses.removeFirst()
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")
        await service.performFetch(with: "old-token")
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(authHeaders, ["Bearer old-token", "Bearer old-token", "Bearer old-token", "Bearer fresh-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 64)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [120, 240, 60])
    }

    private func makeDependencies(
        scheduler: PollSchedulerSpy,
        resolveUserAgent: @escaping () -> String?,
        getAccessToken: @escaping () -> String? = { nil },
        getCachedOAuthToken: @escaping () -> String? = { nil },
        refreshAccessTokenSilently: @escaping () -> String? = { nil },
        clearCachedOAuthToken: @escaping () -> Void = {},
        now: @escaping () -> Date = { Date() },
        fetchUsage: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> ClaudeUsageServiceDependencies {
        ClaudeUsageServiceDependencies(
            fetchUsage: fetchUsage,
            getAccessToken: getAccessToken,
            getCachedOAuthToken: getCachedOAuthToken,
            refreshAccessTokenSilently: refreshAccessTokenSilently,
            clearCachedOAuthToken: clearCachedOAuthToken,
            resolveUserAgent: resolveUserAgent,
            pollJitter: { 0 },
            now: now,
            schedulePoll: { interval, handler in
                scheduler.schedule(after: interval, handler: handler)
            }
        )
    }

    private func makeSuccessPayload(utilization: Double) -> Data {
        let json = """
        {
          "five_hour": {
            "utilization": \(utilization),
            "resets_at": "2099-01-01T01:00:00Z"
          },
          "seven_day": null
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Enterprise Headers Fallback

    func testOAuth403TriggersHeadersFallbackAndSucceeds() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.42",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertTrue(service.isConnected)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testOAuth403ThenHeadersFallbackFailsWithNoHeaders() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "No rate limit headers, retrying in 60s")
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testOAuth403ThenHeaders401ClearsToken() async throws {
        let scheduler = PollSchedulerSpy()
        var clearCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            clearCachedOAuthToken: { clearCalls += 1 },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeResponse(statusCode: 401, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(clearCalls, 1)
        XCTAssertEqual(service.error, "Token expired")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertFalse(service.isConnected)
    }

    func testCachedFallbackSkipsOAuth() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.50",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        requestURLs.removeAll()
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 50)
    }

    func testOAuthRecheckAfterTenPolls() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.30",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        // First call: OAuth 403 → headers fallback
        await service.performFetch(with: "token")
        requestURLs.removeAll()

        // Polls 2-10: headers only (9 polls, counter goes 1-9)
        for _ in 0..<9 {
            await service.performFetch(with: "token")
        }
        let headerOnlyURLs = requestURLs
        requestURLs.removeAll()

        // Poll 11: counter hits 10, rechecks OAuth
        await service.performFetch(with: "token")

        XCTAssertEqual(headerOnlyURLs, Array(repeating: "/v1/messages", count: 9))
        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
    }

    func testOAuthRecheckSucceedsAfterAccountUpgrade() async throws {
        let scheduler = PollSchedulerSpy()
        var oauthCallCount = 0
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    oauthCallCount += 1
                    if oauthCallCount == 1 {
                        return (Data(), self.makeResponse(statusCode: 403))
                    }
                    return (self.makeSuccessPayload(utilization: 25), self.makeResponse(statusCode: 200))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.30",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        // First call: OAuth 403 → headers fallback
        await service.performFetch(with: "token")

        // 9 more polls (headers only)
        for _ in 0..<9 {
            await service.performFetch(with: "token")
        }

        // Poll 11: recheck OAuth → now succeeds (account upgraded)
        requestURLs.removeAll()
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 25)

        // Next poll should go to OAuth directly (preferHeadersFallback cleared)
        requestURLs.removeAll()
        await service.performFetch(with: "token")
        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
    }

    func testHeadersUtilizationScaling() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(
                    utilization: "0.75",
                    reset: "2099-01-01T01:00:00Z"
                ))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 75)
    }

    func testOAuth401StillClearsToken() async throws {
        let scheduler = PollSchedulerSpy()
        var clearCalls = 0
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: { "new-token" },
            clearCachedOAuthToken: { clearCalls += 1 },
            fetchUsage: { request in
                let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                authHeaders.append(authHeader)
                if authHeader == "Bearer old-token" {
                    return (Data(), self.makeResponse(statusCode: 401))
                }
                return (self.makeSuccessPayload(utilization: 33), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")

        XCTAssertEqual(clearCalls, 1)
        XCTAssertEqual(authHeaders, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 33)
    }

    func testOAuth403ThenHeadersNetworkErrorShowsFallbackError() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                throw URLError(.notConnectedToInternet)
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(service.error, "Network error, retrying in 60s")
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testMissingResetHeaderHandledGracefully() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(utilization: "0.60", reset: nil))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(service.currentUsage?.usagePercentage, 60)
        XCTAssertNil(service.currentUsage?.resetDate)
        XCTAssertTrue(service.isConnected)
    }

    func testHeaders429WithNoRateLimitHeadersShowsRetryableError() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeResponse(statusCode: 429, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "No rate limit headers, retrying in 60s")
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testMalformedUtilizationHeaderTreatedAsMissing() async throws {
        let scheduler = PollSchedulerSpy()
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 403))
                }
                return (Data(), self.makeHeadersResponse(utilization: "not-a-number", reset: nil))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "No rate limit headers, retrying in 60s")
        XCTAssertEqual(service.recoveryAction, .retry)
    }

    // MARK: - Helpers

    private var messagesURL: URL { URL(string: "https://api.anthropic.com/v1/messages")! }

    private func makeQuotaPeriod(utilization: Double) -> QuotaPeriod {
        QuotaPeriod(utilization: utilization, resetsAt: "2099-01-01T01:00:00Z")
    }

    private func makeResponse(statusCode: Int, headers: [String: String] = [:], url: URL? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    private func makeHeadersResponse(utilization: String, reset: String?, statusCode: Int = 200) -> HTTPURLResponse {
        var headers: [String: String] = [
            "anthropic-ratelimit-unified-5h-utilization": utilization,
        ]
        if let reset {
            headers["anthropic-ratelimit-unified-5h-reset"] = reset
        }
        return HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}
