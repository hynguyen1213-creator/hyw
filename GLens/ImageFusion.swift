import Foundation
import CoreImage
import Vision
import UIKit

// All registration operates on a bounded working image. Reject bad matches instead
// of silently blending unrelated frames. Full-resolution sensor RAW is never changed.
enum ImageRegistration {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static func normalized(_ image: CIImage, longest: CGFloat) -> CIImage {
        let zero = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, longest / max(zero.extent.width, zero.extent.height))
        return zero.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: CGRect(x: 0, y: 0, width: floor(zero.extent.width * scale), height: floor(zero.extent.height * scale)))
    }
    static func flatten(_ image: CIImage, context: CIContext) -> CIImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space).map { CIImage(cgImage: $0) }
    }
    static func pixels(_ image: CIImage, bounds: CGRect, context: CIContext) -> [UInt8] {
        let w = Int(bounds.width), h = Int(bounds.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &bytes, rowBytes: w * 4, bounds: bounds, format: .RGBA8, colorSpace: space)
        return bytes
    }
    static func image(_ bytes: [UInt8], width: Int, height: Int) -> CIImage {
        CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: space)
    }
    static func translation(_ source: CIImage, to reference: CIImage, context: CIContext, maxFraction: CGFloat = 0.15) -> CGAffineTransform? {
        let scale = min(1, 640 / max(reference.extent.width, reference.extent.height))
        let a = reference.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let b = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: b, options: [:])
        do {
            try VNImageRequestHandler(ciImage: a, options: [:]).perform([request])
            guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
            let t = observation.alignmentTransform
            guard t.tx.isFinite, t.ty.isFinite else { return nil }
            // Validate against image content, including the transform direction.
            let candidate = [CGAffineTransform.identity, t, t.inverted()].map { value in (value, correlation(a, b.transformed(by: value), context: context)) }.min { $0.1 < $1.1 }
            guard let (best, error) = candidate, error < 0.28,
                  abs(best.tx) < a.extent.width * maxFraction,
                  abs(best.ty) < a.extent.height * maxFraction else { return nil }
            return CGAffineTransform(translationX: (best.tx / scale).rounded(), y: (best.ty / scale).rounded())
        } catch { return nil }
    }
    // One minus normalized correlation: invariant to a global exposure change.
    static func correlation(_ a: CIImage, _ b: CIImage, context: CIContext) -> Double {
        let overlap = a.extent.intersection(b.extent).insetBy(dx: 3, dy: 3).integral
        guard overlap.width > 24, overlap.height > 24 else { return 1 }
        let scale = min(1, 128 / max(overlap.width, overlap.height))
        let transform = CGAffineTransform(translationX: -overlap.minX, y: -overlap.minY).scaledBy(x: 1, y: 1)
        let aa = a.cropped(to: overlap).transformed(by: transform).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bb = b.cropped(to: overlap).transformed(by: transform).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: floor(overlap.width * scale), height: floor(overlap.height * scale))
        let pa = pixels(aa, bounds: bounds, context: context), pb = pixels(bb, bounds: bounds, context: context)
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        let count = pa.count / 4
        for i in stride(from: 0, to: pa.count, by: 4) {
            let x = ProMath.luminance(pa[i], pa[i+1], pa[i+2]), y = ProMath.luminance(pb[i], pb[i+1], pb[i+2])
            sa += x; sb += y; saa += x*x; sbb += y*y; sab += x*y
        }
        let n = Double(count), va = saa-sa*sa/n, vb = sbb-sb*sb/n
        guard va > 0.002 * n, vb > 0.002 * n else { return 1 } // Blank sky is not a reliable match.
        return 1 - (sab-sa*sb/n) / sqrt(va*vb)
    }
}
struct FusionResult {
    let image: CIImage
    let used: Int
    let rejected: Int
}
enum ImageFusion {
    enum Kind: Equatable { case hdr, night }
    static func fuse(_ frames: [CIImage], kind: Kind, context: CIContext) -> FusionResult? {
        guard !frames.isEmpty else { return nil }
        let middle = kind == .hdr ? frames.count / 2 : 0
        let reference = ImageRegistration.normalized(frames[middle], longest: 3072)
        let bounds = reference.extent
        var aligned = [reference], used = 1
        for (index, frame) in frames.enumerated() where index != middle {
            let candidate = ImageRegistration.normalized(frame, longest: 3072)
            guard candidate.extent.size == reference.extent.size,
                  let t = ImageRegistration.translation(candidate, to: reference, context: context) else { continue }
            aligned.append(candidate.transformed(by: t)); used += 1
        }
        let overlap = aligned.reduce(bounds) { $0.intersection($1.extent) }
        let crop = CGRect(x: ceil(overlap.minX), y: ceil(overlap.minY), width: floor(overlap.maxX) - ceil(overlap.minX), height: floor(overlap.maxY) - ceil(overlap.minY))
        guard crop.width > 16, crop.height > 16 else { return nil }
        let referenceBytes = ImageRegistration.pixels(reference, bounds: crop, context: context)
        let w = Int(crop.width), h = Int(crop.height), count = w*h
        // Streaming accumulation bounds memory independently of the number of photos.
        var sum = [Float](repeating: 0, count: count*3), weights = [Float](repeating: 0, count: count)
        for (index, frame) in aligned.enumerated() {
            let bytes = index == 0 ? referenceBytes : ImageRegistration.pixels(frame, bounds: crop, context: context)
            for p in 0..<count {
                let j = p*4
                let r = Float(bytes[j])/255, g = Float(bytes[j+1])/255, b = Float(bytes[j+2])/255
                let rr = Float(referenceBytes[j])/255, rg = Float(referenceBytes[j+1])/255, rb = Float(referenceBytes[j+2])/255
                let l = 0.2126*r + 0.7152*g + 0.0722*b
                var weight: Float = 1
                if kind == .night {
                    // Motion rejection preserves the reference subject instead of averaging ghosts.
                    if index > 0 && max(abs(r-rr), max(abs(g-rg), abs(b-rb))) > 0.12 { continue }
                } else {
                    let maximum = max(r, max(g,b)), minimum = min(r,min(g,b))
                    weight = max(0.002, exp(-pow(l-0.5,2)/0.08)) * max(0.02, 1 - max(0,maximum-0.93)*14) * max(0.02,min(1,minimum*20))
                    // Compare normalized chroma to suppress moving colored objects.
                    let total = max(0.05,r+g+b), rt = max(0.05,rr+rg+rb)
                    let difference = max(abs(r/total-rr/rt), max(abs(g/total-rg/rt),abs(b/total-rb/rt)))
                    if index > 0 && difference > 0.16 { continue }
                }
                sum[p*3] += r*weight; sum[p*3+1] += g*weight; sum[p*3+2] += b*weight; weights[p] += weight
            }
        }
        var bytes = referenceBytes
        for p in 0..<count where weights[p] > 0 {
            for channel in 0..<3 { bytes[p*4+channel] = UInt8(max(0,min(255,(sum[p*3+channel]/weights[p]*255).rounded()))) }
            bytes[p*4+3] = 255
        }
        let result = ImageRegistration.image(bytes, width: w, height: h).settingProperties(frames[middle].properties)
        return FusionResult(image: result, used: used, rejected: frames.count-used)
    }
}

// A short, guided horizontal panorama. Translation + feathering is appropriate
// for distant scenes; parallax, large rotations and unreliable matches are rejected.
final class PanoramaStitcher {
    struct Tile { let image: CIImage; let origin: CGPoint }
    var tiles: [Tile] = []
    var lastTime = -Double.infinity
    var direction: CGFloat = 0
    var hint = "Giữ máy dọc, lia chậm ngang sang một phía"
    let maxTiles = 18
    func append(_ source: CIImage, now: Double, context: CIContext) -> Bool {
        guard now - lastTime >= 0.22 else { return false }; lastTime = now
        let image = ImageRegistration.normalized(source, longest: 1280)
        guard let flat = ImageRegistration.flatten(image, context: context) else { return false }
        guard let previous = tiles.last else { tiles.append(Tile(image: flat, origin: .zero)); return false }
        guard let shift = ImageRegistration.translation(flat, to: previous.image, context: context, maxFraction: 0.48) else { hint = "Lia chậm lại · cần vùng ảnh chồng nhau có chi tiết"; return false }
        let dx = shift.tx, dy = shift.ty
        guard abs(dy) < flat.extent.height * 0.08 else { hint = "Giữ đường chân trời ngang"; return false }
        guard abs(dx) > flat.extent.width * 0.16 else { hint = direction < 0 ? "← Lia chậm sang trái" : "Lia chậm sang phải →"; return false }
        if direction != 0 && dx * direction < 0 { hint = "Giữ nguyên hướng lia máy"; return false }
        direction = dx > 0 ? 1 : -1
        let origin = CGPoint(x: previous.origin.x + dx, y: previous.origin.y + dy)
        let minX = min(0,origin.x), maxX = max(flat.extent.width, origin.x + flat.extent.width)
        guard maxX - minX < 8192 else { return true }
        tiles.append(Tile(image: flat, origin: origin))
        hint = "\(tiles.count) khung · bấm dừng để ghép"
        return tiles.count >= maxTiles
    }
    func finish(context: CIContext) -> CIImage? {
        guard tiles.count >= 2 else { return nil }
        let placed = tiles.map { $0.image.transformed(by: CGAffineTransform(translationX: $0.origin.x, y: $0.origin.y)) }
        let lowY = placed.map { $0.extent.minY }.max()!, highY = placed.map { $0.extent.maxY }.min()!
        let lowX = placed.map { $0.extent.minX }.min()!, highX = placed.map { $0.extent.maxX }.max()!
        let crop = CGRect(x: ceil(lowX), y: ceil(lowY), width: floor(highX)-ceil(lowX), height: floor(highY)-ceil(lowY))
        guard crop.width > 0, crop.height > 100 else { return nil }
        var result = placed[0]
        for next in placed.dropFirst() {
            let overlap = result.extent.intersection(next.extent)
            let rightward = next.extent.midX > result.extent.midX
            let mask = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: overlap.minX, y: 0), "inputPoint1": CIVector(x: overlap.maxX, y: 0), "inputColor0": rightward ? CIColor.black : CIColor.white, "inputColor1": rightward ? CIColor.white : CIColor.black])!.outputImage!
            let mixed = next.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask]).cropped(to: result.extent.union(next.extent))
            guard let flat = ImageRegistration.flatten(mixed, context: context) else { return nil }
            result = flat.transformed(by: CGAffineTransform(translationX: mixed.extent.minX, y: mixed.extent.minY))
        }
        return ImageRegistration.flatten(result.cropped(to: crop), context: context)
    }
}
