import AppKit
import Sparkle

@MainActor
final class RhythmUpdateUserDriver: NSObject, SPUUserDriver {
    private let standardUserDriver: SPUStandardUserDriver
    private let shouldHandleUpdaterErrorsInline: () -> Bool
    private let didFinishCustomSession: () -> Void

    init(
        standardUserDriver: SPUStandardUserDriver,
        shouldHandleUpdaterErrorsInline: @escaping () -> Bool,
        didFinishCustomSession: @escaping () -> Void
    ) {
        self.standardUserDriver = standardUserDriver
        self.shouldHandleUpdaterErrorsInline = shouldHandleUpdaterErrorsInline
        self.didFinishCustomSession = didFinishCustomSession
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standardUserDriver.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standardUserDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standardUserDriver.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standardUserDriver.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standardUserDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        didFinishCustomSession()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if shouldHandleUpdaterErrorsInline() {
            acknowledgement()
            didFinishCustomSession()
            return
        }

        standardUserDriver.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standardUserDriver.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standardUserDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standardUserDriver.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        standardUserDriver.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standardUserDriver.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standardUserDriver.showReady(toInstallAndRelaunch: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standardUserDriver.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standardUserDriver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        standardUserDriver.dismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        standardUserDriver.showUpdateInFocus()
    }
}
