import Foundation
import AVFoundation
import CoreImage
import UIKit
import Combine
import ImageIO

struct LensDevice: Identifiable { let id: String; let title: String; let device: AVCaptureDevice }
private struct CaptureJob {
    let color: ColorSettings
    var metadata: String
    var requestedRAW = false
    var zoom: CGFloat = 1
    var jpeg: Data?
    var raw: Data?
    var error: String?
}
final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    @Published var preview: UIImage?
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
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "glens.session")
    private let videoQueue = DispatchQueue(label: "glens.video", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "glens.photo", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let engine = ColorEngine()
    private let lock = NSLock()
    private var color = ColorSettings()
    private var importedImage: CIImage?
    private var input: AVCaptureDeviceInput?
    private var previewDevice: AVCaptureDevice?
    private var sensorSize = CGSize(width: 3, height: 4)
    private var configured = false
    private var lastPreviewTime: TimeInterval = 0
    private var jobs: [Int64: CaptureJob] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pauseForBackground = false
    private var exposureInFlight = false
    private var exposureRevision = 0

    override init() {
        super.init()
        captures = CaptureStore.shared.all(); lastCapture = captures.first
        if let first = captures.first { lastThumbnail = CaptureStore.shared.thumbnail(first.url) }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.clearExposureWait(); self?.interrupted = true; self?.message = "Camera đang bị gián đoạn bởi hệ thống hoặc ứng dụng khác."
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
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func clearExposureWait() {
        sessionQueue.async {
            self.exposureRevision &+= 1; self.exposureInFlight = false
            DispatchQueue.main.async { self.adjustingExposure = false }
        }
    }
    private func notify(_ text: String) { DispatchQueue.main.async { self.message = text } }
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
        sessionQueue.async {
            self.pauseForBackground = !active
            if !active { self.exposureRevision &+= 1; self.exposureInFlight = false; DispatchQueue.main.async { self.adjustingExposure = false }; if self.session.isRunning { self.session.stopRunning() }; DispatchQueue.main.async { self.running = false } }
            else { self.start() }
        }
    }
    private func configure() throws {
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
    private func configureOutputs(_ device: AVCaptureDevice) {
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
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = device.position == .front
            }
        }
    }
    private func publishCapabilities(_ device: AVCaptureDevice) {
        let raw = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let pro = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        let minISO = device.activeFormat.minISO, maxISO = device.activeFormat.maxISO
        let minDuration = max(0.000001, CMTimeGetSeconds(device.activeFormat.minExposureDuration))
        let maxDuration = min(1, CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
        DispatchQueue.main.async {
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
        guard !capturing, !changingLens else { return }
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
                    self.configureOutputs(device)
                    DispatchQueue.main.async { self.selectedLens = id }
                } else { self.session.addInput(old) }
                self.session.commitConfiguration()
                self.publishCapabilities(self.input!.device)
            } catch { self.notify(error.localizedDescription) }
        }
    }
    private func withDevice(_ block: @escaping (AVCaptureDevice) -> Void) {
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
                let duration = max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), min(seconds, CMTimeGetSeconds(device.activeFormat.maxExposureDuration)))
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
            DispatchQueue.main.async { self.manualExposure = manual }
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
            DispatchQueue.main.async { self.manualFocus = manual; self.focusPosition = max(0, min(1, position)) }
        }
    }
    func setWB(manual: Bool, kelvin: Float) {
        withDevice { device in
            if manual && device.isWhiteBalanceModeSupported(.locked) {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: max(2500, min(9000, kelvin)), tint: 0)
                var gains = device.deviceWhiteBalanceGains(for: values)
                let limit = device.maxWhiteBalanceGain
                gains.redGain = min(limit, max(1, gains.redGain)); gains.greenGain = min(limit, max(1, gains.greenGain)); gains.blueGain = min(limit, max(1, gains.blueGain))
                device.setWhiteBalanceModeLocked(with: gains)
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            DispatchQueue.main.async { self.manualWB = manual; self.whiteBalanceKelvin = max(2500, min(9000, kelvin)) }
        }
    }
    func setZoom(_ zoom: CGFloat) { withDevice { d in d.videoZoomFactor = min(d.activeFormat.videoMaxZoomFactor, max(1, zoom)) } }
    func focus(at point: CGPoint) {
        guard !manualFocus, !imported else { return }
        withDevice { device in
            let (size, ratio) = self.locked { (self.sensorSize, self.color.ratio) }
            var cw = size.width, ch = size.width / ratio
            if ch > size.height { ch = size.height; cw = size.height * ratio }
            var px = ((size.width - cw) * 0.5 + point.x * cw) / size.width
            let py = ((size.height - ch) * 0.5 + point.y * ch) / size.height
            if device.position == .front { px = 1 - px }
            let sensorPoint = CGPoint(x: py, y: 1 - px)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = sensorPoint }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported && device.exposureMode != .custom { device.exposurePointOfInterest = sensorPoint }
        }
    }
    func updateColor(_ settings: ColorSettings) {
        locked { color = settings }
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
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { notify("Không đọc được ảnh này."); return }
        locked { importedImage = image }
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        imported = true; running = false
        photoQueue.async { self.renderImported(image) }
    }
    private func renderImported(_ image: CIImage) {
        let settings = locked { color }
        if let result = engine.uiImage(engine.process(image, settings: settings, preview: true)) { DispatchQueue.main.async { self.preview = result } }
    }
    func returnToCamera() { locked { importedImage = nil }; imported = false; authorizeAndStart() }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPreviewTime > 1.0 / 15.0, locked({ importedImage == nil }), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPreviewTime = now
        autoreleasepool {
            let settings = locked { sensorSize = CGSize(width: CGFloat(CVPixelBufferGetWidth(buffer)), height: CGFloat(CVPixelBufferGetHeight(buffer))); return color }
            let image = engine.process(CIImage(cvPixelBuffer: buffer), settings: settings, preview: true)
            guard let result = engine.uiImage(image) else { return }
            let device = locked { previewDevice }
            let iso = device?.iso ?? 100, duration = device.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0.008
            DispatchQueue.main.async { self.preview = result; self.currentISO = iso; self.currentShutter = duration }
        }
    }
    func capture() {
        guard !capturing, !changingLens else { return }
        capturing = true
        let settings = locked { color }
        if let importedImage = locked({ importedImage }) {
            photoQueue.async { self.finishImage(importedImage, settings: settings, raw: nil, metadata: "ẢNH NHẬP") }; return
        }
        let requestedRAW = rawEnabled
        sessionQueue.async {
            guard !self.exposureInFlight else {
                self.notify("Đợi camera áp xong ISO/tốc độ rồi chụp lại.")
                DispatchQueue.main.async { self.capturing = false }; return
            }
            guard self.session.isRunning, let device = self.input?.device else {
                self.notify("Bật camera trước khi chụp."); DispatchQueue.main.async { self.capturing = false }; return
            }
            let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? self.photoOutput.availableRawPhotoPixelFormatTypes.first
            let photoSettings: AVCapturePhotoSettings
            if requestedRAW, let rawFormat { photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]) }
            else { photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) }
            photoSettings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            // Apple's custom exposure contract: speed prioritization preserves requested ISO/duration.
            photoSettings.photoQualityPrioritization = device.exposureMode == .custom ? .speed : .quality
            photoSettings.flashMode = .off
            let duration = CMTimeGetSeconds(device.exposureDuration)
            let shutter = duration < 1 ? "1/\(Int((1 / max(duration, 0.000001)).rounded()))s" : String(format: "%.1fs", duration)
            let metadata = String(format: "ISO %.0f  %@  %.1f×", device.iso, shutter, device.videoZoomFactor)
            self.jobs[photoSettings.uniqueID] = CaptureJob(color: settings, metadata: metadata, requestedRAW: requestedRAW, zoom: device.videoZoomFactor)
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
            self.jobs[id] = job
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async {
            guard let job = self.jobs.removeValue(forKey: resolvedSettings.uniqueID) else { return }
            guard let jpeg = job.jpeg, let image = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else {
                self.notify(error?.localizedDescription ?? job.error ?? "Không nhận được ảnh từ camera.")
                DispatchQueue.main.async { self.capturing = false }; return
            }
            let warning = [error?.localizedDescription, job.error, job.requestedRAW && job.raw == nil ? "DNG yêu cầu chưa được camera trả về; JPEG vẫn được giữ." : nil].compactMap { $0 }.joined(separator: " ")
            self.photoQueue.async { self.finishImage(image, settings: job.color, raw: job.raw, metadata: job.metadata, warning: warning.isEmpty ? nil : warning) }
        }
    }
    private func finishImage(_ image: CIImage, settings: ColorSettings, raw: Data?, metadata: String, warning: String? = nil) {
        autoreleasepool {
            var finalSettings = settings; finalSettings.compare = false
            guard let jpeg = engine.jpeg(image, settings: finalSettings, metadata: metadata) else { notify("Chưa xuất được JPEG."); DispatchQueue.main.async { self.capturing = false }; return }
            do {
                let item = try CaptureStore.shared.store(jpeg: jpeg, raw: raw)
                let thumb = CaptureStore.shared.thumbnail(item.url)
                DispatchQueue.main.async { self.lastCapture = item; self.lastThumbnail = thumb; self.captures.insert(item, at: 0); self.capturing = false; self.message = ([item.rawURL == nil ? "Đã chụp JPEG. Mở thư viện để lưu hoặc chia sẻ." : "Đã chụp JPEG màu + DNG gốc.", warning, item.rawWarning].compactMap { $0 }).joined(separator: " ") }
            } catch { notify(error.localizedDescription); DispatchQueue.main.async { self.capturing = false } }
        }
    }
}
enum CameraError: LocalizedError { case unavailable; var errorDescription: String? { "Không tìm thấy camera tương thích. Thử trên iPhone thật." } }
