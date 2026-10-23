import Foundation
import Vision
import CoreImage
import UIKit

struct TrackingTarget {
    let box: CGRect // normalized, bottom-left origin in the displayed crop
    let point: CGPoint // normalized, top-left origin
    let label: String
}
final class SubjectTracker {
    private var sequence = VNSequenceRequestHandler()
    private var observation: VNDetectedObjectObservation?
    private var lastFace: CGRect?
    private var lastTime = -Double.infinity
    private var lastMode = TrackingMode.off
    func reset() { sequence = VNSequenceRequestHandler(); observation = nil; lastFace = nil; lastTime = -Double.infinity }
    func seed(_ point: CGPoint) {
        reset()
        let box = CGRect(x: max(0,min(0.82,point.x-0.09)), y: max(0,min(0.82,1-point.y-0.09)), width: 0.18, height: 0.18)
        observation = VNDetectedObjectObservation(boundingBox: box)
        lastMode = .subject
    }
    func update(_ image: CIImage, mode: TrackingMode, now: Double) -> (updated: Bool, target: TrackingTarget?) {
        if lastMode != mode { reset(); lastMode = mode }
        guard mode != .off else { return (true,nil) }
        guard now-lastTime > 0.24 else { return (false,nil) }; lastTime = now
        let small = ImageRegistration.normalized(image, longest: 640)
        do {
            if mode == .subject {
                guard let observation else { return (true,nil) }
                let request = VNTrackObjectRequest(detectedObjectObservation: observation); request.trackingLevel = .accurate
                try sequence.perform([request], on: small, orientation: .up)
                guard let next = request.results?.first as? VNDetectedObjectObservation, next.confidence > 0.45 else { self.observation = nil; return (true,nil) }
                self.observation = next
                let box = next.boundingBox.intersection(CGRect(x: 0,y: 0,width: 1,height: 1))
                guard !box.isNull, box.width > 0.02, box.height > 0.02 else { self.observation = nil; return (true,nil) }
                return (true,TrackingTarget(box: box, point: CGPoint(x: box.midX,y: 1-box.midY), label: "TRACK AF"))
            }
            let request = VNDetectFaceLandmarksRequest()
            try VNImageRequestHandler(ciImage: small, options: [:]).perform([request])
            let faces = (request.results ?? []).filter { $0.confidence > 0.5 }
            let face: VNFaceObservation?
            if let prior = lastFace {
                face = faces.min { hypot($0.boundingBox.midX-prior.midX,$0.boundingBox.midY-prior.midY) < hypot($1.boundingBox.midX-prior.midX,$1.boundingBox.midY-prior.midY) }
            } else { face = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height } }
            guard let face else { lastFace = nil; return (true,nil) }
            let box = face.boundingBox; lastFace = box
            if let eye = face.landmarks?.leftEye ?? face.landmarks?.rightEye, eye.pointCount > 0 {
                let points = eye.normalizedPoints
                let center = points.reduce(CGPoint.zero) { CGPoint(x: $0.x+$1.x, y: $0.y+$1.y) }
                let point = CGPoint(x: box.minX + center.x/CGFloat(points.count)*box.width, y: 1-(box.minY + center.y/CGFloat(points.count)*box.height))
                return (true,TrackingTarget(box: box, point: point, label: "EYE AF"))
            }
            return (true,TrackingTarget(box: box, point: CGPoint(x: box.midX,y: 1-box.midY), label: "FACE AF"))
        } catch { observation = nil; lastFace = nil; return (true,nil) }
    }
}

extension CameraController {
    func track(at point: CGPoint) {
        if options.tracking == .subject { videoQueue.async { self.subjectTracker.seed(point) } }
        focus(at: point)
    }
    func applyTracking(_ target: TrackingTarget?) {
        guard options.tracking != .off, !imported, !manualFocus, !afLocked, !capturing, !sequenceActive else { trackingTarget = nil; return }
        trackingTarget = target
        guard let target else { lastTrackingPoint = nil; return }
        if let previous = lastTrackingPoint, hypot(previous.x-target.point.x, previous.y-target.point.y) < 0.025 { return }
        lastTrackingPoint = target.point
        withDevice { device in
            guard device.focusMode != .locked else { return }
            let (size,ratio) = self.locked { (self.sensorSize, self.color.ratio) }
            let p = ProMath.sensorPoint(x: target.point.x,y: target.point.y,width: size.width,height: size.height,ratio: ratio,mirrored: device.position == .front)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: p.x,y: p.y) }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
    }
}
