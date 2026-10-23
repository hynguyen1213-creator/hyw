import Foundation
import AVFoundation
import CoreImage
import UIKit
import Combine
import ImageIO
import Vision
import UniformTypeIdentifiers

struct LensDevice: Identifiable { let id: String; let title: String; let device: AVCaptureDevice }
struct CaptureJob {
    let color: ColorSettings
    var metadata: String
    var requestedRAW = false
    var zoom: CGFloat = 1
    var jpeg: Data?
    var raw: Data?
    var error: String?
    var options = ProOptions()
    var portrait = false
    var frames: [Data] = []
    var frameMetadata: [String] = []
    var purpose = CapturePurpose.normal
}
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    @Published var preview: UIImage?
    @Published var lookThumbnails: [String: UIImage] = [:]
    var lookPreviewSource: CIImage?
    @Published var lenses: [LensDevice] = []
    @Published var selectedLens = ""
    @Published var permissionDenied = false
    @Published var running = false
    @Published var capturing = false
    @Published var message = ""
    @Published var currentISO: Float = 100
    @Published var currentShutter: Double = 1.0 / 125
    @Published var minISO: Float = 25
    @Published var maxISO: Float = 3200
    @Published var minShutter: Double = 1.0 / 8000
    @Published var maxShutter: Double = 1
    @Published var maxZoom: CGFloat = 5
    @Published var supportsManual = false
    @Published var supportsFocus = false
    @Published var supportsWB = false
    @Published var supportsRaw = false
    @Published var rawLabel = "RAW không khả dụng"
    @Published var manualExposure = false
    @Published var manualFocus = false
    @Published var manualWB = false
    @Published var exposureBias: Float = 0
    @Published var focusPosition: Float = 0.5
    @Published var whiteBalanceKelvin: Float = 5500
    @Published var zoom: CGFloat = 1
    @Published var rawEnabled = false
    @Published var imported = false
    @Published var lastCapture: SavedCapture?
    @Published var lastThumbnail: UIImage?
    @Published var captures: [SavedCapture] = []
    @Published var activeCameraName = "Chưa mở camera"
    @Published var interrupted = false
    @Published var changingLens = false
    @Published var adjustingExposure = false
    @Published var options = ProOptions.restored()
    @Published var mode = ShootingMode.photo
    @Published var analysis = ExposureAnalysis()
    @Published var whiteBalanceTint: Float = 0
    @Published var minEV: Float = -2
    @Published var maxEV: Float = 2
    @Published var meterEV: Float = 0
    @Published var aeLocked = false
    @Published var afLocked = false
    @Published var supportsFlash = false
    @Published var supportsTorch = false
    @Published var torchOn = false
    @Published var supportsHEIF = false
    @Published var supportsBracket = false
    @Published var photoResolution = "—"
    @Published var recording = false
    @Published var recordingBusy = false
    @Published var elapsed = 0.0
    @Published var sequenceActive = false
    @Published var sequenceProgress = ""
    @Published var videoChoices: [VideoChoice] = []
    @Published var selectedVideo: VideoChoice?
    @Published var toast = ""
    @Published var presets = CameraPreset.load()
    @Published var colorRevision = 0
    @Published var trackingTarget: TrackingTarget?
    let subjectTracker = SubjectTracker()
    var lastTrackingPoint: CGPoint?
    var advancedID: UUID?
    var nightFrames: [Data] = []
    var stackDeviceState: StackDeviceState?
    var panorama: PanoramaStitcher?
    let movieOutput = AVCaptureMovieFileOutput()
    let analyzer = FrameAnalyzer()
    var renderOptions = ProOptions.restored()
    var renderMode = ShootingMode.photo
    var currentVideo: VideoChoice?
    var audioInput: AVCaptureDeviceInput?
    var recordingStarted: TimeInterval = 0
    var recordingTimer: Timer?
    var sequenceTask: Task<Void, Never>?
    var activeMovieMode = ShootingMode.video
    var activeMovieFPS: Int32 = 30
    var frameRecorder: FrameMovieWriter?
    var accumulator: LongExposureAccumulator?
    var lastAnalysisTime: TimeInterval = 0
    var toastTask: Task<Void, Never>?
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "glens.session")
    let videoQueue = DispatchQueue(label: "glens.video", qos: .userInitiated)
    let photoQueue = DispatchQueue(label: "glens.photo", qos: .userInitiated)
    let videoOutput = AVCaptureVideoDataOutput()
    let photoOutput = AVCapturePhotoOutput()
    let engine = ColorEngine()
    let lock = NSLock()
    var color = ColorSettings()
    var importedImage: CIImage?
    var importedRAW: Data?
    var input: AVCaptureDeviceInput?
    var previewDevice: AVCaptureDevice?
    var sensorSize = CGSize(width: 3, height: 4)
    var configured = false
    var lastPreviewTime: TimeInterval = 0
    var jobs: [Int64: CaptureJob] = [:]
    var observers: [NSObjectProtocol] = []
    var pauseForBackground = false
    var exposureInFlight = false
    var exposureRevision = 0

    override init() {
        super.init()
        captures = CaptureStore.shared.all(); lastCapture = captures.first
        if let first = captures.first { lastThumbnail = CaptureStore.shared.thumbnail(first.url) }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.cancelSequence(); self?.stopRecording(); self?.clearExposureWait(); self?.cancelLongExposure(); self?.interrupted = true; self?.message = "Camera đang bị gián đoạn bởi hệ thống hoặc ứng dụng khác."
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            self?.interrupted = false; self?.start()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self.clearExposureWait()
            self.notify(error?.localizedDescription ?? "Camera gặp lỗi hệ thống.")
            if error?.code == .mediaServicesWereReset { self.sessionQueue.async { if self.configured && !self.pauseForBackground { self.session.startRunning() } } }
        })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    func clearExposureWait() {
        sessionQueue.async {
            self.exposureRevision &+= 1; self.exposureInFlight = false
            DispatchQueue.main.async { self.adjustingExposure = false }
        }
    }
    func notify(_ text: String) { DispatchQueue.main.async { self.message = text } }
    func authorizeAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.start() } else { DispatchQueue.main.async { self?.permissionDenied = true } }
            }
        default: permissionDenied = true
        }
    }
    func start() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        let isImported = locked { importedImage != nil }
        guard !isImported else { return }
        sessionQueue.async {
            guard !self.pauseForBackground else { return }
            if !self.configured {
                do { try self.configure() } catch { self.notify(error.localizedDescription); return }
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.running = self.session.isRunning; self.permissionDenied = false }
        }
    }
    func setActive(_ active: Bool) {
        if !active { cancelSequence(); stopRecording(); cancelLongExposure() }
        sessionQueue.async {
            self.pauseForBackground = !active
            if !active { self.exposureRevision &+= 1; self.exposureInFlight = false; DispatchQueue.main.async { self.adjustingExposure = false }; if self.session.isRunning { self.session.stopRunning() }; DispatchQueue.main.async { self.running = false } }
            else { self.start() }
        }
    }
    func configure() throws {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified)
        let devices = discovery.devices.sorted { a,b in
            if a.position != b.position { return a.position == .back }
            return a.deviceType == .builtInWideAngleCamera && b.deviceType != .builtInWideAngleCamera
        }
        let lensList = devices.map { device -> LensDevice in
            let title = device.position == .front ? "Trước" : device.deviceType == .builtInUltraWideCamera ? "Siêu rộng" : device.deviceType == .builtInTelephotoCamera ? "Tele" : "Chính"
            return LensDevice(id: device.uniqueID, title: title, device: device)
        }
        guard let camera = devices.first else { throw CameraError.unavailable }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }; session.outputs.forEach { session.removeOutput($0) }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        let newInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(newInput) else { throw CameraError.unavailable }
        session.addInput(newInput); input = newInput; locked { previewDevice = camera }
        photoOutput.maxPhotoQualityPrioritization = .quality
        guard session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else { throw CameraError.unavailable }
        session.addOutput(photoOutput)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.addOutput(videoOutput)
        configureOutputs(camera)
        configured = true
        DispatchQueue.main.async { self.lenses = lensList; self.selectedLens = camera.uniqueID }
        publishCapabilities(camera)
    }
    func configureOutputs(_ device: AVCaptureDevice) {
        videoQueue.async { self.subjectTracker.reset() }
        DispatchQueue.main.async { self.trackingTarget = nil; self.lastTrackingPoint = nil }
        exposureRevision &+= 1; exposureInFlight = false
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.videoZoomFactor = 1
            device.setExposureTargetBias(max(device.minExposureTargetBias, min(0, device.maxExposureTargetBias)))
            device.unlockForConfiguration()
        } catch { notify(error.localizedDescription) }
        DispatchQueue.main.async { self.adjustingExposure = false }
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = false }
        applyPhotoResolution(device)
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = device.position == .front
            }
        }
    }
    func publishCapabilities(_ device: AVCaptureDevice) {
        let raw = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let pro = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let minISO = device.activeFormat.minISO, maxISO = device.activeFormat.maxISO
        let minDuration = max(0.000001, CMTimeGetSeconds(device.activeFormat.minExposureDuration))
        let videoLimit = locked { renderMode.isMovie } ? currentVideo.map { 1.0 / Double($0.fps) } ?? 1 : Double.infinity
        let maxDuration = min(videoLimit, CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
        let choices = discoverVideoChoices(device)
        let heif = photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let bracket = photoOutput.maxBracketedCapturePhotoCount >= 3
        let dimensions = photoOutput.maxPhotoDimensions
        DispatchQueue.main.async {
            self.supportsHEIF = heif; self.supportsBracket = bracket
            self.supportsFlash = device.hasFlash; self.supportsTorch = device.hasTorch
            self.minEV = device.minExposureTargetBias; self.maxEV = device.maxExposureTargetBias
            self.aeLocked = false; self.afLocked = false; self.torchOn = false
            self.photoResolution = String(format: "%.1f MP", Double(dimensions.width) * Double(dimensions.height) / 1_000_000)
            self.videoChoices = choices
            self.supportsManual = device.isExposureModeSupported(.custom)
            self.supportsFocus = device.isLockingFocusWithCustomLensPositionSupported
            self.supportsWB = device.isWhiteBalanceModeSupported(.locked)
            self.supportsRaw = raw; self.rawLabel = pro ? "Apple ProRAW · DNG" : raw ? "Bayer RAW · DNG" : "RAW không khả dụng"
            if !raw { self.rawEnabled = false }
            self.minISO = minISO; self.maxISO = maxISO
            self.minShutter = minDuration; self.maxShutter = max(minDuration, maxDuration)
            self.maxZoom = max(1, min(10, device.activeFormat.videoMaxZoomFactor))
            self.currentISO = device.iso; self.currentShutter = CMTimeGetSeconds(device.exposureDuration)
            self.zoom = device.videoZoomFactor
            self.exposureBias = device.exposureTargetBias
            self.focusPosition = device.lensPosition
            self.whiteBalanceKelvin = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
            self.manualExposure = false; self.manualFocus = false; self.manualWB = false
            self.activeCameraName = device.localizedName
        }
    }
    func selectLens(_ id: String) {
        guard !capturing, !changingLens, !recording, !recordingBusy, !sequenceActive else { return }
        changingLens = true
        sessionQueue.async {
            defer { DispatchQueue.main.async { self.changingLens = false } }
            guard let old = self.input, id != old.device.uniqueID else { return }
            let all = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified).devices
            guard let device = all.first(where: { $0.uniqueID == id }) else { return }
            do {
                let next = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.removeInput(old)
                if self.session.canAddInput(next) {
                    self.session.addInput(next); self.input = next; self.locked { self.previewDevice = device }
                    if self.locked({ self.renderMode.isMovie }) { self.configureVideoDevice(device, requested: self.currentVideo) } else { self.configureOutputs(device) }
                    DispatchQueue.main.async { self.selectedLens = id }
                } else { self.session.addInput(old) }
                self.session.commitConfiguration()
                self.publishCapabilities(self.input!.device)
            } catch { self.notify(error.localizedDescription) }
        }
    }
    func withDevice(_ block: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let device = self.input?.device else { return }
            do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }; block(device) }
            catch { self.notify(error.localizedDescription) }
        }
    }
    func setExposure(manual: Bool, iso: Float, seconds: Double) {
        withDevice { device in
            if manual {
                guard device.isExposureModeSupported(.custom) else { return }
                let videoLimit = self.locked { self.renderMode.isMovie } ? self.currentVideo.map { 1.0 / Double($0.fps) } ?? 1 : Double.infinity
                let duration = max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), min(seconds, min(videoLimit, CMTimeGetSeconds(device.activeFormat.maxExposureDuration))))
                let value = max(device.activeFormat.minISO, min(iso, device.activeFormat.maxISO))
                self.exposureRevision &+= 1
                let revision = self.exposureRevision
                self.exposureInFlight = true
                DispatchQueue.main.async { self.adjustingExposure = true }
                device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000), iso: value) { [weak self] _ in
                    guard let self else { return }
                    self.sessionQueue.async {
                        guard self.exposureRevision == revision else { return }
                        self.exposureInFlight = false
                        DispatchQueue.main.async { self.adjustingExposure = false }
                    }
                }
            } else {
                self.exposureRevision &+= 1; self.exposureInFlight = false
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                DispatchQueue.main.async { self.adjustingExposure = false }
            }
            DispatchQueue.main.async { self.manualExposure = manual; self.aeLocked = false }
        }
    }
    func setEV(_ ev: Float) { withDevice { d in
        let value = max(d.minExposureTargetBias, min(ev, d.maxExposureTargetBias))
        d.setExposureTargetBias(value)
        DispatchQueue.main.async { self.exposureBias = value }
    } }
    func setFocus(manual: Bool, position: Float) {
        withDevice { device in
            if manual && device.isLockingFocusWithCustomLensPositionSupported { device.setFocusModeLocked(lensPosition: max(0, min(1, position))) }
            else if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            DispatchQueue.main.async { self.manualFocus = manual; self.afLocked = false; self.focusPosition = max(0, min(1, position)) }
        }
    }
    func setWB(manual: Bool, kelvin: Float, tint: Float = 0) {
        withDevice { device in
            if manual && device.isWhiteBalanceModeSupported(.locked) {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: max(2000, min(12000, kelvin)), tint: max(-150, min(150, tint)))
                var gains = device.deviceWhiteBalanceGains(for: values)
                let limit = device.maxWhiteBalanceGain
                gains.redGain = min(limit, max(1, gains.redGain)); gains.greenGain = min(limit, max(1, gains.greenGain)); gains.blueGain = min(limit, max(1, gains.blueGain))
                device.setWhiteBalanceModeLocked(with: gains)
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            DispatchQueue.main.async { self.manualWB = manual; self.whiteBalanceKelvin = max(2000, min(12000, kelvin)); self.whiteBalanceTint = tint }
        }
    }
    func setZoom(_ zoom: CGFloat) { withDevice { d in d.videoZoomFactor = min(d.activeFormat.videoMaxZoomFactor, max(1, zoom)) } }
    func focus(at point: CGPoint) {
        guard !manualFocus, !afLocked, !imported else { return }
        withDevice { device in
            let (size, ratio) = self.locked { (self.sensorSize, self.color.ratio) }
            let mapped = ProMath.sensorPoint(x: point.x, y: point.y, width: size.width, height: size.height, ratio: ratio, mirrored: device.position == .front)
            let sensorPoint = CGPoint(x: mapped.x, y: mapped.y)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = sensorPoint }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported && device.exposureMode != .custom && device.exposureMode != .locked { device.exposurePointOfInterest = sensorPoint }
        }
    }
    func updateColor(_ settings: ColorSettings) {
        locked { color = settings }
        settings.save()
        if let image = locked({ importedImage }) {
            photoQueue.async { self.renderImported(image) }
        }
    }
    func setCompare(_ original: Bool) {
        let settings: ColorSettings = locked { color.compare = original; return color }
        if let image = locked({ importedImage }) {
            photoQueue.async {
                if let result = self.engine.uiImage(self.engine.process(image, settings: settings, preview: true)) { DispatchQueue.main.async { self.preview = result } }
            }
        }
    }
    func importPhoto(_ data: Data) {
        guard !recording, !recordingBusy, !sequenceActive, !capturing, !changingLens else { return }
        changingLens = true
        photoQueue.async {
            let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) }.map { $0 as String }
            let isRAW = type.flatMap { UTType($0) }?.conforms(to: .rawImage) == true
            let image: CIImage?
            if isRAW { image = CIRAWFilter(imageData: data, identifierHint: type)?.outputImage }
            else { image = CIImage(data: data, options: [.applyOrientationProperty: true]) }
            guard let image else {
                self.notify(isRAW ? "iOS chưa giải mã được RAW này. Hãy thử DNG từ iPhone hoặc JPEG/HEIF." : "Không đọc được ảnh này.")
                DispatchQueue.main.async { self.changingLens = false }; return
            }
            // Preserve only real DNG under the .dng extension; never relabel NEF/CR3.
            let dng = type == "com.adobe.raw-image" ? data : nil
            self.locked { self.importedImage = image; self.importedRAW = dng }
            self.sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
            DispatchQueue.main.async { self.imported = true; self.running = false; self.changingLens = false; self.trackingTarget = nil }
            self.renderImported(image)
        }
    }
    func renderImported(_ image: CIImage) {
        let settings = locked { color }
        if let result = engine.uiImage(engine.process(image, settings: settings, preview: true)) { DispatchQueue.main.async { self.preview = result } }
    }
    func returnToCamera() { locked { importedImage = nil; importedRAW = nil }; imported = false; authorizeAndStart() }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), locked({ importedImage == nil }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            let state = locked { () -> (ColorSettings, ProOptions, ShootingMode) in
                sensorSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                return (color, renderOptions, renderMode)
            }
            frameRecorder?.append(source, now: now)
            if let panorama {
                let finished = panorama.append(source, now: now, context: engine.context)
                let hint = panorama.hint
                DispatchQueue.main.async {
                    if self.mode == .panorama && self.sequenceActive && !self.capturing { self.sequenceProgress = hint; if finished { self.finishPanorama() } }
                }
            }
            let tracking = subjectTracker.update(engine.crop(source, ratio: state.0.ratio), mode: state.1.tracking, now: now)
            if tracking.updated { DispatchQueue.main.async { self.applyTracking(tracking.target) } }
            if let accumulator {
                if accumulator.append(source, now: now, context: engine.context) {
                    self.accumulator = nil
                    if let final = accumulator.result {
                        DispatchQueue.main.async { self.sequenceProgress = "Đang lưu…" }
                        photoQueue.async { self.finishImage(final, settings: state.0, raw: nil, metadata: "STACK \(Int(accumulator.duration))s · \(accumulator.count) frames", options: state.1) }
                    } else { DispatchQueue.main.async { self.capturing = false } }
                } else {
                    DispatchQueue.main.async { self.sequenceProgress = String(format: "%.1f / %.0f s", now - accumulator.start, accumulator.duration) }
                }
            }
            guard now - lastPreviewTime > 1.0 / 24 else { return }; lastPreviewTime = now
            var display = state.0
            if state.2.isMovie { display.compare = true; display.ratio = 9.0 / 16 }
            locked { lookPreviewSource = source }
            let image = engine.process(source, settings: display, preview: true)
            guard let result = engine.uiImage(image) else { return }
            var analysis: ExposureAnalysis?
            if now - lastAnalysisTime > 0.16 && (state.1.histogram || state.1.peaking || state.1.zebra) {
                lastAnalysisTime = now; analysis = analyzer.analyze(image, options: state.1)
            }
            let device = locked { previewDevice }
            let iso = device?.iso ?? 100, duration = device.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0.008
            let offset = device?.exposureTargetOffset ?? 0
            DispatchQueue.main.async {
                self.preview = result; self.currentISO = iso; self.currentShutter = duration; self.meterEV = offset
                if let analysis { self.analysis = analysis }
            }
        }
    }
    func capture(purpose: CapturePurpose = .normal) {
        guard !capturing, !changingLens else { return }
        capturing = true
        let settings = locked { color }
        if let importedImage = locked({ importedImage }) {
            let options = self.options
            let raw = locked { importedRAW }
            photoQueue.async { self.finishImage(importedImage, settings: settings, raw: raw, metadata: raw == nil ? "ẢNH NHẬP" : "DNG DEVELOPED", options: options) }; return
        }
        let requestedRAW = rawEnabled && purpose == .normal
        var options = self.options
        if purpose != .normal { options.sequence = purpose == .hdr ? .bracket : .single; options.flash = 0 }
        let portrait = mode == .portrait
        sessionQueue.async {
            guard !self.exposureInFlight else {
                self.notify("Đợi camera áp xong ISO/tốc độ rồi chụp lại.")
                DispatchQueue.main.async { self.capturing = false }; return
            }
            guard self.session.isRunning, let device = self.input?.device else {
                self.notify("Bật camera trước khi chụp."); DispatchQueue.main.async { self.capturing = false }; return
            }
            if purpose == .hdr && self.photoOutput.maxBracketedCapturePhotoCount < 3 {
                self.notify("Camera này chưa hỗ trợ chuỗi bracket 3 ảnh cho HDR.")
                DispatchQueue.main.async { self.capturing = false }; return
            }
            let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? self.photoOutput.availableRawPhotoPixelFormatTypes.first
            let photoSettings: AVCapturePhotoSettings
            if options.sequence == .bracket, self.photoOutput.maxBracketedCapturePhotoCount >= 3 {
                let brackets: [AVCaptureBracketedStillImageSettings]
                if device.exposureMode == .custom {
                    brackets = [-options.bracketEV, 0, options.bracketEV].map { ev in
                        let duration = max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), min(CMTimeGetSeconds(device.activeFormat.maxExposureDuration), CMTimeGetSeconds(device.exposureDuration) * pow(2, Double(ev))))
                        return AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(exposureDuration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000), iso: device.iso)
                    }
                } else {
                    brackets = ProMath.bracketBiases(center: device.exposureTargetBias, step: options.bracketEV, minimum: device.minExposureTargetBias, maximum: device.maxExposureTargetBias).map { AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: $0) }
                }
                photoSettings = AVCapturePhotoBracketSettings(rawPixelFormatType: 0, processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg], bracketedSettings: brackets)
            } else if requestedRAW, let rawFormat { photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]) }
            else { photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) }
            photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            // Apple's custom exposure contract: speed prioritization preserves requested ISO/duration.
            photoSettings.photoQualityPrioritization = device.exposureMode == .custom || photoSettings is AVCapturePhotoBracketSettings ? .speed : .quality
            if !(photoSettings is AVCapturePhotoBracketSettings) && device.hasFlash {
                let flash: AVCaptureDevice.FlashMode = options.flash == 1 ? .auto : options.flash == 2 ? .on : .off
                if self.photoOutput.supportedFlashModes.contains(flash) { photoSettings.flashMode = flash }
            }
            let duration = CMTimeGetSeconds(device.exposureDuration)
            let shutter = duration < 1 ? "1/\(Int((1 / max(duration, 0.000001)).rounded()))s" : String(format: "%.1fs", duration)
            let metadata = String(format: "ISO %.0f  %@  %.1f×", device.iso, shutter, device.videoZoomFactor)
            self.jobs[photoSettings.uniqueID] = CaptureJob(color: settings, metadata: metadata, requestedRAW: requestedRAW && options.sequence != .bracket, zoom: device.videoZoomFactor, options: options, portrait: portrait, purpose: purpose)
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = photo.fileDataRepresentation()
        let isRaw = photo.isRawPhoto
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        sessionQueue.async {
            guard var job = self.jobs[id] else { return }
            if let error { job.error = error.localizedDescription }
            if isRaw { job.raw = data } else {
                job.jpeg = data
                if let exif,
                   let duration = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
                   let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue,
                   duration > 0 {
                    let shutter = duration < 1 ? "1/\(Int((1 / duration).rounded()))s" : String(format: "%.1fs", duration)
                    job.metadata = String(format: "ISO %.0f  %@  %.1f×", iso, shutter, job.zoom)
                }
            }
            if !isRaw, let data { job.frames.append(data); job.frameMetadata.append(job.metadata) }
            self.jobs[id] = job
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async {
            guard let job = self.jobs.removeValue(forKey: resolvedSettings.uniqueID) else { return }
            if case .night(let id) = job.purpose {
                DispatchQueue.main.async { self.acceptNight(job.jpeg, id: id) }; return
            }
            guard let jpeg = job.jpeg, let image = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else {
                self.notify(error?.localizedDescription ?? job.error ?? "Không nhận được ảnh từ camera.")
                DispatchQueue.main.async { self.capturing = false }; return
            }
            let warning = [error?.localizedDescription, job.error, job.requestedRAW && job.raw == nil ? "DNG yêu cầu chưa được camera trả về; JPEG vẫn được giữ." : nil].compactMap { $0 }.joined(separator: " ")
            if job.options.sequence == .bracket && job.frames.count != 3 { self.notify("Camera chỉ trả về \(job.frames.count)/3 ảnh bracket. Các ảnh nhận được vẫn được giữ.") }
            self.photoQueue.async {
                if job.purpose == .hdr {
                    let images = job.frames.compactMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
                    guard let result = ImageFusion.fuse(images, kind: .hdr, context: self.engine.context) else {
                        self.finishImage(image, settings: job.color, raw: nil, metadata: "HDR fallback · " + job.metadata, warning: "Không ghép được HDR; đã giữ một ảnh nguồn.", options: job.options, original: jpeg); return
                    }
                    self.finishImage(result.image, settings: job.color, raw: nil, metadata: "HDR · \(result.used)/3 ảnh · fusion SDR", warning: result.used < 3 ? "Chỉ ghép được \(result.used)/3 khung. Hãy giữ máy yên khi chụp HDR." : nil, options: job.options, original: job.frames.dropFirst().first ?? jpeg)
                } else if job.purpose == .document {
                    let (document, corrected) = self.documentImage(image, monochrome: job.options.documentMono)
                    var settings = job.color; settings.ratio = document.extent.width/document.extent.height
                    self.finishImage(document, settings: settings, raw: nil, metadata: "DOC · " + job.metadata, warning: corrected ? nil : "Không tìm được bốn góc tài liệu; đã giữ nguyên khung ảnh.", options: job.options, original: jpeg)
                } else if job.frames.count > 1 {
                    defer { DispatchQueue.main.async { self.capturing = false; self.sequenceProgress = "" } }
                    for (index, frame) in job.frames.enumerated() {
                        guard let image = CIImage(data: frame, options: [.applyOrientationProperty: true]) else { continue }
                        self.finishImage(image, settings: job.color, raw: nil, metadata: "BKT \(index + 1)/\(job.frames.count) · " + job.frameMetadata[index], warning: nil, options: job.options, original: frame, completesCapture: false)
                    }
                } else {
                    self.finishImage(image, settings: job.color, raw: job.raw, metadata: job.metadata, warning: warning.isEmpty ? nil : warning, options: job.options, original: jpeg, portrait: job.portrait)
                }
            }
        }
    }
    func finishImage(_ image: CIImage, settings: ColorSettings, raw: Data?, metadata: String, warning: String? = nil, options: ProOptions = ProOptions(), original: Data? = nil, portrait: Bool = false, completesCapture: Bool = true) {
        autoreleasepool {
            var finalSettings = settings; finalSettings.compare = false
            let source = (portrait ? portraitImage(image, amount: options.portraitBlur) : image).settingProperties(image.properties)
            guard let jpeg = engine.jpeg(source, settings: finalSettings, metadata: metadata, encoding: options.encoding) else { notify("Chưa xuất được ảnh " + options.encoding.rawValue + "."); DispatchQueue.main.async { self.capturing = false }; return }
            do {
                let item = try CaptureStore.shared.store(jpeg: jpeg, raw: raw, encoding: options.encoding, original: options.saveOriginal ? original : nil, metadata: metadata)
                let thumb = CaptureStore.shared.thumbnail(item.url)
                DispatchQueue.main.async {
                    self.lastCapture = item; self.lastThumbnail = thumb; self.captures.insert(item, at: 0)
                    if completesCapture { self.capturing = false; self.sequenceProgress = "" }
                    self.showToast("Đã lưu " + options.encoding.rawValue + (raw == nil ? "" : " + DNG"))
                    if let warning { self.message = warning }
                    if let warning = item.rawWarning { self.message = warning }
                }
                if options.autoSavePhotos { CaptureStore.shared.saveToPhotos(item) { text in if !text.hasPrefix("Đã") { self.notify(text) } } }

            } catch { notify(error.localizedDescription); DispatchQueue.main.async { self.capturing = false } }
        }
    }
}
enum CameraError: LocalizedError { case unavailable; var errorDescription: String? { "Không tìm thấy camera tương thích. Thử trên iPhone thật." } }
