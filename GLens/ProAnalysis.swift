import Foundation
import CoreImage
import UIKit
import CoreMotion
import Combine

struct ExposureAnalysis {
    var red = [Double](repeating: 0, count: 64)
    var green = [Double](repeating: 0, count: 64)
    var blue = [Double](repeating: 0, count: 64)
    var luma = [Double](repeating: 0, count: 64)
    var clipped = 0.0
    var overlay: UIImage?
}
final class FrameAnalyzer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func analyze(_ image: CIImage, options: ProOptions) -> ExposureAnalysis {
        let scale = min(1, 256 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(small.extent.width)), height = max(1, Int(small.extent.height)), count = width * height
        var pixels = [UInt8](repeating: 0, count: count * 4)
        context.render(small, toBitmap: &pixels, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var result = ExposureAnalysis(), luma = [Double](repeating: 0, count: count)
        var overlay = [UInt8](repeating: 0, count: count * 4)
        for index in 0..<count {
            let p = index * 4
            let value = ProMath.luminance(pixels[p], pixels[p + 1], pixels[p + 2]); luma[index] = value
            result.red[Int(pixels[p]) / 4] += 1
            result.green[Int(pixels[p + 1]) / 4] += 1
            result.blue[Int(pixels[p + 2]) / 4] += 1
            result.luma[min(63, Int(value * 63))] += 1
            if max(pixels[p], max(pixels[p + 1], pixels[p + 2])) >= 250 { result.clipped += 1 }
            if options.zebra && value >= options.zebraThreshold && ((index % width + index / width) / 4).isMultiple(of: 2) {
                overlay[p] = 255; overlay[p + 1] = 210; overlay[p + 2] = 0; overlay[p + 3] = 185
            }
        }
        if options.peaking && width > 2 && height > 2 {
            for y in 1..<(height - 1) { for x in 1..<(width - 1) {
                let index = y * width + x
                let gx = luma[index + 1] - luma[index - 1], gy = luma[index + width] - luma[index - width]
                if abs(gx) + abs(gy) > options.peakingThreshold {
                    let p = index * 4
                    overlay[p] = 255; overlay[p + 1] = 45; overlay[p + 2] = 35; overlay[p + 3] = 220
                }
            } }
        }
        result.clipped /= Double(count)
        let maximum = max(1, result.luma.max() ?? 1)
        result.luma = result.luma.map { $0 / maximum }
        let rgbMaximum = max(1, max(result.red.max() ?? 1, result.green.max() ?? 1, result.blue.max() ?? 1))
        result.red = result.red.map { $0 / rgbMaximum }; result.green = result.green.map { $0 / rgbMaximum }; result.blue = result.blue.map { $0 / rgbMaximum }
        if options.zebra || options.peaking {
            let data = Data(overlay)
            if let provider = CGDataProvider(data: data as CFData), let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                result.overlay = UIImage(cgImage: cg)
            }
        }
        return result
    }
}
final class HorizonMeter: ObservableObject {
    @Published var degrees = 0.0
    private let motion = CMMotionManager()
    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 12
        motion.startDeviceMotionUpdates(to: .main) { [weak self] value, _ in
            guard let g = value?.gravity else { return }
            var angle = atan2(g.x, -g.y) * 180 / .pi
            while angle > 45 { angle -= 90 }; while angle < -45 { angle += 90 }
            self?.degrees = angle
        }
    }
    func stop() { motion.stopDeviceMotionUpdates() }
    deinit { motion.stopDeviceMotionUpdates() }
}
