import Foundation
import XCTest
@testable import notchi

private struct TestPollTimer: ClaudeUsagePollTimer {
    func invalidate() {}
}

@MainActor
private final class PollSchedulerSpy {
    private(set) var intervals: [TimeInterval] = []
    private var handlers: [() -> Void] = []

    func schedule(after interval: TimeInterval, handler: @escaping () -> Void) -> any ClaudeUsagePollTimer {
        intervals.append(interval)
        handlers.append(handler)
        return TestPollTimer()
    }

    func fireLast() {
        handlers.last?()
    }
}

@MainActor
final class ClaudeUsageServiceTests: XCTestCase {
    override func tearDown() {
        AppSettings.isUsageEnabled = false
        AppSettings.claudeUsageRecoverySnapshot = nil
        super.tearDown()
    }

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

    func testStartPollingDuringActiveHeadersFallbackDoesNotSendOAuthImmediately() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429))
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.currentUsage = self.makeQuotaPeriod(utilization: 46)
        await service.performFetch(with: "token")
        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])

        requestURLs.removeAll()
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(requestURLs.isEmpty)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 46)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testStartPollingRestoresPersistedActiveHeadersFallbackState() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var fetchCalled = false
        let snapshot = makeRecoverySnapshot(
            oauthHeadersFallbackProbeUntil: now.addingTimeInterval(600),
            isHeadersFallbackActive: true,
            didSucceedWithHeadersFallbackInOAuthBackoff: true,
            lastGoodUsage: makeQuotaPeriod(utilization: 46)
        )
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            loadRecoverySnapshot: { snapshot },
            now: { now },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 20), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(fetchCalled)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 46)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testStartPollingRestoresPersistedOAuthBackoffState() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var fetchCalled = false
        let snapshot = makeRecoverySnapshot(
            oauthBackoffUntil: now.addingTimeInterval(120),
            lastGoodUsage: makeQuotaPeriod(utilization: 52)
        )
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            loadRecoverySnapshot: { snapshot },
            now: { now },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 20), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(fetchCalled)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 52)
        XCTAssertNil(service.error)
        XCTAssertEqual(service.statusMessage, "Stale, retrying in 120s")
        XCTAssertTrue(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [120])
    }

    func testExpiredPersistedRecoveryStateIsClearedAndLiveFetchRuns() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var clearCalls = 0
        var requestURLs: [String] = []
        let snapshot = makeRecoverySnapshot(
            oauthBackoffUntil: now.addingTimeInterval(-5),
            lastGoodUsage: makeQuotaPeriod(utilization: 40)
        )
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            loadRecoverySnapshot: { snapshot },
            clearRecoverySnapshot: { clearCalls += 1 },
            now: { now },
            fetchUsage: { request in
                requestURLs.append(request.url?.path ?? "")
                return (self.makeSuccessPayload(utilization: 33), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(clearCalls, 2)
        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 33)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testSuccessfulOAuthAfterRestoredBackoffClearsPersistedRecoveryState() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var storedSnapshot: ClaudeUsageRecoverySnapshot? = makeRecoverySnapshot(
            oauthBackoffUntil: now.addingTimeInterval(5),
            lastGoodUsage: makeQuotaPeriod(utilization: 41)
        )
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            loadRecoverySnapshot: { storedSnapshot },
            saveRecoverySnapshot: { storedSnapshot = $0 },
            clearRecoverySnapshot: { storedSnapshot = nil },
            now: { now },
            fetchUsage: { request in
                requestURLs.append(request.url?.path ?? "")
                return (self.makeSuccessPayload(utilization: 35), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()
        XCTAssertNotNil(storedSnapshot)
        XCTAssertTrue(requestURLs.isEmpty)

        now = now.addingTimeInterval(6)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertNil(storedSnapshot)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 35)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testConnectAndStartPollingClearsPersistedRecoveryState() async throws {
        let scheduler = PollSchedulerSpy()
        var clearCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getAccessToken: { "token" },
            clearRecoverySnapshot: { clearCalls += 1 },
            fetchUsage: { _ in
                (self.makeSuccessPayload(utilization: 27), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.connectAndStartPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(clearCalls, 2)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 27)
    }

    func testRateLimitWithoutCachedUsageShowsRetryState() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429, headers: ["Retry-After": "0"]))
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Rate limited, retrying in 120s")
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [120])
    }

    func testPositiveRetryAfterHeaderRaisesBackoffDelay() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429, headers: ["Retry-After": "300"]))
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.error, "Rate limited, retrying in 300s")
        XCTAssertEqual(scheduler.intervals, [300])
    }

    func testRateLimitWithCachedUsageKeepsLastGoodValueCurrentDuringActiveFallback() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                switch requestURLs.count {
                case 1:
                    return (self.makeSuccessPayload(utilization: 55), self.makeResponse(statusCode: 200))
                case 2:
                    return (Data(), self.makeResponse(statusCode: 429))
                default:
                    XCTAssertEqual(path, "/v1/messages")
                    return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                }
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 55)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testManualRetryDuringActiveBackoffDoesNotSendOAuthAgainWhenHeadersAlreadyTried() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429))
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()
        service.retryNow()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.error, "Rate limited, retrying in 120s")
        XCTAssertNil(service.statusMessage)
        XCTAssertEqual(service.recoveryAction, .retry)
        XCTAssertEqual(scheduler.intervals, [120, 120])
    }

    func testRetryAfterBackoffExpiryUsesOAuthAgainAndClearsBackoffState() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                switch requestURLs.count {
                case 1:
                    return (Data(), self.makeResponse(statusCode: 429))
                case 2:
                    XCTAssertEqual(path, "/v1/messages")
                    return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                default:
                    XCTAssertEqual(path, "/api/oauth/usage")
                    return (self.makeSuccessPayload(utilization: 37), self.makeResponse(statusCode: 200))
                }
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        now = now.addingTimeInterval(121)
        service.retryNow()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages", "/api/oauth/usage"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 37)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [120, 60])
    }

    func testSuccessfulHeadersFallbackDefersOAuthProbeForTenMinutes() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        var oauthRequests = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    oauthRequests += 1
                    if oauthRequests == 1 {
                        return (Data(), self.makeResponse(statusCode: 429))
                    }
                    XCTAssertEqual(path, "/api/oauth/usage")
                    return (self.makeSuccessPayload(utilization: 37), self.makeResponse(statusCode: 200))
                }
                XCTAssertEqual(path, "/v1/messages")
                return (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: "0.41",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 41)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])

        requestURLs.removeAll()
        now = now.addingTimeInterval(60)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 41)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])

        requestURLs.removeAll()
        now = Date(timeIntervalSince1970: 701)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 37)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60, 60])
    }

    func testRetryDuringSuccessfulHeadersFallbackDoesNotForceOAuthProbe() async throws {
        let scheduler = PollSchedulerSpy()
        let now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429))
                }
                return (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: "0.42",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        service.retryNow()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testActiveHeadersFallbackRefreshUsesHeadersAndKeepsUsageCurrent() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        var headerRefreshes = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429))
                }

                headerRefreshes += 1
                return (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: headerRefreshes == 1 ? "0.42" : "0.43",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        requestURLs.removeAll()
        now = now.addingTimeInterval(60)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 43)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testActiveHeadersFallbackMissKeepsLastGoodUsageVisible() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        var headerRefreshes = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429))
                }

                headerRefreshes += 1
                if headerRefreshes == 1 {
                    return (
                        Data(),
                        self.makeHeadersResponse(
                            utilization: "0.42",
                            reset: "2099-01-01T01:00:00Z"
                        )
                    )
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        requestURLs.removeAll()
        now = now.addingTimeInterval(60)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
    }

    func testOAuthProbe429RestartsHeadersFallbackCycleCleanly() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        var oauthRequests = 0
        var headerRefreshes = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    oauthRequests += 1
                    return (Data(), self.makeResponse(statusCode: 429))
                }

                headerRefreshes += 1
                return (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: headerRefreshes == 1 ? "0.42" : "0.45",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        requestURLs.removeAll()
        now = Date(timeIntervalSince1970: 701)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 45)
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
        XCTAssertEqual(oauthRequests, 2)
    }

    func testHeadersFallbackResetsRateLimitCounterBeforeLaterOAuthProbe() async throws {
        let scheduler = PollSchedulerSpy()
        var now = Date(timeIntervalSince1970: 100)
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "token" },
            now: { now },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (Data(), self.makeResponse(statusCode: 429))
                }
                return (
                    Data(),
                    self.makeHeadersResponse(
                        utilization: "0.42",
                        reset: "2099-01-01T01:00:00Z"
                    )
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        requestURLs.removeAll()
        now = Date(timeIntervalSince1970: 701)
        scheduler.fireLast()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertNil(service.error)
        XCTAssertNil(service.statusMessage)
        XCTAssertFalse(service.isUsageStale)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60, 60])
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

    func testStartPollingRecoversCachedTokenFromSilentCredentials() async throws {
        let scheduler = PollSchedulerSpy()
        var cachedTokens: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { nil },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "silent-token",
                    scopes: ["user:profile"]
                )
            },
            cacheOAuthToken: { token in
                cachedTokens.append(token)
            },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer silent-token")
                return (self.makeSuccessPayload(utilization: 27), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(cachedTokens, ["silent-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 27)
        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testStartPollingPrefersMismatchedSilentCredentialsOverCachedToken() async throws {
        let scheduler = PollSchedulerSpy()
        var cachedTokens: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getCachedOAuthToken: { "stale-cached-token" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "fresh-claude-token",
                    scopes: ["user:profile"]
                )
            },
            cacheOAuthToken: { token in
                cachedTokens.append(token)
            },
            fetchUsage: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-claude-token")
                return (self.makeSuccessPayload(utilization: 31), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        service.startPolling()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(cachedTokens, ["fresh-claude-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 31)
        XCTAssertTrue(AppSettings.isUsageEnabled)
        XCTAssertEqual(scheduler.intervals, [60])
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

    func testLocalPreflightBlocksOAuthWhenScopeIsMissing() async throws {
        let scheduler = PollSchedulerSpy()
        var fetchCalled = false
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertTrue(allowInteraction)
                return self.makeCredentials(accessToken: "token", scopes: ["openid"])
            },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 20), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token", userInitiated: true)

        XCTAssertFalse(fetchCalled)
        XCTAssertEqual(service.error, "Claude OAuth permissions missing. Reconnect Claude Code.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testLocalPreflightSilentlyRefreshesExpiredToken() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var authHeaders: [String] = []
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "cached-token",
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "fresh-token"
            },
            now: { now },
            fetchUsage: { request in
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "<missing>")
                return (self.makeSuccessPayload(utilization: 34), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "cached-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(authHeaders, ["Bearer fresh-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 34)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testLocalPreflightExpiredTokenSameRefreshTokenReconnectsWithoutNetwork() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var fetchCalled = false
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "cached-token",
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "cached-token"
            },
            now: { now },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 34), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "cached-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertFalse(fetchCalled)
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Token expired")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testLocalPreflightExpiredTokenOnlyRefreshesOncePerFetchCycle() async throws {
        let scheduler = PollSchedulerSpy()
        var credentialReads = 0
        var refreshCalls = 0
        var fetchCalled = false
        let expiredDate = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                credentialReads += 1
                let token = credentialReads == 1 ? "cached-token" : "fresh-token-1"
                return self.makeCredentials(
                    accessToken: token,
                    expiresAt: expiredDate,
                    scopes: ["user:profile"]
                )
            },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return refreshCalls == 1 ? "fresh-token-1" : "fresh-token-2"
            },
            now: { now },
            fetchUsage: { _ in
                fetchCalled = true
                return (self.makeSuccessPayload(utilization: 34), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "cached-token")

        XCTAssertEqual(credentialReads, 2)
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertFalse(fetchCalled)
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Token expired")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testManualFetchPrefersInteractiveCredentialsWhenTokenMismatchExists() async throws {
        let scheduler = PollSchedulerSpy()
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertTrue(allowInteraction)
                return self.makeCredentials(
                    accessToken: "interactive-fresh-token",
                    scopes: ["user:profile"]
                )
            },
            fetchUsage: { request in
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "<missing>")
                return (self.makeSuccessPayload(utilization: 44), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "stale-cached-token", userInitiated: true)

        XCTAssertEqual(authHeaders, ["Bearer interactive-fresh-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 44)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testBackgroundFetchKeepsCachedTokenWhenSilentCredentialsMismatch() async throws {
        let scheduler = PollSchedulerSpy()
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            getOAuthCredentials: { allowInteraction in
                XCTAssertFalse(allowInteraction)
                return self.makeCredentials(
                    accessToken: "different-silent-token",
                    scopes: ["user:profile"]
                )
            },
            fetchUsage: { request in
                authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "<missing>")
                return (self.makeSuccessPayload(utilization: 22), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "cached-background-token")

        XCTAssertEqual(authHeaders, ["Bearer cached-background-token"])
        XCTAssertEqual(service.currentUsage?.usagePercentage, 22)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testOAuth401SameRefreshTokenReconnectsWithoutSecondRetry() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var clearCachedTokenCalls = 0
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "old-token"
            },
            clearCachedOAuthToken: {
                clearCachedTokenCalls += 1
            },
            fetchUsage: { request in
                let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                authHeaders.append(authHeader)
                return (Data(), self.makeResponse(statusCode: 401))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(clearCachedTokenCalls, 1)
        XCTAssertEqual(authHeaders, ["Bearer old-token"])
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Token expired")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testOAuth401OnlyRefreshesOncePerFetchCycle() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var clearCachedTokenCalls = 0
        var authHeaders: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return refreshCalls == 1 ? "new-token-1" : "new-token-2"
            },
            clearCachedOAuthToken: {
                clearCachedTokenCalls += 1
            },
            fetchUsage: { request in
                let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                authHeaders.append(authHeader)
                return (Data(), self.makeResponse(statusCode: 401))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(clearCachedTokenCalls, 2)
        XCTAssertEqual(authHeaders, ["Bearer old-token", "Bearer new-token-1"])
        XCTAssertNil(service.currentUsage)
        XCTAssertEqual(service.error, "Token expired")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testThreeConsecutiveRateLimitsRefreshTokenAndRetry() async throws {
        let scheduler = PollSchedulerSpy()
        var refreshCalls = 0
        var requests: [String] = []
        var oauthCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "fresh-token"
            },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                let authHeader = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                requests.append("\(path) \(authHeader)")
                if path == "/v1/messages" {
                    return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                }
                oauthCalls += 1
                if oauthCalls <= 3 {
                    return (Data(), self.makeResponse(statusCode: 429))
                }
                return (self.makeSuccessPayload(utilization: 64), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")
        await service.performFetch(with: "old-token")
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(
            requests,
            [
                "/api/oauth/usage Bearer old-token",
                "/v1/messages Bearer old-token",
                "/api/oauth/usage Bearer old-token",
                "/api/oauth/usage Bearer old-token",
                "/api/oauth/usage Bearer fresh-token",
            ]
        )
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
        getOAuthCredentials: @escaping (_ allowInteraction: Bool) -> ClaudeOAuthCredentials? = { _ in nil },
        cacheOAuthToken: @escaping (_ token: String) -> Void = { _ in },
        refreshAccessTokenSilently: @escaping () -> String? = { nil },
        clearCachedOAuthToken: @escaping () -> Void = {},
        loadRecoverySnapshot: @escaping () -> ClaudeUsageRecoverySnapshot? = { nil },
        saveRecoverySnapshot: @escaping (ClaudeUsageRecoverySnapshot) -> Void = { _ in },
        clearRecoverySnapshot: @escaping () -> Void = {},
        now: @escaping () -> Date = { Date() },
        fetchUsage: @escaping (URLRequest) async throws -> (Data, URLResponse)
    ) -> ClaudeUsageServiceDependencies {
        ClaudeUsageServiceDependencies(
            fetchUsage: fetchUsage,
            getAccessToken: getAccessToken,
            getCachedOAuthToken: getCachedOAuthToken,
            getOAuthCredentials: getOAuthCredentials,
            cacheOAuthToken: cacheOAuthToken,
            refreshAccessTokenSilently: refreshAccessTokenSilently,
            clearCachedOAuthToken: clearCachedOAuthToken,
            loadRecoverySnapshot: loadRecoverySnapshot,
            saveRecoverySnapshot: saveRecoverySnapshot,
            clearRecoverySnapshot: clearRecoverySnapshot,
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

    func testOAuth403WithExplicitScopeErrorDoesNotFallbackToHeaders() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                return (
                    self.makeAnthropicErrorPayload(
                        type: "permission_error",
                        message: "Claude OAuth token does not meet scope requirement 'user:profile'."
                    ),
                    self.makeResponse(statusCode: 403)
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertEqual(service.error, "Claude OAuth permissions missing. Reconnect Claude Code.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testOAuth403WithGenericOAuthScopeErrorDoesNotFallbackToHeaders() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                return (
                    self.makeAnthropicErrorPayload(
                        type: "permission_error",
                        message: "OAuth token scope is invalid"
                    ),
                    self.makeResponse(statusCode: 403)
                )
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "token")

        XCTAssertEqual(requestURLs, ["/api/oauth/usage"])
        XCTAssertEqual(service.error, "Claude OAuth permissions missing. Reconnect Claude Code.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
    }

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

    func testOAuth403HeadersFallbackDoesNotPersist429RecoveryState() async throws {
        let scheduler = PollSchedulerSpy()
        var savedSnapshots: [ClaudeUsageRecoverySnapshot] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            saveRecoverySnapshot: { savedSnapshots.append($0) },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
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

        XCTAssertTrue(savedSnapshots.isEmpty)
        XCTAssertEqual(service.currentUsage?.usagePercentage, 42)
    }

    func testOAuth403WithAmbiguousJSONStillFallsBackToHeaders() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (
                        self.makeAnthropicErrorPayload(
                            type: "permission_error",
                            message: "Your account does not have permission to use this resource."
                        ),
                        self.makeResponse(statusCode: 403)
                    )
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
        XCTAssertEqual(service.recoveryAction, .none)
    }

    func testOAuth403WithNonPermissionErrorAndScopeTextStillFallsBackToHeaders() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (
                        self.makeAnthropicErrorPayload(
                            type: "invalid_request_error",
                            message: "OAuth token scope is invalid"
                        ),
                        self.makeResponse(statusCode: 403)
                    )
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
        XCTAssertEqual(service.recoveryAction, .none)
    }

    func testOAuth403WithEmptyBodyStillFallsBackToHeaders() async throws {
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
        XCTAssertEqual(service.recoveryAction, .none)
    }

    func testOAuth403WithEmptyHeadersFallbackRefreshesAndRecovers() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        var clearCalls = 0
        var refreshCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "fresh-token"
            },
            clearCachedOAuthToken: {
                clearCalls += 1
            },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? "<missing>"
                requestURLs.append("\(path) \(auth)")
                if path == "/api/oauth/usage", auth == "Bearer old-token" {
                    return (
                        self.makeAnthropicErrorPayload(
                            type: "forbidden",
                            message: "Access forbidden"
                        ),
                        self.makeResponse(statusCode: 403)
                    )
                }
                if path == "/v1/messages" {
                    return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
                }
                return (self.makeSuccessPayload(utilization: 28), self.makeResponse(statusCode: 200))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(clearCalls, 1)
        XCTAssertEqual(
            requestURLs,
            [
                "/api/oauth/usage Bearer old-token",
                "/v1/messages Bearer old-token",
                "/api/oauth/usage Bearer fresh-token",
            ]
        )
        XCTAssertEqual(service.currentUsage?.usagePercentage, 28)
        XCTAssertEqual(service.recoveryAction, .none)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testOAuth403WithEmptyHeadersFallbackReconnectsWithoutRefreshLoop() async throws {
        let scheduler = PollSchedulerSpy()
        var requestURLs: [String] = []
        var clearCalls = 0
        var refreshCalls = 0
        let dependencies = makeDependencies(
            scheduler: scheduler,
            resolveUserAgent: { "claude-code/2.1.77" },
            refreshAccessTokenSilently: {
                refreshCalls += 1
                return "old-token"
            },
            clearCachedOAuthToken: {
                clearCalls += 1
            },
            fetchUsage: { request in
                let path = request.url?.path ?? ""
                requestURLs.append(path)
                if path == "/api/oauth/usage" {
                    return (
                        self.makeAnthropicErrorPayload(
                            type: "forbidden",
                            message: "Access forbidden"
                        ),
                        self.makeResponse(statusCode: 403)
                    )
                }
                return (Data(), self.makeResponse(statusCode: 200, url: self.messagesURL))
            }
        )

        let service = ClaudeUsageService(dependencies: dependencies)
        await service.performFetch(with: "old-token")

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(clearCalls, 1)
        XCTAssertEqual(requestURLs, ["/api/oauth/usage", "/v1/messages"])
        XCTAssertEqual(service.error, "Claude authentication needs attention. Reconnect Claude Code.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    func testOAuth403ThenHeadersFallbackFailsWithNoHeadersAndReconnects() async throws {
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
        XCTAssertEqual(service.error, "Claude authentication needs attention. Reconnect Claude Code.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
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
        XCTAssertEqual(service.error, "Claude authentication needs attention. Reconnect Claude Code.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
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
        XCTAssertEqual(service.error, "Claude authentication needs attention. Reconnect Claude Code.")
        XCTAssertEqual(service.recoveryAction, .reconnect)
        XCTAssertTrue(scheduler.intervals.isEmpty)
    }

    // MARK: - Helpers

    private var messagesURL: URL { URL(string: "https://api.anthropic.com/v1/messages")! }

    private func makeQuotaPeriod(utilization: Double) -> QuotaPeriod {
        QuotaPeriod(utilization: utilization, resetsAt: "2099-01-01T01:00:00Z")
    }

    private func makeRecoverySnapshot(
        oauthBackoffUntil: Date? = nil,
        oauthHeadersFallbackProbeUntil: Date? = nil,
        isHeadersFallbackActive: Bool = false,
        didSucceedWithHeadersFallbackInOAuthBackoff: Bool = false,
        lastGoodUsage: QuotaPeriod? = nil
    ) -> ClaudeUsageRecoverySnapshot {
        ClaudeUsageRecoverySnapshot(
            oauthBackoffUntil: oauthBackoffUntil,
            oauthHeadersFallbackProbeUntil: oauthHeadersFallbackProbeUntil,
            isHeadersFallbackActive: isHeadersFallbackActive,
            didSucceedWithHeadersFallbackInOAuthBackoff: didSucceedWithHeadersFallbackInOAuthBackoff,
            lastGoodUsage: lastGoodUsage
        )
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

    private func makeAnthropicErrorPayload(
        type: String,
        message: String,
        requestID: String = "req_test_123"
    ) -> Data {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": type,
                "message": message,
            ],
            "request_id": requestID,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func makeCredentials(
        accessToken: String,
        expiresAt: Date? = nil,
        scopes: Set<String> = []
    ) -> ClaudeOAuthCredentials {
        ClaudeOAuthCredentials(
            accessToken: accessToken,
            expiresAt: expiresAt,
            scopes: scopes
        )
    }
}
