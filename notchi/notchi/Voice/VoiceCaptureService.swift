import AVFoundation
import Combine
import CoreAudio
import os.log

extension Notification.Name {
    static let voiceMaxDurationReached = Notification.Name("voiceMaxDurationReached")
}

private let logger = Logger(subsystem: "com.ruban.rhythm", category: "VoiceCapture")

/// Audio format presets for different use cases
enum AudioQualityPreset: String, CaseIterable, Identifiable {
    case standard = "Standard"       // 16kHz mono, ideal for ASR
    case high = "High Quality"       // 44.1kHz mono, good for voice
    case lossless = "Lossless"       // 48kHz stereo, studio quality

    var id: String { rawValue }

    var sampleRate: Double {
        switch self {
        case .standard: return 16_000
        case .high: return 44_100
        case .lossless: return 48_000
        }
    }

    var channels: AVAudioChannelCount {
        switch self {
        case .standard, .high: return 1
        case .lossless: return 2
        }
    }

    var bitDepth: Int {
        switch self {
        case .standard: return 16
        case .high: return 16
        case .lossless: return 24
        }
    }

    var description: String {
        switch self {
        case .standard: return "\(Int(sampleRate / 1000))kHz · Mono · Optimized for speech"
        case .high: return "\(Int(sampleRate / 1000))kHz · Mono · Balanced quality"
        case .lossless: return "\(Int(sampleRate / 1000))kHz · Stereo · Full fidelity"
        }
    }
}

/// Audio device info
struct AudioDeviceInfo: Identifiable, Hashable {
    let id: String           // uniqueID
    let name: String         // localizedName
    let manufacturer: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
    let isUSB: Bool
    let sampleRates: [Double]

    var icon: String {
        if isBluetooth { return "airpodspro" }
        if isUSB { return "cable.connector" }
        if isBuiltIn { return "laptopcomputer" }
        return "mic"
    }

    var transportLabel: String {
        if isBluetooth { return "Bluetooth" }
        if isUSB { return "USB" }
        if isBuiltIn { return "Built-in" }
        return "External"
    }
}

/// Microphone capture service with device selection, quality presets,
/// and compatibility with Bluetooth/USB/wired audio devices.
@MainActor
final class VoiceCaptureService: NSObject, ObservableObject {
    static let shared = VoiceCaptureService()

    // Published state
    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var audioDB: Float = -60
    @Published private(set) var hasPermission = false
    @Published private(set) var devices: [AudioDeviceInfo] = []
    @Published var selectedDeviceID: String? {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: "rhythm_selected_mic") }
    }
    @Published var qualityPreset: AudioQualityPreset = .standard {
        didSet { UserDefaults.standard.set(qualityPreset.rawValue, forKey: "rhythm_audio_quality") }
    }

    private(set) var audioBuffers: [AVAudioPCMBuffer] = []

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var tempFileURL: URL?
    private let captureQueue = DispatchQueue(label: "com.rhythm.voice.capture", qos: .userInteractive)
    private var levelSmoothingFactor: Float = 0.3
    private var deviceObserver: NSObjectProtocol?

    private override init() {
        super.init()

        // Restore saved preferences
        if let savedDevice = UserDefaults.standard.string(forKey: "rhythm_selected_mic") {
            selectedDeviceID = savedDevice
        }
        if let savedQuality = UserDefaults.standard.string(forKey: "rhythm_audio_quality"),
           let preset = AudioQualityPreset(rawValue: savedQuality) {
            qualityPreset = preset
        }

        refreshDevices()
        observeDeviceChanges()
    }

    deinit {
        if let observer = deviceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.hasPermission = granted
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func checkPermission() {
        hasPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Device Discovery

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        devices = discovery.devices.map { device in
            let transportType = getTransportType(for: device)
            let sampleRates = getSupportedSampleRates(for: device)

            return AudioDeviceInfo(
                id: device.uniqueID,
                name: device.localizedName,
                manufacturer: device.manufacturer,
                isBuiltIn: transportType == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transportType == kAudioDeviceTransportTypeBluetooth
                    || transportType == kAudioDeviceTransportTypeBluetoothLE,
                isUSB: transportType == kAudioDeviceTransportTypeUSB,
                sampleRates: sampleRates
            )
        }

        // Auto-select default if no selection or selection is gone
        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        logger.info("Found \(self.devices.count) audio devices")
    }

    private func observeDeviceChanges() {
        // Watch for audio device connect/disconnect
        deviceObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AVCaptureDeviceWasConnectedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }

        // Also listen for disconnects
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AVCaptureDeviceWasDisconnectedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    /// Get the CoreAudio transport type for a device (built-in, bluetooth, USB, etc.)
    private nonisolated func getTransportType(for device: AVCaptureDevice) -> AudioDevicePropertyID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        // Find the CoreAudio device ID matching this AVCaptureDevice
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceCount: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &deviceCount)
        let count = Int(deviceCount) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &deviceCount, &deviceIDs)

        for id in deviceIDs {
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid)

            if uid as String == device.uniqueID {
                deviceID = id
                break
            }
        }

        guard deviceID != 0 else { return 0 }

        var transportType: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &size, &transportType)

        return transportType
    }

    /// Get supported sample rates for a device
    private nonisolated func getSupportedSampleRates(for device: AVCaptureDevice) -> [Double] {
        // Most audio devices support these standard rates
        return [16_000, 22_050, 44_100, 48_000, 96_000]
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        guard hasPermission else {
            logger.warning("No microphone permission")
            return
        }

        audioBuffers.removeAll()
        isRecording = true  // Set immediately so caller sees it

        // Capture values needed off-main-thread
        let deviceID = selectedDeviceID
        let preset = qualityPreset
        let queue = captureQueue

        DiagLog.shared.write("CAPTURE: Starting (device=\(deviceID ?? "default"), preset=\(preset.rawValue))")

        // ALL AVCaptureSession work happens off the main thread.
        // addInput/addOutput/startRunning can all block — never call on main queue.
        captureQueue.async { [weak self] in
            let session = AVCaptureSession()

            switch preset {
            case .standard: session.sessionPreset = .medium
            case .high:     session.sessionPreset = .high
            case .lossless: session.sessionPreset = .high
            }

            let device: AVCaptureDevice?
            if let deviceID {
                device = AVCaptureDevice(uniqueID: deviceID)
            } else {
                device = AVCaptureDevice.default(for: .audio)
            }

            guard let audioDevice = device else {
                Task { @MainActor in
                    self?.isRecording = false
                    DiagLog.shared.write("CAPTURE: ❌ No audio device")
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(input) { session.addInput(input) }

                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: queue)
                // Use device native format — resampled to 16kHz mono in stopRecording()
                if session.canAddOutput(output) { session.addOutput(output) }

                session.startRunning()
                let running = session.isRunning
                let name = audioDevice.localizedName

                Task { @MainActor in
                    guard let self else { return }
                    if running {
                        self.captureSession = session
                        self.audioOutput = output
                        self.tempFileURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("rhythm-\(UUID().uuidString).wav")
                        DiagLog.shared.write("CAPTURE: ✅ Running (\(name) @ \(preset.rawValue))")
                    } else {
                        self.isRecording = false
                        DiagLog.shared.write("CAPTURE: ❌ Session failed to start")
                    }
                }
            } catch {
                Task { @MainActor in
                    self?.isRecording = false
                    DiagLog.shared.write("CAPTURE: ❌ \(error.localizedDescription)")
                }
            }
        }
    }

    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        let session = captureSession
        captureSession = nil
        audioOutput = nil
        isRecording = false
        audioLevel = 0
        audioDB = -60
        captureQueue.async { session?.stopRunning() }

        // Grab buffers and clear immediately to free memory.
        let buffers = audioBuffers
        audioBuffers.removeAll()
        guard !buffers.isEmpty, let fileURL = tempFileURL else { return nil }

        // Resample synchronously but with the data already captured.
        // This runs on the main actor but with bounded data (max 15s).
        do {
            let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let outputFile = try AVAudioFile(forWriting: fileURL, settings: outputFormat.settings)
            for buffer in buffers {
                if let converted = resample(buffer: buffer, to: outputFormat) {
                    try outputFile.write(from: converted)
                }
            }
            return fileURL
        } catch {
            logger.error("Failed to write audio: \(error.localizedDescription)")
            return nil
        }
    }

    func cancelRecording() {
        let session = captureSession
        captureSession = nil
        audioOutput = nil
        isRecording = false
        captureQueue.async { session?.stopRunning() }
        audioLevel = 0
        audioBuffers.removeAll()
        if let url = tempFileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Resampling

    private func resample(buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Skip if already in target format
        if buffer.format.sampleRate == targetFormat.sampleRate
            && buffer.format.channelCount == targetFormat.channelCount {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return error == nil ? outputBuffer : nil
    }

    // MARK: - Level Metering

    private nonisolated func processLevel(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let data = dataPointer else { return }

        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }
        let floats = data.withMemoryRebound(to: Float.self, capacity: floatCount) {
            UnsafeBufferPointer(start: $0, count: floatCount)
        }

        var sum: Float = 0
        for sample in floats { sum += sample * sample }
        let rms = sqrt(sum / Float(floats.count))
        let db = 20 * log10(max(rms, 1e-6))

        Task { @MainActor in
            self.audioDB = db
            let normalized = max(0, min(1, (db + 60) / 60))
            self.audioLevel = self.audioLevel * (1 - self.levelSmoothingFactor) + normalized * self.levelSmoothingFactor
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension VoiceCaptureService: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processLevel(from: sampleBuffer)

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let avFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate,
                  channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
                  interleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
              )
        else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        if let data = dataPointer, let channelData = pcmBuffer.floatChannelData {
            memcpy(channelData[0], data, min(length, Int(pcmBuffer.frameCapacity) * MemoryLayout<Float>.size))
        }

        Task { @MainActor in
            self.audioBuffers.append(pcmBuffer)
        }
    }
}
