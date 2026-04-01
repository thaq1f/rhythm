import AVFoundation
import ServiceManagement
import SwiftUI

struct PanelSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var hooksError = false
    @State private var apiKeyInput = AppSettings.anthropicApiKey ?? ""
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var voiceCapture = VoiceCaptureService.shared
    private var keyListener: VoiceKeyListener { VoiceKeyListener.shared }
    private var usageConnected: Bool { ClaudeUsageService.shared.isConnected }
    private var hasApiKey: Bool { !apiKeyInput.isEmpty }
    private var hasActiveAgent: Bool { AgentSessionManager.shared.activeProvider?.isRunning == true }

    private var hookStatusText: String {
        if hooksError { return "Error" }
        if hooksInstalled { return "Installed" }
        return "Not Installed"
    }

    private var hookStatusColor: Color {
        hooksInstalled && !hooksError ? TerminalColors.green : TerminalColors.red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    displaySection
                    Divider().background(Color.white.opacity(0.08))
                    voiceSection
                    Divider().background(Color.white.opacity(0.08))
                    permissionsSection
                    Divider().background(Color.white.opacity(0.08))
                    agentSection
                    Divider().background(Color.white.opacity(0.08))
                    togglesSection
                    Divider().background(Color.white.opacity(0.08))
                    actionsSection
                }
                .padding(.top, 10)
            }
            .scrollIndicators(.hidden)

            Spacer()

            quitSection
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { VoiceOrchestrator.shared.recheckPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            VoiceOrchestrator.shared.recheckPermissions()
        }
    }

    // MARK: - Voice Settings

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("VOICE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(TerminalColors.dimmedText)
                .tracking(1)

            // Device picker
            VStack(alignment: .leading, spacing: 6) {
                SettingsRowView(icon: "waveform", title: "Input Device") {
                    EmptyView()
                }

                ForEach(voiceCapture.devices) { device in
                    Button(action: { voiceCapture.selectedDeviceID = device.id }) {
                        HStack(spacing: 8) {
                            Image(systemName: device.icon)
                                .font(.system(size: 11))
                                .foregroundColor(TerminalColors.secondaryText)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(TerminalColors.primaryText)
                                    .lineLimit(1)
                                Text(device.transportLabel)
                                    .font(.system(size: 9))
                                    .foregroundColor(TerminalColors.dimmedText)
                            }

                            Spacer()

                            if voiceCapture.selectedDeviceID == device.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(TerminalColors.green)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            voiceCapture.selectedDeviceID == device.id
                                ? Color.white.opacity(0.06) : Color.clear
                        )
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 20)
            }

            // Quality preset
            VStack(alignment: .leading, spacing: 6) {
                SettingsRowView(icon: "tuningfork", title: "Audio Quality") {
                    EmptyView()
                }

                HStack(spacing: 6) {
                    ForEach(AudioQualityPreset.allCases) { preset in
                        Button(action: { voiceCapture.qualityPreset = preset }) {
                            VStack(spacing: 2) {
                                Text(preset.rawValue)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(
                                        voiceCapture.qualityPreset == preset
                                            ? .white : TerminalColors.secondaryText
                                    )
                                Text("\(Int(preset.sampleRate / 1000))kHz")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundColor(TerminalColors.dimmedText)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                voiceCapture.qualityPreset == preset
                                    ? Color.white.opacity(0.1) : Color.white.opacity(0.04)
                            )
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 20)

                Text(voiceCapture.qualityPreset.description)
                    .font(.system(size: 9))
                    .foregroundColor(TerminalColors.dimmedText)
                    .padding(.leading, 20)
            }

            // Push to talk
            SettingsRowView(icon: "hand.raised", title: "Push to Talk") {
                Text("Hold Right ⌥ or Fn")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(TerminalColors.dimmedText)
                .tracking(1)

            // Microphone permission
            Button(action: {
                if voiceCapture.hasPermission {
                    // Already granted
                } else if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                    // Previously denied — must go to System Settings
                    openMicrophoneSettings()
                } else {
                    Task { await voiceCapture.requestPermission() }
                }
            }) {
                SettingsRowView(icon: "mic", title: "Microphone") {
                    statusBadge(
                        voiceCapture.hasPermission ? "Granted" : "Required",
                        color: voiceCapture.hasPermission ? TerminalColors.green : TerminalColors.red
                    )
                }
            }
            .buttonStyle(.plain)

            // Accessibility / Input Monitoring (required for Fn key)
            Button(action: openInputMonitoringSettings) {
                SettingsRowView(icon: "hand.raised", title: "Input Monitoring") {
                    HStack(spacing: 6) {
                        statusBadge(
                            keyListener.hasAccessibility ? "Granted" : "Required for Fn",
                            color: keyListener.hasAccessibility ? TerminalColors.green : TerminalColors.red
                        )
                        if !keyListener.hasAccessibility {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9))
                                .foregroundColor(TerminalColors.dimmedText)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if !keyListener.hasAccessibility {
                Text("Fn key push-to-talk requires Input Monitoring permission. Right ⌥ works without it.")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
                    .padding(.leading, 20)
            }
        }
    }

    private func openInputMonitoringSettings() {
        // macOS 26+: new System Settings URL scheme
        // macOS 14-15: x-apple.systempreferences scheme
        // Try most-specific first, fall back to broader privacy pane.
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for urlString in urls {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func openMicrophoneSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for urlString in urls {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    // MARK: - Agent Settings

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AGENTS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(TerminalColors.dimmedText)
                .tracking(1)

            Button(action: spawnNewSession) {
                SettingsRowView(icon: "plus.circle", title: "New Claude Session") {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .buttonStyle(.plain)

            if hasActiveAgent {
                Button(action: { AgentSessionManager.shared.terminateSession() }) {
                    SettingsRowView(icon: "stop.circle", title: "End Session") {
                        statusBadge("Running", color: TerminalColors.green)
                    }
                }
                .buttonStyle(.plain)
            }

            SettingsRowView(icon: "terminal", title: "Claude Code") {
                statusBadge(
                    claudeInstalled() ? "Installed" : "Not Found",
                    color: claudeInstalled() ? TerminalColors.green : TerminalColors.red
                )
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenPickerRow(screenSelector: ScreenSelector.shared)
            SoundPickerView()
        }
    }

    // MARK: - Toggles

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleLaunchAtLogin) {
                SettingsRowView(icon: "power", title: "Launch at Login") {
                    ToggleSwitch(isOn: launchAtLogin)
                }
            }
            .buttonStyle(.plain)

            Button(action: installHooksIfNeeded) {
                SettingsRowView(icon: "terminal", title: "Hooks") {
                    statusBadge(hookStatusText, color: hookStatusColor)
                }
            }
            .buttonStyle(.plain)

            Button(action: connectUsage) {
                SettingsRowView(icon: "gauge.with.dots.needle.33percent", title: "Claude Usage") {
                    statusBadge(
                        usageConnected ? "Connected" : "Not Connected",
                        color: usageConnected ? TerminalColors.green : TerminalColors.red
                    )
                }
            }
            .buttonStyle(.plain)

            apiKeyRow
        }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRowView(icon: "brain", title: "Emotion Analysis") {
                statusBadge(
                    hasApiKey ? "Active" : "No Key",
                    color: hasApiKey ? TerminalColors.green : TerminalColors.red
                )
            }

            HStack(spacing: 6) {
                SecureField("", text: $apiKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TerminalColors.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .onSubmit { saveApiKey() }
                    .overlay(alignment: .leading) {
                        if apiKeyInput.isEmpty {
                            Text("Anthropic API Key")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(TerminalColors.dimmedText)
                                .padding(.leading, 8)
                                .allowsHitTesting(false)
                        }
                    }

                Button(action: saveApiKey) {
                    Image(systemName: hasApiKey ? "checkmark.circle.fill" : "arrow.right.circle")
                        .font(.system(size: 14))
                        .foregroundColor(hasApiKey ? TerminalColors.green : TerminalColors.dimmedText)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 28)
        }
    }

    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.anthropicApiKey = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: handleUpdatesAction) {
                SettingsRowView(icon: "arrow.triangle.2.circlepath", title: "Check for Updates") {
                    updateStatusView
                }
            }
            .buttonStyle(.plain)

            Button(action: openGitHubRepo) {
                SettingsRowView(icon: "star", title: "Star on GitHub") {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(TerminalColors.dimmedText)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func openGitHubRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/thaq1f/rhythm")!)
    }

    private func openLatestReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/thaq1f/rhythm/releases/latest")!)
    }

    // MARK: - Quit

    private var quitSection: some View {
        Button(action: {
            AgentSessionManager.shared.terminateSession()
            NSApplication.shared.terminate(nil)
        }) {
            HStack {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13))
                Text("Quit Rhythm")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(TerminalColors.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(TerminalColors.red.opacity(0.1))
            .contentShape(Rectangle())
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private func connectUsage() {
        ClaudeUsageService.shared.connectAndStartPolling()
    }

    private func handleUpdatesAction() {
        if case .upToDate = updateManager.state {
            openLatestReleasePage()
        } else {
            updateManager.checkForUpdates()
        }
    }

    private func installHooksIfNeeded() {
        guard !hooksInstalled else { return }
        hooksError = false
        let success = HookInstaller.installIfNeeded()
        if success {
            hooksInstalled = HookInstaller.isInstalled()
        } else {
            hooksError = true
        }
    }

    private func spawnNewSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder to start Claude Code"
        panel.prompt = "Start Session"

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        panel.begin { response in
            defer { NSApp.setActivationPolicy(.accessory) }
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await AgentSessionManager.shared.startSession(in: url)
            }
        }
    }

    private func claudeInstalled() -> Bool {
        let paths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        return paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
            .frame(maxWidth: 160, alignment: .trailing)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .upToDate:
            statusBadge("Up to date", color: TerminalColors.green)
        case .updateAvailable:
            statusBadge("Update available", color: TerminalColors.amber)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Downloading...")
                    .font(.system(size: 10))
                    .foregroundColor(TerminalColors.dimmedText)
            }
        case .readyToInstall:
            statusBadge("Ready to install", color: TerminalColors.green)
        case .error(let failure):
            statusBadge(failure.label, color: TerminalColors.red)
        case .idle:
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.dimmedText)
        }
    }
}

struct SettingsRowView<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.secondaryText)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(TerminalColors.primaryText)
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ToggleSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? TerminalColors.green : Color.white.opacity(0.15))
                .frame(width: 32, height: 18)
            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

#Preview {
    PanelSettingsView()
        .frame(width: 402, height: 400)
        .background(Color.black)
}
