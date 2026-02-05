#!/usr/bin/env swift

// ScreenRecordingBubble - A comprehensive macOS screen recording app like Loom
// Features: Screen recording with webcam bubble, video editing, speed controls, trimming
// Usage: swift ScreenRecordingBubble.swift

import Cocoa
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import AVKit

// MARK: - Configuration

struct AppConfig {
    static let appName = "Screen Recording Bubble"
    static let recordingsFolder = "ScreenRecordingBubble"
    static let defaultBubbleSize: CGFloat = 180
    static let minBubbleSize: CGFloat = 80
    static let maxBubbleSize: CGFloat = 400
    static let defaultBorderWidth: CGFloat = 3
    static let defaultBorderColor: NSColor = .white
    static let cornerSnapThreshold: CGFloat = 50
    static let cornerPadding: CGFloat = 20

    enum BubbleSize: String, CaseIterable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"
        case hidden = "Hidden"

        var size: CGFloat {
            switch self {
            case .small: return 120
            case .medium: return 180
            case .large: return 280
            case .hidden: return 0
            }
        }
    }

    enum RecordingQuality: String, CaseIterable {
        case low = "720p"
        case medium = "1080p"
        case high = "4K"

        var dimensions: (width: Int, height: Int) {
            switch self {
            case .low: return (1280, 720)
            case .medium: return (1920, 1080)
            case .high: return (3840, 2160)
            }
        }
    }

    static func recordingsDirectory() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let folder = movies.appendingPathComponent(recordingsFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

// MARK: - Recording Model

struct Recording: Identifiable, Codable {
    let id: UUID
    let filename: String
    let createdAt: Date
    var duration: TimeInterval
    var thumbnail: Data?

    var url: URL {
        AppConfig.recordingsDirectory().appendingPathComponent(filename)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}

// MARK: - Recording Manager

class RecordingManager: NSObject, ObservableObject {
    static let shared = RecordingManager()

    @Published var recordings: [Recording] = []
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var currentRecordingURL: URL?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartTime: Date?

    private let recordingsKey = "SavedRecordings"

    override init() {
        super.init()
        loadRecordings()
    }

    func loadRecordings() {
        if let data = UserDefaults.standard.data(forKey: recordingsKey),
           let decoded = try? JSONDecoder().decode([Recording].self, from: data) {
            // Filter out recordings whose files no longer exist
            recordings = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            saveRecordings()
        }
    }

    func saveRecordings() {
        if let encoded = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(encoded, forKey: recordingsKey)
        }
    }

    func deleteRecording(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }

    func startRecording(includeAudio: Bool, completion: @escaping (Bool, String?) -> Void) {
        Task {
            do {
                // Request screen recording permission
                guard await requestScreenRecordingPermission() else {
                    DispatchQueue.main.async {
                        completion(false, "Screen recording permission denied")
                    }
                    return
                }

                // Get available content
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else {
                    DispatchQueue.main.async {
                        completion(false, "No display found")
                    }
                    return
                }

                // Configure stream
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width * 2
                config.height = display.height * 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.queueDepth = 5
                config.showsCursor = true

                if includeAudio {
                    config.capturesAudio = true
                    config.sampleRate = 48000
                    config.channelCount = 2
                }

                // Setup output file
                let filename = "Recording_\(Date().timeIntervalSince1970).mp4"
                let outputURL = AppConfig.recordingsDirectory().appendingPathComponent(filename)
                currentRecordingURL = outputURL

                // Setup asset writer
                assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: config.width,
                    AVVideoHeightKey: config.height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: 10_000_000,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                    ]
                ]

                videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput?.expectsMediaDataInRealTime = true

                if let videoInput = videoInput, assetWriter?.canAdd(videoInput) == true {
                    assetWriter?.add(videoInput)
                }

                if includeAudio {
                    let audioSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48000,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 128000
                    ]

                    audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    audioInput?.expectsMediaDataInRealTime = true

                    if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true {
                        assetWriter?.add(audioInput)
                    }
                }

                // Start writing
                assetWriter?.startWriting()
                assetWriter?.startSession(atSourceTime: .zero)

                // Create and start stream
                stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.capture"))

                if includeAudio {
                    try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.capture"))
                }

                try await stream?.startCapture()

                DispatchQueue.main.async { [weak self] in
                    self?.isRecording = true
                    self?.isPaused = false
                    self?.recordingDuration = 0
                    self?.pausedDuration = 0
                    self?.recordingStartTime = Date()
                    self?.startDurationTimer()
                    completion(true, nil)
                }

            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    func pauseRecording() {
        guard isRecording && !isPaused else { return }
        isPaused = true
        pauseStartTime = Date()
        durationTimer?.invalidate()
    }

    func resumeRecording() {
        guard isRecording && isPaused else { return }
        if let pauseStart = pauseStartTime {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }
        isPaused = false
        pauseStartTime = nil
        startDurationTimer()
    }

    func stopRecording(completion: @escaping (Recording?) -> Void) {
        guard isRecording else {
            completion(nil)
            return
        }

        durationTimer?.invalidate()
        durationTimer = nil

        Task {
            do {
                try await stream?.stopCapture()
                stream = nil

                await MainActor.run {
                    videoInput?.markAsFinished()
                    audioInput?.markAsFinished()
                }

                await assetWriter?.finishWriting()

                let finalDuration = recordingDuration
                let url = currentRecordingURL

                await MainActor.run { [weak self] in
                    guard let self = self, let url = url else {
                        completion(nil)
                        return
                    }

                    self.isRecording = false
                    self.isPaused = false

                    // Create recording entry
                    let recording = Recording(
                        id: UUID(),
                        filename: url.lastPathComponent,
                        createdAt: Date(),
                        duration: finalDuration,
                        thumbnail: self.generateThumbnail(for: url)
                    )

                    self.recordings.insert(recording, at: 0)
                    self.saveRecordings()

                    completion(recording)
                }

            } catch {
                await MainActor.run { [weak self] in
                    self?.isRecording = false
                    self?.isPaused = false
                    completion(nil)
                }
            }
        }
    }

    private func requestScreenRecordingPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.current
            return true
        } catch {
            return false
        }
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime, !self.isPaused else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime) - self.pausedDuration
        }
    }

    private func generateThumbnail(for url: URL) -> Data? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 320, height: 180))
            return nsImage.tiffRepresentation
        } catch {
            return nil
        }
    }

    private var firstSampleTime: CMTime?
}

extension RecordingManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.isPaused = false
        }
    }
}

extension RecordingManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording && !isPaused else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstSampleTime == nil {
            firstSampleTime = timestamp
        }

        let adjustedTime = CMTimeSubtract(timestamp, firstSampleTime ?? .zero)

        switch type {
        case .screen:
            if let videoInput = videoInput, videoInput.isReadyForMoreMediaData {
                if let adjustedBuffer = adjustTimestamp(of: sampleBuffer, to: adjustedTime) {
                    videoInput.append(adjustedBuffer)
                }
            }
        case .audio, .microphone:
            if let audioInput = audioInput, audioInput.isReadyForMoreMediaData {
                if let adjustedBuffer = adjustTimestamp(of: sampleBuffer, to: adjustedTime) {
                    audioInput.append(adjustedBuffer)
                }
            }
        @unknown default:
            break
        }
    }

    private func adjustTimestamp(of sampleBuffer: CMSampleBuffer, to newTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newTime,
            decodeTimeStamp: .invalid
        )

        var newBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &newBuffer
        )

        return newBuffer
    }
}

// MARK: - Camera Controller

class CameraController: NSObject {
    private let session = AVCaptureSession()
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentDevice: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?

    var isMirrored: Bool = true {
        didSet { updateMirroring() }
    }

    var isRunning: Bool { session.isRunning }

    var availableCameras: [AVCaptureDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        } else {
            deviceTypes.append(.externalUnknown)
        }
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices
    }

    var currentCameraName: String? { currentDevice?.localizedName }

    func requestPermissionAndSetup(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.setupCamera() }
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    func switchCamera(to device: AVCaptureDevice) {
        guard device != currentDevice else { return }

        session.beginConfiguration()

        if let currentInput = currentInput {
            session.removeInput(currentInput)
        }

        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                currentInput = newInput
                currentDevice = device
            }
        } catch {
            if let currentInput = currentInput, session.canAddInput(currentInput) {
                session.addInput(currentInput)
            }
        }

        session.commitConfiguration()
        updateMirroring()
    }

    func startSession() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stopSession() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                currentDevice = device
            }
        } catch {
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        previewLayer = layer

        updateMirroring()
    }

    private func updateMirroring() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let connection = self.previewLayer?.connection else { return }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = self.isMirrored
            }
        }
    }
}

// MARK: - Bubble Window

class BubbleWindow: NSWindow {
    var onDragEnd: (() -> Void)?

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: backing, defer: flag)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onDragEnd?()
    }
}

// MARK: - Bubble View

class BubbleView: NSView {
    var borderWidth: CGFloat = AppConfig.defaultBorderWidth {
        didSet { updateBorder() }
    }

    var borderColor: NSColor = AppConfig.defaultBorderColor {
        didSet { updateBorder() }
    }

    private var borderLayer: CAShapeLayer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.masksToBounds = true
        updateCornerRadius()
        setupBorderLayer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCornerRadius()
        updateBorderPath()
    }

    private func updateCornerRadius() {
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private func setupBorderLayer() {
        borderLayer?.removeFromSuperlayer()

        let shapeLayer = CAShapeLayer()
        shapeLayer.fillColor = nil
        shapeLayer.strokeColor = borderColor.cgColor
        shapeLayer.lineWidth = borderWidth
        borderLayer = shapeLayer

        layer?.addSublayer(shapeLayer)
        updateBorderPath()
    }

    private func updateBorderPath() {
        guard let borderLayer = borderLayer else { return }

        let inset = borderWidth / 2
        let circleRect = bounds.insetBy(dx: inset, dy: inset)
        borderLayer.path = CGPath(ellipseIn: circleRect, transform: nil)
        borderLayer.frame = bounds
    }

    private func updateBorder() {
        borderLayer?.strokeColor = borderColor.cgColor
        borderLayer?.lineWidth = borderWidth
        updateBorderPath()
    }
}

// MARK: - Video Editor Window Controller

class VideoEditorWindowController: NSWindowController {
    private var recording: Recording
    private var player: AVPlayer?
    private var playerView: AVPlayerView!
    private var timelineSlider: NSSlider!
    private var playButton: NSButton!
    private var currentTimeLabel: NSTextField!
    private var durationLabel: NSTextField!
    private var speedPopup: NSPopUpButton!
    private var trimStartSlider: NSSlider!
    private var trimEndSlider: NSSlider!
    private var trimStartLabel: NSTextField!
    private var trimEndLabel: NSTextField!
    private var exportButton: NSButton!
    private var deleteButton: NSButton!

    private var timeObserver: Any?
    private var currentSpeed: Float = 1.0
    private var trimStart: Double = 0
    private var trimEnd: Double = 0

    init(recording: Recording) {
        self.recording = recording

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Recording - \(recording.formattedDate)"
        window.minSize = NSSize(width: 700, height: 550)
        window.center()

        super.init(window: window)

        setupUI()
        loadVideo()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        // Player view
        playerView = AVPlayerView(frame: NSRect(x: 20, y: 220, width: contentView.bounds.width - 40, height: contentView.bounds.height - 240))
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .none
        contentView.addSubview(playerView)

        // Controls container
        let controlsContainer = NSView(frame: NSRect(x: 20, y: 20, width: contentView.bounds.width - 40, height: 180))
        controlsContainer.autoresizingMask = [.width]
        contentView.addSubview(controlsContainer)

        // Timeline section
        let timelineLabel = NSTextField(labelWithString: "Timeline")
        timelineLabel.frame = NSRect(x: 0, y: 155, width: 100, height: 20)
        timelineLabel.font = NSFont.boldSystemFont(ofSize: 12)
        controlsContainer.addSubview(timelineLabel)

        currentTimeLabel = NSTextField(labelWithString: "0:00")
        currentTimeLabel.frame = NSRect(x: 0, y: 130, width: 50, height: 20)
        currentTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        controlsContainer.addSubview(currentTimeLabel)

        timelineSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(timelineChanged(_:)))
        timelineSlider.frame = NSRect(x: 55, y: 130, width: controlsContainer.bounds.width - 110, height: 20)
        timelineSlider.autoresizingMask = [.width]
        timelineSlider.isContinuous = true
        controlsContainer.addSubview(timelineSlider)

        durationLabel = NSTextField(labelWithString: "0:00")
        durationLabel.frame = NSRect(x: controlsContainer.bounds.width - 50, y: 130, width: 50, height: 20)
        durationLabel.autoresizingMask = [.minXMargin]
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationLabel.alignment = .right
        controlsContainer.addSubview(durationLabel)

        // Playback controls
        playButton = NSButton(title: "▶", target: self, action: #selector(togglePlayback))
        playButton.frame = NSRect(x: controlsContainer.bounds.width / 2 - 25, y: 95, width: 50, height: 30)
        playButton.bezelStyle = .rounded
        playButton.font = NSFont.systemFont(ofSize: 14)
        controlsContainer.addSubview(playButton)

        // Speed control
        let speedLabel = NSTextField(labelWithString: "Speed:")
        speedLabel.frame = NSRect(x: controlsContainer.bounds.width / 2 + 40, y: 98, width: 50, height: 20)
        speedLabel.font = NSFont.systemFont(ofSize: 12)
        controlsContainer.addSubview(speedLabel)

        speedPopup = NSPopUpButton(frame: NSRect(x: controlsContainer.bounds.width / 2 + 90, y: 95, width: 80, height: 25), pullsDown: false)
        speedPopup.addItems(withTitles: ["0.25x", "0.5x", "0.75x", "1x", "1.25x", "1.5x", "2x", "3x"])
        speedPopup.selectItem(withTitle: "1x")
        speedPopup.target = self
        speedPopup.action = #selector(speedChanged(_:))
        controlsContainer.addSubview(speedPopup)

        // Trim section
        let trimLabel = NSTextField(labelWithString: "Trim")
        trimLabel.frame = NSRect(x: 0, y: 65, width: 100, height: 20)
        trimLabel.font = NSFont.boldSystemFont(ofSize: 12)
        controlsContainer.addSubview(trimLabel)

        let startLabel = NSTextField(labelWithString: "Start:")
        startLabel.frame = NSRect(x: 0, y: 40, width: 40, height: 20)
        startLabel.font = NSFont.systemFont(ofSize: 11)
        controlsContainer.addSubview(startLabel)

        trimStartSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(trimStartChanged(_:)))
        trimStartSlider.frame = NSRect(x: 45, y: 40, width: controlsContainer.bounds.width / 2 - 100, height: 20)
        trimStartSlider.autoresizingMask = [.width]
        trimStartSlider.isContinuous = true
        controlsContainer.addSubview(trimStartSlider)

        trimStartLabel = NSTextField(labelWithString: "0:00")
        trimStartLabel.frame = NSRect(x: controlsContainer.bounds.width / 2 - 50, y: 40, width: 45, height: 20)
        trimStartLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trimStartLabel.alignment = .right
        controlsContainer.addSubview(trimStartLabel)

        let endLabel = NSTextField(labelWithString: "End:")
        endLabel.frame = NSRect(x: controlsContainer.bounds.width / 2 + 10, y: 40, width: 35, height: 20)
        endLabel.font = NSFont.systemFont(ofSize: 11)
        controlsContainer.addSubview(endLabel)

        trimEndSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: self, action: #selector(trimEndChanged(_:)))
        trimEndSlider.frame = NSRect(x: controlsContainer.bounds.width / 2 + 50, y: 40, width: controlsContainer.bounds.width / 2 - 100, height: 20)
        trimEndSlider.autoresizingMask = [.width]
        trimEndSlider.isContinuous = true
        controlsContainer.addSubview(trimEndSlider)

        trimEndLabel = NSTextField(labelWithString: "0:00")
        trimEndLabel.frame = NSRect(x: controlsContainer.bounds.width - 45, y: 40, width: 45, height: 20)
        trimEndLabel.autoresizingMask = [.minXMargin]
        trimEndLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trimEndLabel.alignment = .right
        controlsContainer.addSubview(trimEndLabel)

        // Action buttons
        exportButton = NSButton(title: "Export", target: self, action: #selector(exportVideo))
        exportButton.frame = NSRect(x: controlsContainer.bounds.width - 180, y: 0, width: 80, height: 30)
        exportButton.autoresizingMask = [.minXMargin]
        exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"
        controlsContainer.addSubview(exportButton)

        let openInFinderButton = NSButton(title: "Show in Finder", target: self, action: #selector(showInFinder))
        openInFinderButton.frame = NSRect(x: controlsContainer.bounds.width - 290, y: 0, width: 105, height: 30)
        openInFinderButton.autoresizingMask = [.minXMargin]
        openInFinderButton.bezelStyle = .rounded
        controlsContainer.addSubview(openInFinderButton)

        deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteRecording))
        deleteButton.frame = NSRect(x: 0, y: 0, width: 80, height: 30)
        deleteButton.bezelStyle = .rounded
        deleteButton.contentTintColor = .systemRed
        controlsContainer.addSubview(deleteButton)
    }

    private func loadVideo() {
        let asset = AVAsset(url: recording.url)
        let playerItem = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: playerItem)
        playerView.player = player

        // Get duration
        Task {
            do {
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)

                await MainActor.run {
                    self.trimEnd = seconds
                    self.timelineSlider.maxValue = seconds
                    self.trimStartSlider.maxValue = seconds
                    self.trimEndSlider.maxValue = seconds
                    self.trimEndSlider.doubleValue = seconds
                    self.durationLabel.stringValue = self.formatTime(seconds)
                    self.trimEndLabel.stringValue = self.formatTime(seconds)
                }
            } catch {
                print("Error loading duration: \(error)")
            }
        }

        // Add time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = CMTimeGetSeconds(time)
            self.timelineSlider.doubleValue = seconds
            self.currentTimeLabel.stringValue = self.formatTime(seconds)

            // Loop within trim range
            if seconds >= self.trimEnd {
                self.player?.seek(to: CMTime(seconds: self.trimStart, preferredTimescale: 600))
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    @objc private func togglePlayback() {
        guard let player = player else { return }

        if player.rate == 0 {
            player.rate = currentSpeed
            playButton.title = "⏸"
        } else {
            player.pause()
            playButton.title = "▶"
        }
    }

    @objc private func timelineChanged(_ sender: NSSlider) {
        let time = CMTime(seconds: sender.doubleValue, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func speedChanged(_ sender: NSPopUpButton) {
        let speeds: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
        currentSpeed = speeds[sender.indexOfSelectedItem]

        if player?.rate != 0 {
            player?.rate = currentSpeed
        }
    }

    @objc private func trimStartChanged(_ sender: NSSlider) {
        trimStart = sender.doubleValue
        trimStartLabel.stringValue = formatTime(trimStart)

        // Ensure start doesn't exceed end
        if trimStart >= trimEnd {
            trimStart = max(0, trimEnd - 1)
            sender.doubleValue = trimStart
            trimStartLabel.stringValue = formatTime(trimStart)
        }

        // Seek to trim start
        let time = CMTime(seconds: trimStart, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func trimEndChanged(_ sender: NSSlider) {
        trimEnd = sender.doubleValue
        trimEndLabel.stringValue = formatTime(trimEnd)

        // Ensure end doesn't precede start
        if trimEnd <= trimStart {
            trimEnd = trimStart + 1
            sender.doubleValue = trimEnd
            trimEndLabel.stringValue = formatTime(trimEnd)
        }
    }

    @objc private func exportVideo() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.mpeg4Movie]
        savePanel.nameFieldStringValue = "Edited_\(recording.filename)"
        savePanel.canCreateDirectories = true

        savePanel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self = self else { return }
            self.performExport(to: url)
        }
    }

    private func performExport(to outputURL: URL) {
        let asset = AVAsset(url: recording.url)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            showAlert(title: "Export Failed", message: "Could not create export session")
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        // Set time range for trimming
        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        exportSession.timeRange = CMTimeRange(start: startTime, end: endTime)

        // Apply speed change if needed
        if currentSpeed != 1.0 {
            let composition = AVMutableComposition()

            Task {
                do {
                    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                        await MainActor.run {
                            self.showAlert(title: "Export Failed", message: "No video track found")
                        }
                        return
                    }

                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                    guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        return
                    }

                    let timeRange = CMTimeRange(start: startTime, end: endTime)
                    try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

                    // Scale time for speed change
                    let scaledDuration = CMTimeMultiplyByFloat64(CMTimeSubtract(endTime, startTime), multiplier: Float64(1.0 / currentSpeed))
                    compositionVideoTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: CMTimeSubtract(endTime, startTime)), toDuration: scaledDuration)

                    // Handle audio
                    if let audioTrack = audioTracks.first,
                       let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
                        compositionAudioTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: CMTimeSubtract(endTime, startTime)), toDuration: scaledDuration)
                    }

                    // Export the composition
                    guard let speedExportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                        await MainActor.run {
                            self.showAlert(title: "Export Failed", message: "Could not create export session")
                        }
                        return
                    }

                    speedExportSession.outputURL = outputURL
                    speedExportSession.outputFileType = .mp4

                    await speedExportSession.export()

                    await MainActor.run {
                        if speedExportSession.status == .completed {
                            self.showAlert(title: "Export Complete", message: "Video exported successfully to \(outputURL.lastPathComponent)")
                        } else {
                            self.showAlert(title: "Export Failed", message: speedExportSession.error?.localizedDescription ?? "Unknown error")
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.showAlert(title: "Export Failed", message: error.localizedDescription)
                    }
                }
            }
        } else {
            // Simple export without speed change
            exportSession.exportAsynchronously { [weak self] in
                DispatchQueue.main.async {
                    if exportSession.status == .completed {
                        self?.showAlert(title: "Export Complete", message: "Video exported successfully to \(outputURL.lastPathComponent)")
                    } else {
                        self?.showAlert(title: "Export Failed", message: exportSession.error?.localizedDescription ?? "Unknown error")
                    }
                }
            }
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }

    @objc private func deleteRecording() {
        let alert = NSAlert()
        alert.messageText = "Delete Recording?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            RecordingManager.shared.deleteRecording(recording)
            window?.close()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Recordings Library Window Controller

class RecordingsLibraryWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {
    private var tableView: NSTableView!
    private var recordings: [Recording] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Recording Library"
        window.minSize = NSSize(width: 400, height: 300)
        window.center()

        super.init(window: window)

        setupUI()
        loadRecordings()

        // Observe changes
        NotificationCenter.default.addObserver(self, selector: #selector(loadRecordings), name: NSNotification.Name("RecordingsChanged"), object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = window else { return }

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.doubleAction = #selector(openRecording)
        tableView.target = self

        let thumbnailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thumbnail"))
        thumbnailColumn.title = ""
        thumbnailColumn.width = 120
        thumbnailColumn.minWidth = 80
        tableView.addTableColumn(thumbnailColumn)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Recording"
        nameColumn.width = 200
        nameColumn.minWidth = 100
        tableView.addTableColumn(nameColumn)

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Date"
        dateColumn.width = 150
        dateColumn.minWidth = 100
        tableView.addTableColumn(dateColumn)

        let durationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("duration"))
        durationColumn.title = "Duration"
        durationColumn.width = 80
        durationColumn.minWidth = 60
        tableView.addTableColumn(durationColumn)

        scrollView.documentView = tableView
        window.contentView?.addSubview(scrollView)
    }

    @objc private func loadRecordings() {
        recordings = RecordingManager.shared.recordings
        tableView?.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        recordings.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let recording = recordings[row]

        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("cell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = identifier

            if identifier.rawValue == "thumbnail" {
                let imageView = NSImageView()
                imageView.imageScaling = .scaleProportionallyUpOrDown
                cell?.imageView = imageView
                cell?.addSubview(imageView)
            } else {
                let textField = NSTextField(labelWithString: "")
                textField.lineBreakMode = .byTruncatingTail
                cell?.textField = textField
                cell?.addSubview(textField)
            }
        }

        if identifier.rawValue == "thumbnail" {
            if let data = recording.thumbnail, let image = NSImage(data: data) {
                cell?.imageView?.image = image
            } else {
                cell?.imageView?.image = NSImage(systemSymbolName: "video", accessibilityDescription: "Video")
            }
            cell?.imageView?.frame = NSRect(x: 5, y: 5, width: 110, height: 60)
        } else {
            switch identifier.rawValue {
            case "name":
                cell?.textField?.stringValue = recording.filename
            case "date":
                cell?.textField?.stringValue = recording.formattedDate
            case "duration":
                cell?.textField?.stringValue = recording.formattedDuration
            default:
                break
            }
            cell?.textField?.frame = NSRect(x: 5, y: 20, width: (tableColumn?.width ?? 100) - 10, height: 20)
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        70
    }

    @objc private func openRecording() {
        let row = tableView.selectedRow
        guard row >= 0 && row < recordings.count else { return }

        let recording = recordings[row]
        let editor = VideoEditorWindowController(recording: recording)
        editor.showWindow(nil)
    }
}

// MARK: - Recording Control Window

class RecordingControlWindow: NSPanel {
    var onStartStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onCancel: (() -> Void)?

    private var statusLabel: NSTextField!
    private var timerLabel: NSTextField!
    private var startStopButton: NSButton!
    private var pauseButton: NSButton!
    private var recordingIndicator: NSView!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true

        setupUI()
    }

    private func setupUI() {
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 280, height: 70))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        contentView = container

        // Recording indicator
        recordingIndicator = NSView(frame: NSRect(x: 15, y: 27, width: 12, height: 12))
        recordingIndicator.wantsLayer = true
        recordingIndicator.layer?.cornerRadius = 6
        recordingIndicator.layer?.backgroundColor = NSColor.systemGray.cgColor
        container.addSubview(recordingIndicator)

        // Timer label
        timerLabel = NSTextField(labelWithString: "0:00")
        timerLabel.frame = NSRect(x: 35, y: 25, width: 60, height: 20)
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        timerLabel.textColor = .labelColor
        container.addSubview(timerLabel)

        // Pause button
        pauseButton = NSButton(image: NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")!, target: self, action: #selector(pauseResumeClicked))
        pauseButton.frame = NSRect(x: 105, y: 20, width: 35, height: 30)
        pauseButton.bezelStyle = .rounded
        pauseButton.isEnabled = false
        container.addSubview(pauseButton)

        // Start/Stop button
        startStopButton = NSButton(title: "Start", target: self, action: #selector(startStopClicked))
        startStopButton.frame = NSRect(x: 145, y: 20, width: 70, height: 30)
        startStopButton.bezelStyle = .rounded
        startStopButton.contentTintColor = .systemRed
        container.addSubview(startStopButton)

        // Cancel button
        let cancelButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")!, target: self, action: #selector(cancelClicked))
        cancelButton.frame = NSRect(x: 220, y: 20, width: 35, height: 30)
        cancelButton.bezelStyle = .rounded
        container.addSubview(cancelButton)
    }

    func updateState(isRecording: Bool, isPaused: Bool, duration: TimeInterval) {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        timerLabel.stringValue = String(format: "%d:%02d", mins, secs)

        if isRecording {
            startStopButton.title = "Stop"
            pauseButton.isEnabled = true

            if isPaused {
                pauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Resume")
                recordingIndicator.layer?.backgroundColor = NSColor.systemYellow.cgColor
            } else {
                pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
                recordingIndicator.layer?.backgroundColor = NSColor.systemRed.cgColor

                // Animate recording indicator
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1.0
                animation.toValue = 0.3
                animation.duration = 0.5
                animation.autoreverses = true
                animation.repeatCount = .infinity
                recordingIndicator.layer?.add(animation, forKey: "blink")
            }
        } else {
            startStopButton.title = "Start"
            pauseButton.isEnabled = false
            pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
            recordingIndicator.layer?.backgroundColor = NSColor.systemGray.cgColor
            recordingIndicator.layer?.removeAllAnimations()
        }
    }

    @objc private func startStopClicked() {
        onStartStop?()
    }

    @objc private func pauseResumeClicked() {
        onPauseResume?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

// MARK: - Main App Controller

class AppController: NSObject {
    private var statusItem: NSStatusItem!
    private var bubbleWindow: BubbleWindow?
    private var bubbleView: BubbleView?
    private var cameraController: CameraController?
    private var recordingControlWindow: RecordingControlWindow?
    private var libraryWindowController: RecordingsLibraryWindowController?

    private var currentBubbleSize: CGFloat = AppConfig.defaultBubbleSize
    private var isBubbleVisible = true
    private var includeAudio = true
    private var includeMicrophone = false

    private var updateTimer: Timer?

    // Menu items
    private var recordMenuItem: NSMenuItem?
    private var bubbleMenuItem: NSMenuItem?
    private var audioMenuItem: NSMenuItem?

    override init() {
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: AppConfig.appName)
            button.image?.isTemplate = true
        }

        statusItem.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()

        // Record control
        let recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        recordItem.target = self
        recordMenuItem = recordItem
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        // Show recording controls
        let showControlsItem = NSMenuItem(title: "Show Recording Controls", action: #selector(showRecordingControls), keyEquivalent: "")
        showControlsItem.target = self
        menu.addItem(showControlsItem)

        menu.addItem(NSMenuItem.separator())

        // Camera bubble submenu
        let bubbleMenu = NSMenu()

        let showBubbleItem = NSMenuItem(title: "Show Camera Bubble", action: #selector(toggleBubble), keyEquivalent: "b")
        showBubbleItem.target = self
        showBubbleItem.state = .off
        bubbleMenuItem = showBubbleItem
        bubbleMenu.addItem(showBubbleItem)

        bubbleMenu.addItem(NSMenuItem.separator())

        for size in AppConfig.BubbleSize.allCases {
            let item = NSMenuItem(title: size.rawValue, action: #selector(selectBubbleSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = size == .medium ? .on : .off
            bubbleMenu.addItem(item)
        }

        let bubbleItem = NSMenuItem(title: "Camera Bubble", action: nil, keyEquivalent: "")
        bubbleItem.submenu = bubbleMenu
        menu.addItem(bubbleItem)

        // Audio options
        let audioMenu = NSMenu()

        let systemAudioItem = NSMenuItem(title: "Include System Audio", action: #selector(toggleSystemAudio), keyEquivalent: "")
        systemAudioItem.target = self
        systemAudioItem.state = includeAudio ? .on : .off
        audioMenuItem = systemAudioItem
        audioMenu.addItem(systemAudioItem)

        let audioItem = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        audioItem.submenu = audioMenu
        menu.addItem(audioItem)

        menu.addItem(NSMenuItem.separator())

        // Library
        let libraryItem = NSMenuItem(title: "Recording Library...", action: #selector(showLibrary), keyEquivalent: "l")
        libraryItem.target = self
        menu.addItem(libraryItem)

        // Open recordings folder
        let folderItem = NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordingsFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        let manager = RecordingManager.shared

        if manager.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        RecordingManager.shared.startRecording(includeAudio: includeAudio) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.recordMenuItem?.title = "Stop Recording"
                    self?.updateStatusIcon(recording: true)
                    self?.startUpdateTimer()

                    // Show recording controls
                    self?.showRecordingControls()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Recording Failed"
                    alert.informativeText = error ?? "Unknown error occurred"
                    alert.runModal()
                }
            }
        }
    }

    private func stopRecording() {
        RecordingManager.shared.stopRecording { [weak self] recording in
            DispatchQueue.main.async {
                self?.recordMenuItem?.title = "Start Recording"
                self?.updateStatusIcon(recording: false)
                self?.stopUpdateTimer()

                // Hide recording controls
                self?.recordingControlWindow?.orderOut(nil)

                if let recording = recording {
                    // Show notification or open editor
                    self?.showRecordingComplete(recording)
                }
            }
        }
    }

    private func showRecordingComplete(_ recording: Recording) {
        let alert = NSAlert()
        alert.messageText = "Recording Complete"
        alert.informativeText = "Duration: \(recording.formattedDuration)"
        alert.addButton(withTitle: "Edit")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            let editor = VideoEditorWindowController(recording: recording)
            editor.showWindow(nil)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([recording.url])
        default:
            break
        }
    }

    @objc private func showRecordingControls() {
        if recordingControlWindow == nil {
            recordingControlWindow = RecordingControlWindow()

            recordingControlWindow?.onStartStop = { [weak self] in
                self?.toggleRecording()
            }

            recordingControlWindow?.onPauseResume = { [weak self] in
                let manager = RecordingManager.shared
                if manager.isPaused {
                    manager.resumeRecording()
                } else {
                    manager.pauseRecording()
                }
            }

            recordingControlWindow?.onCancel = { [weak self] in
                self?.recordingControlWindow?.orderOut(nil)
            }
        }

        // Position at top center of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = recordingControlWindow!.frame
            let x = screenFrame.midX - windowFrame.width / 2
            let y = screenFrame.maxY - windowFrame.height - 10
            recordingControlWindow?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        recordingControlWindow?.makeKeyAndOrderFront(nil)
    }

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            let manager = RecordingManager.shared
            self?.recordingControlWindow?.updateState(
                isRecording: manager.isRecording,
                isPaused: manager.isPaused,
                duration: manager.recordingDuration
            )
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func updateStatusIcon(recording: Bool) {
        if let button = statusItem.button {
            let symbolName = recording ? "record.circle.fill" : "record.circle"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: AppConfig.appName)
            button.image?.isTemplate = !recording

            if recording {
                button.contentTintColor = .systemRed
            } else {
                button.contentTintColor = nil
            }
        }
    }

    // MARK: - Camera Bubble

    @objc private func toggleBubble() {
        if bubbleWindow == nil {
            showBubble()
        } else {
            hideBubble()
        }
    }

    private func showBubble() {
        let controller = CameraController()
        cameraController = controller

        controller.requestPermissionAndSetup { [weak self] granted in
            guard let self = self, granted else {
                DispatchQueue.main.async {
                    self?.showCameraPermissionAlert()
                }
                return
            }

            DispatchQueue.main.async {
                self.createBubbleWindow()
            }
        }
    }

    private func createBubbleWindow() {
        guard let controller = cameraController, let previewLayer = controller.previewLayer else { return }

        let frame = NSRect(x: 0, y: 0, width: currentBubbleSize, height: currentBubbleSize)
        let window = BubbleWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)

        let view = BubbleView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view

        previewLayer.frame = view.bounds
        previewLayer.cornerRadius = currentBubbleSize / 2
        previewLayer.masksToBounds = true
        view.layer?.addSublayer(previewLayer)

        bubbleWindow = window
        bubbleView = view

        // Position bottom right
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - currentBubbleSize - AppConfig.cornerPadding
            let y = screenFrame.minY + AppConfig.cornerPadding
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        controller.startSession()

        bubbleMenuItem?.state = .on
    }

    private func hideBubble() {
        cameraController?.stopSession()
        bubbleWindow?.orderOut(nil)
        bubbleWindow = nil
        bubbleView = nil
        cameraController = nil
        bubbleMenuItem?.state = .off
    }

    @objc private func selectBubbleSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? AppConfig.BubbleSize else { return }

        // Update menu checkmarks
        if let bubbleMenu = sender.menu {
            for item in bubbleMenu.items {
                if let itemSize = item.representedObject as? AppConfig.BubbleSize {
                    item.state = itemSize == size ? .on : .off
                }
            }
        }

        if size == .hidden {
            hideBubble()
            return
        }

        currentBubbleSize = size.size

        if let window = bubbleWindow, let view = bubbleView {
            let currentFrame = window.frame
            let centerX = currentFrame.midX
            let centerY = currentFrame.midY

            let newFrame = NSRect(
                x: centerX - currentBubbleSize / 2,
                y: centerY - currentBubbleSize / 2,
                width: currentBubbleSize,
                height: currentBubbleSize
            )

            window.setFrame(newFrame, display: true, animate: true)
            view.frame = NSRect(origin: .zero, size: NSSize(width: currentBubbleSize, height: currentBubbleSize))

            if let previewLayer = cameraController?.previewLayer {
                previewLayer.frame = view.bounds
                previewLayer.cornerRadius = currentBubbleSize / 2
            }
        }
    }

    // MARK: - Audio

    @objc private func toggleSystemAudio() {
        includeAudio.toggle()
        audioMenuItem?.state = includeAudio ? .on : .off
    }

    // MARK: - Library

    @objc private func showLibrary() {
        if libraryWindowController == nil {
            libraryWindowController = RecordingsLibraryWindowController()
        }
        libraryWindowController?.showWindow(nil)
        libraryWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openRecordingsFolder() {
        NSWorkspace.shared.open(AppConfig.recordingsDirectory())
    }

    // MARK: - Utilities

    private func showCameraPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Camera Access Required"
        alert.informativeText = "Please enable camera access in System Settings > Privacy & Security > Camera."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func quit() {
        if RecordingManager.shared.isRecording {
            let alert = NSAlert()
            alert.messageText = "Recording in Progress"
            alert.informativeText = "Do you want to stop the recording and quit?"
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                RecordingManager.shared.stopRecording { _ in
                    NSApplication.shared.terminate(nil)
                }
            }
        } else {
            hideBubble()
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var appController: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appController = AppController()
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
