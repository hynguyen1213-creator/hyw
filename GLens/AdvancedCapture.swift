import Foundation
import AVFoundation
import CoreImage
import Vision
import UIKit

enum CapturePurpose: Equatable { case normal, hdr, night(UUID), document }
struct StackDeviceState {
    let exposure: AVCaptureDevice.ExposureMode
    let focus: AVCaptureDevice.FocusMode
    let whiteBalance: AVCaptureDevice.WhiteBalanceMode
}
extension CameraController {
    func lockStackDevice() {
        sessionQueue.async {
            guard let device = self.input?.device, self.stackDeviceState == nil else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                self.stackDeviceState = StackDeviceState(exposure: device.exposureMode, focus: device.focusMode, whiteBalance: device.whiteBalanceMode)
                if device.exposureMode != .custom && device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            } catch { self.notify(error.localizedDescription) }
        }
    }
    func restoreStackDevice() {
        sessionQueue.async {
            guard let old = self.stackDeviceState, let device = self.input?.device else { return }
            self.stackDeviceState = nil
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                if device.isExposureModeSupported(old.exposure) { device.exposureMode = old.exposure }
                if device.isFocusModeSupported(old.focus) { device.focusMode = old.focus }
                if device.isWhiteBalanceModeSupported(old.whiteBalance) { device.whiteBalanceMode = old.whiteBalance }
            } catch { self.notify(error.localizedDescription) }
        }
    }
    func startNight() {
        guard running, !capturing, !changingLens, !sequenceActive else { return }
        let id = UUID(), count = max(3,min(12,options.nightFrames))
        advancedID = id; nightFrames = []; sequenceActive = true
        let configuration = options, settings = currentColor()
        lockStackDevice()
        sequenceTask = Task { @MainActor in
            for index in 0..<count {
                guard !Task.isCancelled, self.advancedID == id, self.running else { return }
                self.sequenceProgress = "NIGHT \(index+1)/\(count) · giữ yên máy"
                self.capture(purpose: .night(id))
                while self.capturing && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(80)) }
            }
            guard !Task.isCancelled, self.advancedID == id else { return }
            self.restoreStackDevice()
            let frames = self.nightFrames; self.nightFrames = []
            self.sequenceProgress = "Căn chỉnh và giảm nhiễu…"; self.capturing = true
            self.photoQueue.async {
                let images = frames.compactMap { CIImage(data: $0, options: [.applyOrientationProperty:true]) }
                let result = ImageFusion.fuse(images, kind: .night, context: self.engine.context)
                DispatchQueue.main.async {
                    guard self.advancedID == id else { self.capturing = false; return }
                    self.advancedID = nil; self.sequenceActive = false
                    guard let result else { self.capturing = false; self.sequenceProgress = ""; self.notify("Không nhận đủ ảnh Night. Hãy thử lại."); return }
                    self.photoQueue.async {
                        self.finishImage(result.image, settings: settings, raw: nil, metadata: "NIGHT · \(result.used)/\(count) ảnh · căn chỉnh tịnh tiến", warning: result.used < 2 ? "Không căn chỉnh được các khung; đã giữ một ảnh gốc. Hãy giữ máy yên và chọn cảnh có chi tiết." : nil, options: configuration, original: frames.first)
                    }
                }
            }
        }
    }
    func acceptNight(_ data: Data?, id: UUID) {
        guard advancedID == id else { capturing = false; return }
        if let data { nightFrames.append(data) }
        capturing = false
    }
    func startPanorama() {
        guard running, !capturing, !sequenceActive, !changingLens else { return }
        advancedID = UUID(); sequenceActive = true; sequenceProgress = "Lia chậm ngang · bấm dừng để ghép"
        lockStackDevice()
        videoQueue.async { self.panorama = PanoramaStitcher() }
    }
    func finishPanorama() {
        guard mode == .panorama, sequenceActive, let id = advancedID, !capturing else { return }
        capturing = true; sequenceProgress = "Đang ghép panorama…"
        let configuration = options, settings = currentColor()
        restoreStackDevice()
        videoQueue.async {
            guard let panorama = self.panorama else { DispatchQueue.main.async { self.capturing = false; self.cancelSequence() }; return }
            self.panorama = nil
            let count = panorama.tiles.count
            self.photoQueue.async {
                let image = panorama.finish(context: self.engine.context)
                DispatchQueue.main.async {
                    guard self.advancedID == id else { self.capturing = false; return }
                    self.advancedID = nil; self.sequenceActive = false
                    guard let image else { self.capturing = false; self.sequenceProgress = ""; self.notify("Cần ít nhất 2 khung chồng nhau. Lia ngang chậm, giữ đường chân trời và tránh cảnh thiếu chi tiết."); return }
                    var wide = settings; wide.ratio = image.extent.width/image.extent.height
                    self.photoQueue.async { self.finishImage(image, settings: wide, raw: nil, metadata: "PANO · \(count) khung · \(Int(image.extent.width))×\(Int(image.extent.height))", options: configuration) }
                }
            }
        }
    }
    func cancelAdvanced() {
        if advancedID != nil { advancedID = nil; nightFrames = [] }
        videoQueue.async { self.panorama = nil }
        restoreStackDevice()
    }
    func documentImage(_ source: CIImage, monochrome: Bool) -> (CIImage, Bool) {
        let image = ImageRegistration.normalized(source, longest: 4096)
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1; request.minimumConfidence = 0.7
        request.minimumAspectRatio = 0.25; request.minimumSize = 0.25
        do {
            try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
            guard let rectangle = request.results?.first else { return (source,false) }
            func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x*image.extent.width,y: p.y*image.extent.height) }
            var corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: ["inputTopLeft": point(rectangle.topLeft),"inputTopRight": point(rectangle.topRight),"inputBottomLeft": point(rectangle.bottomLeft),"inputBottomRight": point(rectangle.bottomRight)])
            if monochrome { corrected = corrected.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey:0,kCIInputContrastKey:1.18]) }
            return (corrected.settingProperties(source.properties),true)
        } catch { return (source,false) }
    }
}
