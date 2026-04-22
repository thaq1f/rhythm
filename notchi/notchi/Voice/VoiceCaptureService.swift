import AVFoundation
import Combine
import CoreAudio
import os.log

extension Notification.Name {
    static let voiceMaxDurationReached = Notification.Name("voiceMaxDurationReached")
}

private let logger = Logger(subsystem: "com.silca.rhythm", category: "VoiceCapture")

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

    // Lock-protected state for cross-queue synchronization.
    // captureOutput() appends buffers on captureQueue; stopRecording() drains on main actor.
    private let captureLock = NSLock()
    nonisolated(unsafe) private var captureQueueBuffers: [AVAudioPCMBuffer] = []
    nonisolated(unsafe) private var activeSession: AVCaptureSession?

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
        guard !isRecording else {
            DiagLog.shared.write("CAPTURE: startRecording() skipped — already recording")
            return
        }
        guard hasPermission else {
            logger.warning("No microphone permission")
            DiagLog.shared.write("CAPTURE: startRecording() skipped — no permission")
            return
        }

        audioBuffers.removeAll()
        isRecording = true  // Set immediately so caller sees it
        tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhythm-\(UUID().uuidString).wav")

        captureLock.lock()
        captureQueueBuffers.removeAll()
        activeSession = nil
        captureLock.unlock()

        // Capture values needed off-main-thread
        let deviceID = selectedDeviceID
        let preset = qualityPreset
        let queue = captureQueue

        DiagLog.shared.write("CAPTURE: Starting (device=\(deviceID ?? "default"), preset=\(preset.rawValue), tempURL=\(tempFileURL!.lastPathComponent))")

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
                // Use device native format — resampled to 16kHz mono via resampleBuffers()
                if session.canAddOutput(output) { session.addOutput(output) }

                self?.captureLock.lock()
                self?.activeSession = session
                self?.captureLock.unlock()

                session.startRunning()
                let running = session.isRunning
                let name = audioDevice.localizedName

                Task { @MainActor in
                    guard let self else { return }
                    if running {
                        self.captureSession = session
                        self.audioOutput = output
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
        captureLock.lock()
        let lockBufferCount = captureQueueBuffers.count
        captureLock.unlock()
        DiagLog.shared.write("CAPTURE: stopRecording() called — isRecording=\(isRecording), hasSession=\(captureSession != nil), mainBuffers=\(audioBuffers.count), lockBuffers=\(lockBufferCount), tempURL=\(tempFileURL?.lastPathComponent ?? "nil")")
        guard isRecording else {
            DiagLog.shared.write("CAPTURE: stopRecording() — not recording, returning nil")
            return nil
        }

        // Read session from lock-protected reference (always set before startRunning).
        // Fall back to captureSession for the rare case where the setup Task already ran.
        captureLock.lock()
        let session = activeSession ?? captureSession
        activeSession = nil
        let buffers = captureQueueBuffers
        captureQueueBuffers.removeAll()
        captureLock.unlock()

        captureSession = nil
        audioOutput = nil
        isRecording = false
        audioLevel = 0
        audioDB = -60
        audioBuffers.removeAll()
        captureQueue.async { session?.stopRunning() }

        guard !buffers.isEmpty, let fileURL = tempFileURL else {
            DiagLog.shared.write("CAPTURE: ⚠️ stopRecording() — buffers empty (\(buffers.count)) or no tempURL (\(tempFileURL?.lastPathComponent ?? "nil")) — returning nil")
            return nil
        }

        // Stash buffers for async resampling — caller uses resampleBuffers() off main thread.
        pendingResampleBuffers = buffers
        pendingResampleURL = fileURL
        DiagLog.shared.write("CAPTURE: stopRecording() — stashed \(buffers.count) buffers for resample")
        return fileURL
    }

    private var pendingResampleBuffers: [AVAudioPCMBuffer]?
    private var pendingResampleURL: URL?

    /// Resample captured audio to 16kHz mono WAV. Call from a background context after stopRecording().
    nonisolated func resampleBuffers(to fileURL: URL, buffers: [AVAudioPCMBuffer]) -> Bool {
        do {
            let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let outputFile = try AVAudioFile(forWriting: fileURL, settings: outputFormat.settings)
            for buffer in buffers {
                if let converted = resample(buffer: buffer, to: outputFormat) {
                    try outputFile.write(from: converted)
                }
            }
            return true
        } catch {
            logger.error("Failed to write audio: \(error.localizedDescription)")
            return false
        }
    }

    /// Consume pending buffers and URL from the last stopRecording() call.
    func consumePendingResample() -> (url: URL, buffers: [AVAudioPCMBuffer])? {
        guard let url = pendingResampleURL, let buffers = pendingResampleBuffers else {
            DiagLog.shared.write("CAPTURE: consumePendingResample() — nothing pending (url=\(pendingResampleURL?.lastPathComponent ?? "nil"), buffers=\(pendingResampleBuffers?.count ?? -1))")
            return nil
        }
        pendingResampleBuffers = nil
        pendingResampleURL = nil
        DiagLog.shared.write("CAPTURE: consumePendingResample() — returning \(buffers.count) buffers")
        return (url, buffers)
    }

    func cancelRecording() {
        captureLock.lock()
        let session = activeSession ?? captureSession
        activeSession = nil
        captureQueueBuffers.removeAll()
        captureLock.unlock()

        captureSession = nil
        audioOutput = nil
        isRecording = false
        captureQueue.async { session?.stopRunning() }
        audioLevel = 0
        audioBuffers.removeAll()
        if let url = tempFileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Resampling

    private nonisolated func resample(buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
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
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let data = dataPointer, length > 0 else { return }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = AVAudioChannelCount(asbd.mChannelsPerFrame)

        // Target format: float32, non-interleaved (what AVAudioPCMBuffer.floatChannelData expects)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: channels,
            interleaved: false
        )!

        // Always convert from the device's native format via AVAudioConverter
        // to handle any mic (USB, Bluetooth, built-in) regardless of bit depth or layout.
        let nativeFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        guard let nativeBuf = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        nativeBuf.frameLength = AVAudioFrameCount(frameCount)

        if nativeFormat.isInterleaved {
            if let dest = nativeBuf.audioBufferList.pointee.mBuffers.mData {
                memcpy(dest, data, min(length, Int(nativeBuf.audioBufferList.pointee.mBuffers.mDataByteSize)))
            }
        } else {
            let ablPointer = UnsafeMutableAudioBufferListPointer(nativeBuf.mutableAudioBufferList)
            var offset = 0
            for i in 0..<Int(channels) where i < ablPointer.count {
                if let dest = ablPointer[i].mData {
                    let copyLen = min(length - offset, Int(ablPointer[i].mDataByteSize))
                    guard copyLen > 0 else { break }
                    memcpy(dest, data.advanced(by: offset), copyLen)
                    offset += copyLen
                }
            }
        }

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else { return }
        guard let outputBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuf, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return nativeBuf
        }
        guard error == nil, outputBuf.frameLength > 0 else { return }
        let pcmBuffer = outputBuf

        captureLock.lock()
        let wasEmpty = captureQueueBuffers.isEmpty
        captureQueueBuffers.append(pcmBuffer)
        captureLock.unlock()

        Task { @MainActor in
            self.audioBuffers.append(pcmBuffer)
            if wasEmpty {
                let fmtFlags = asbd.mFormatFlags
                let bitsPerCh = asbd.mBitsPerChannel
                let isPacked = (fmtFlags & kAudioFormatFlagIsPacked) != 0
                let isInterleaved = !isNonInterleaved
                DiagLog.shared.write("CAPTURE: First buffer — rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) bits=\(bitsPerCh) float=\(isFloat) packed=\(isPacked) interleaved=\(isInterleaved) flags=0x\(String(fmtFlags, radix: 16)) frames=\(pcmBuffer.frameLength) dataBytes=\(length)")
            }
        }
    }
}
