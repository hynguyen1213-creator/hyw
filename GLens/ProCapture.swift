import Foundation
import AVFoundation
import CoreImage
import UIKit
import Vision

extension CameraController {
    func showToast(_ value: String) {
        toastTask?.cancel(); toast = value
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self.toast = "" }
        }
    }
    func updateOptions() {
        if options.sequence == .bracket || mode.computational { rawEnabled = false }
        options.save(); let value = options
        locked { renderOptions = value }
        guard !capturing, !recording, !recordingBusy, !sequenceActive else { return }
        sessionQueue.async { if let device = self.input?.device, !self.locked({ self.renderMode.isMovie }) { self.applyPhotoResolution(device) } }
    }
    func applyPhotoResolution(_ device: AVCaptureDevice) {
        let choices = device.activeFormat.supportedMaxPhotoDimensions.sorted { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        let maximum = locked { renderOptions.maximumResolution && renderOptions.sequence != .bracket && !renderMode.computational }
        guard let size = maximum ? choices.last : (choices.last(where: { Int64($0.width) * Int64($0.height) <= 13_000_000 }) ?? choices.first) else { return }
        photoOutput.maxPhotoDimensions = size
        DispatchQueue.main.async { self.photoResolution = String(format: "%.1f MP", Double(size.width) * Double(size.height) / 1_000_000) }
    }
    func toggleAELock() {
        let enabled = !aeLocked
        withDevice { device in
            guard device.exposureMode != .custom else { return }
            if device.isExposureModeSupported(enabled ? .locked : .continuousAutoExposure) {
                device.exposureMode = enabled ? .locked : .continuousAutoExposure
                DispatchQueue.main.async { self.aeLocked = enabled }
            }
        }
    }
    func toggleAFLock() {
        let enabled = !afLocked
        withDevice { device in
            guard device.isFocusModeSupported(enabled ? .locked : .continuousAutoFocus) else { return }
            device.focusMode = enabled ? .locked : .continuousAutoFocus
            DispatchQueue.main.async { self.afLocked = enabled; self.manualFocus = false }
        }
    }
    func setTorch(_ enabled: Bool) {
        withDevice { device in
            guard device.hasTorch, device.isTorchAvailable else { return }
            do {
                if enabled { try device.setTorchModeOn(level: 0.5) } else { device.torchMode = .off }
                DispatchQueue.main.async { self.torchOn = enabled }
            } catch { self.notify(error.localizedDescription) }
        }
    }
    func resetHardware() {
        setExposure(manual: false, iso: currentISO, seconds: currentShutter)
        setFocus(manual: false, position: focusPosition); setWB(manual: false, kelvin: 5500)
        setEV(0); setTorch(false); aeLocked = false; afLocked = false
    }
    func savePreset(name: String, color: ColorSettings) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = CameraPreset(name: String(trimmed.prefix(40)), color: color, manualExposure: manualExposure, iso: currentISO, shutter: currentShutter, manualFocus: manualFocus, focus: focusPosition, manualWB: manualWB, kelvin: whiteBalanceKelvin, tint: whiteBalanceTint, ev: exposureBias)
        presets.append(preset); CameraPreset.save(presets)
    }
    func applyPreset(_ preset: CameraPreset) {
        guard !capturing, !recording, !recordingBusy else { return }
        updateColor(preset.color); colorRevision += 1
        setExposure(manual: preset.manualExposure && supportsManual, iso: preset.iso, seconds: preset.shutter)
        setFocus(manual: preset.manualFocus && supportsFocus, position: preset.focus)
        setWB(manual: preset.manualWB && supportsWB, kelvin: preset.kelvin, tint: preset.tint); setEV(preset.ev)
        showToast("Đã áp preset " + preset.name)
    }
    func currentColor() -> ColorSettings { locked { color } }
    func shutterAction() {
        if recording || recordingBusy { stopRecording(); return }
        if mode == .panorama && sequenceActive { finishPanorama(); return }
        if sequenceActive { cancelSequence(); return }
        if imported { capture(); return }
        if mode == .hdr { capture(purpose: .hdr); return }
        if mode == .night { startNight(); return }
        if mode == .panorama { startPanorama(); return }
        if mode == .document { capture(purpose: .document); return }
        if mode.isMovie { startRecording(); return }
        if mode == .longExposure { startLongExposure(); return }
        if options.sequence == .single || options.sequence == .bracket || imported { capture(); return }
        sequenceActive = true
        let count = max(2, min(99, options.sequenceCount))
        let interval = options.sequence == .interval ? max(0.5, options.intervalSeconds) : 0
        sequenceTask = Task { @MainActor in
            defer { self.sequenceActive = false; self.sequenceProgress = "" }
            for index in 0..<count {
                if Task.isCancelled || !self.running { return }
                self.sequenceProgress = "\(index + 1) / \(count)"
                let started = ProcessInfo.processInfo.systemUptime
                self.capture()
                while self.capturing && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(80)) }
                if Task.isCancelled { return }
                let wait = max(0.08, interval - (ProcessInfo.processInfo.systemUptime - started))
                if index < count - 1 { try? await Task.sleep(for: .seconds(wait)) }
            }
        }
    }
    func cancelSequence() { cancelAdvanced(); sequenceTask?.cancel(); sequenceTask = nil; sequenceActive = false; sequenceProgress = "" }
    func startLongExposure() {
        guard !capturing, running, !changingLens else { return }
        capturing = true; let configuration = options
        videoQueue.async { self.accumulator = LongExposureAccumulator(duration: configuration.longSeconds, blend: configuration.longBlend) }
    }
    func cancelLongExposure() {
        videoQueue.async {
            guard self.accumulator != nil else { return }
            self.accumulator = nil
            DispatchQueue.main.async { self.capturing = false; self.sequenceProgress = "" }
        }
    }
    func portraitImage(_ image: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return image }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate; request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
            guard let buffer = request.results?.first?.pixelBuffer else { return image }
            var mask = CIImage(cvPixelBuffer: buffer)
            let average = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: mask.extent)])
            var rgba = [Float](repeating: 0, count: 4)
            engine.context.render(average, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
            guard rgba[0] > 0.002 else { DispatchQueue.main.async { self.showToast("Không tìm thấy người; giữ ảnh không xoá phông") }; return image }
            mask = mask.transformed(by: CGAffineTransform(scaleX: image.extent.width / mask.extent.width, y: image.extent.height / mask.extent.height))
            mask = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, image.extent.width / 1600)]).cropped(to: image.extent)
            let background = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: amount * image.extent.width / 65]).cropped(to: image.extent)
            return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
        } catch { notify("Không tách được người; đã giữ ảnh không xoá phông."); return image }
    }
    func refreshGallery() {
        captures = CaptureStore.shared.all(); lastCapture = captures.first
        lastThumbnail = captures.first.flatMap { CaptureStore.shared.thumbnail($0.url) }
    }
    func discoverVideoChoices(_ device: AVCaptureDevice) -> [VideoChoice] {
        var found: [String: VideoChoice] = [:]
        for format in device.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard (size.width == 1920 && size.height == 1080) || (size.width == 3840 && size.height == 2160) else { continue }
            let tenBit = CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            for fps in [Int32(24), 25, 30, 50, 60, 120, 240] {
                guard format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }) else { continue }
                for tone in VideoTone.allCases {
                    if tone == .standard && !format.supportedColorSpaces.contains(.sRGB) { continue }
                    if tone == .log && (!tenBit || !format.supportedColorSpaces.contains(.appleLog)) { continue }
                    if tone == .hlg && (!tenBit || !format.supportedColorSpaces.contains(.HLG_BT2020)) { continue }
                    let choice = VideoChoice(width: size.width, height: size.height, fps: fps, tone: tone)
                    found[choice.id] = choice
                }
            }
        }
        return found.values.sorted { ($0.width, $0.fps, $0.tone.rawValue) < ($1.width, $1.fps, $1.tone.rawValue) }
    }
    func changeMode(_ newMode: ShootingMode) {
        guard !capturing, !recording, !recordingBusy, !sequenceActive, !changingLens, !imported else { return }
        changingLens = true; mode = newMode
        if newMode.computational { rawEnabled = false }
        locked { renderMode = newMode }
        sessionQueue.async {
            defer { DispatchQueue.main.async { self.changingLens = false } }
            guard let device = self.input?.device else { return }
            self.session.beginConfiguration()
            if newMode.isMovie {
                if self.session.outputs.contains(self.photoOutput) { self.session.removeOutput(self.photoOutput) }
                if newMode != .timeLapse, !self.session.outputs.contains(self.movieOutput), self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
                if newMode == .timeLapse, self.session.outputs.contains(self.movieOutput) { self.session.removeOutput(self.movieOutput) }
                self.configureVideoDevice(device, requested: self.currentVideo)
            } else {
                if self.session.outputs.contains(self.movieOutput) { self.session.removeOutput(self.movieOutput) }
                if let audio = self.audioInput { self.session.removeInput(audio); self.audioInput = nil }
                self.session.sessionPreset = .photo
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                if !self.session.outputs.contains(self.photoOutput), self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
                self.configureOutputs(device)
            }
            self.session.commitConfiguration()
            self.publishCapabilities(device)
        }
    }
    func selectVideo(_ choice: VideoChoice) {
        guard !recording, !recordingBusy, !changingLens, mode.isMovie else { return }
        changingLens = true
        sessionQueue.async {
            defer { DispatchQueue.main.async { self.changingLens = false } }
            guard let device = self.input?.device else { return }
            self.session.beginConfiguration(); self.configureVideoDevice(device, requested: choice); self.session.commitConfiguration()
            self.publishCapabilities(device)
        }
    }
    func configureVideoDevice(_ device: AVCaptureDevice, requested: VideoChoice?) {
        let mode = locked { renderMode }
        let options = locked { renderOptions }
        let choices = discoverVideoChoices(device).filter {
            if mode == .slowMotion { return $0.fps >= 120 && $0.tone == .standard }
            if mode == .timeLapse { return $0.width == 1920 && $0.fps == 30 && $0.tone == .standard }
            return $0.fps <= 120
        }
        guard let choice = choices.first(where: { $0 == requested }) ?? choices.first(where: { $0.width == 1920 && $0.fps == 30 && $0.tone == .standard }) ?? choices.first else {
            currentVideo = nil
            DispatchQueue.main.async { self.selectedVideo = nil }
            notify("Camera này không hỗ trợ chế độ video đã chọn."); return
        }
        let colorSpace: AVCaptureColorSpace = choice.tone == .log ? .appleLog : choice.tone == .hlg ? .HLG_BT2020 : .sRGB
        currentVideo = nil
        DispatchQueue.main.async { self.selectedVideo = nil }
        let candidates = device.formats.filter { f in
            let size = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let tenBit = CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            return size.width == choice.width && size.height == choice.height && f.supportedColorSpaces.contains(colorSpace) && (choice.tone == .standard || tenBit) && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(choice.fps) && $0.maxFrameRate >= Double(choice.fps) }
        }
        guard let format = candidates.first else { notify("Không có định dạng quay phù hợp."); return }
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: choice.fps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: choice.fps)
            device.activeColorSpace = colorSpace
            self.exposureRevision &+= 1; self.exposureInFlight = false
            DispatchQueue.main.async { self.adjustingExposure = false }
            if device.hasTorch { device.torchMode = .off }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            let pixel: OSType = choice.tone == .standard ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            if videoOutput.availableVideoPixelFormatTypes.contains(pixel) { videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixel] }
            for connection in [movieOutput.connection(with: .video), videoOutput.connection(with: .video)].compactMap({ $0 }) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = device.position == .front }
                if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = options.stabilization ? .standard : .off }
            }
            if let connection = movieOutput.connection(with: .video) {
                let codecs = movieOutput.availableVideoCodecTypes
                let codec: AVVideoCodecType = codecs.contains(.hevc) ? .hevc : .h264
                movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection)
                movieOutput.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
            }
            currentVideo = choice
            DispatchQueue.main.async { self.selectedVideo = choice }
        } catch { notify(error.localizedDescription) }
    }
    func startRecording() {
        guard mode.isMovie, running, !changingLens, !recording, !recordingBusy, selectedVideo != nil else { return }
        recordingBusy = true
        let captureMode = mode, options = self.options
        let wantsAudio = options.microphone && mode == .video
        if wantsAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { self.beginRecording(mode: captureMode, options: options, audio: granted) }
            }
        } else { beginRecording(mode: captureMode, options: options, audio: wantsAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) }
    }
    func beginRecording(mode: ShootingMode, options: ProOptions, audio: Bool) {
        sessionQueue.async {
            guard self.session.isRunning, !self.pauseForBackground, let choice = self.currentVideo else { DispatchQueue.main.async { self.recordingBusy = false }; return }
            self.activeMovieMode = mode; self.activeMovieFPS = choice.fps
            if mode == .timeLapse {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                do {
                    let writer = try FrameMovieWriter(url: url, interval: options.lapseInterval)
                    self.videoQueue.async { self.frameRecorder = writer }
                    DispatchQueue.main.async { self.didStartRecording() }
                } catch { self.notify(error.localizedDescription); DispatchQueue.main.async { self.recordingBusy = false } }
                return
            }
            self.session.beginConfiguration()
            if let previous = self.audioInput { self.session.removeInput(previous); self.audioInput = nil }
            if audio, let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(input) { self.session.addInput(input); self.audioInput = input }
            self.session.commitConfiguration()
            guard self.movieOutput.connection(with: .video) != nil else { self.notify("Đầu ra video chưa sẵn sàng."); DispatchQueue.main.async { self.recordingBusy = false }; return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            if options.microphone && mode == .video && !audio { DispatchQueue.main.async { self.showToast("Đang quay không có mic. Bật Micro trong Cài đặt để thu tiếng.") } }
        }
    }
    func didStartRecording() {
        recording = true; recordingBusy = false; elapsed = 0; recordingStarted = ProcessInfo.processInfo.systemUptime
        UIApplication.shared.isIdleTimerDisabled = true
        if UIApplication.shared.applicationState != .active { stopRecording(); return }
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }; self.elapsed = ProcessInfo.processInfo.systemUptime - self.recordingStarted
        }
    }
    func stopRecording() {
        guard recording else { return }
        recording = false; recordingBusy = true
        recordingTimer?.invalidate(); recordingTimer = nil; UIApplication.shared.isIdleTimerDisabled = false
        if activeMovieMode == .timeLapse {
            videoQueue.async {
                guard let writer = self.frameRecorder else { DispatchQueue.main.async { self.recordingBusy = false }; return }
                self.frameRecorder = nil
                writer.finish { result in
                    switch result { case .success(let url): self.storeMovie(url, metadata: "TIME-LAPSE · 1080p · 30 fps")
                    case .failure(let error): self.notify(error.localizedDescription); DispatchQueue.main.async { self.recordingBusy = false } }
                }
            }
        } else { sessionQueue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } } }
    }
    func storeMovie(_ url: URL, metadata: String) {
        photoQueue.async {
            do {
                let item = try CaptureStore.shared.storeMovie(url: url, metadata: metadata)
                let thumbnail = CaptureStore.shared.thumbnail(item.url)
                DispatchQueue.main.async {
                    self.captures.insert(item, at: 0); self.lastCapture = item; self.lastThumbnail = thumbnail
                    self.recordingBusy = false; self.showToast("Đã lưu video")
                    if self.options.autoSavePhotos { CaptureStore.shared.saveToPhotos(item) { text in if !text.hasPrefix("Đã") { self.notify(text) } } }
                }
            } catch { self.notify(error.localizedDescription); DispatchQueue.main.async { self.recordingBusy = false } }
        }
    }
}
extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) { DispatchQueue.main.async { self.didStartRecording() } }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.recording = false; self.recordingBusy = true; self.recordingTimer?.invalidate(); UIApplication.shared.isIdleTimerDisabled = false }
        if let error = error as NSError?, !(error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false) {
            notify(error.localizedDescription); DispatchQueue.main.async { self.recordingBusy = false }; return
        }
        if activeMovieMode == .slowMotion {
            let fps = activeMovieFPS
            Task {
                do {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProCaptureError.failed("Không đọc được video.") }
                    let composition = AVMutableComposition()
                    guard let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ProCaptureError.failed("Không tạo được slow motion.") }
                    try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                    destination.preferredTransform = try await track.load(.preferredTransform)
                    destination.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: CMTimeMultiplyByFloat64(duration, multiplier: Double(fps) / 30))
                    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw ProCaptureError.failed("Không xuất được slow motion.") }
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                    export.outputURL = target; export.outputFileType = .mov
                    await export.export()
                    guard export.status == .completed else { throw export.error ?? ProCaptureError.failed("Xuất slow motion thất bại.") }
                    try? FileManager.default.removeItem(at: url)
                    self.storeMovie(target, metadata: "SLOW · \(fps) → 30 fps")
                } catch {
                    self.notify("Chưa làm chậm được video; giữ bản gốc \(fps) fps. " + error.localizedDescription)
                    self.storeMovie(url, metadata: "HIGH FPS · \(fps) fps")
                }
            }
        } else { storeMovie(url, metadata: currentVideo?.title ?? "VIDEO") }
    }
}
enum ProCaptureError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
}

// Video-queue owned: flatten each composite so the Core Image graph stays bounded.
final class LongExposureAccumulator {
    let start = ProcessInfo.processInfo.systemUptime
    let duration: Double
    let blend: LongBlend
    var count = 0
    var result: CIImage?
    private var last = 0.0
    init(duration: Double, blend: LongBlend) { self.duration = max(1, min(30, duration)); self.blend = blend }
    func append(_ input: CIImage, now: Double, context: CIContext) -> Bool {
        if now - last < 1.0 / 12 { return false }; last = now
        let factor = min(1, 1920 / max(input.extent.width, input.extent.height))
        let frame = input.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        var next = frame
        if let previous = result {
            if blend == .lighten { next = frame.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: previous]) }
            else {
                let weight = 1.0 / Double(count + 1)
                let mask = CIImage(color: CIColor(red: weight, green: weight, blue: weight)).cropped(to: frame.extent)
                next = frame.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: previous, kCIInputMaskImageKey: mask])
            }
        }
        if let cg = context.createCGImage(next, from: frame.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) { result = CIImage(cgImage: cg); count += 1 }
        return now - start >= duration
    }
}
final class FrameMovieWriter {
    let url: URL
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let context = CIContext(options: [.cacheIntermediates: false])
    let interval: Double
    var last = -Double.infinity
    var count: Int64 = 0
    init(url: URL, interval: Double) throws {
        self.url = url; self.interval = max(0.25, interval)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1080, AVVideoHeightKey: 1920, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1080, kCVPixelBufferHeightKey as String: 1920, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw ProCaptureError.failed("Không tạo được bộ ghi time-lapse.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ProCaptureError.failed("Không bắt đầu được time-lapse.") }
        writer.startSession(atSourceTime: .zero)
    }
    func append(_ image: CIImage, now: Double) {
        guard now - last >= interval, input.isReadyForMoreMediaData, writer.status == .writing, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return }
        let factor = max(1080 / image.extent.width, 1920 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let centered = scaled.transformed(by: CGAffineTransform(translationX: (1080 - scaled.extent.width) / 2, y: (1920 - scaled.extent.height) / 2))
        context.render(centered, to: buffer, bounds: CGRect(x: 0, y: 0, width: 1080, height: 1920), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if adaptor.append(buffer, withPresentationTime: CMTime(value: count, timescale: 30)) { last = now; count += 1 }
    }
    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        guard writer.status == .writing else { completion(.failure(writer.error ?? ProCaptureError.failed("Bộ ghi time-lapse đã dừng."))); return }
        guard count > 0 else { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); completion(.failure(ProCaptureError.failed("Chưa có khung hình time-lapse."))); return }
        writer.endSession(atSourceTime: CMTime(value: count, timescale: 30)); input.markAsFinished()
        writer.finishWriting { completion(self.writer.status == .completed ? .success(self.url) : .failure(self.writer.error ?? ProCaptureError.failed("Lỗi ghi time-lapse."))) }
    }
}
