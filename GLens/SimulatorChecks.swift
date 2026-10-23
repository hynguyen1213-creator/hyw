#if targetEnvironment(simulator)
import Foundation
import UIKit
import CoreImage
import ImageIO
import AVFoundation

enum SimulatorChecks {
    static func run() async {
        var checks: [String: Bool] = [:]
        var notes: [String] = []
        let engine = ColorEngine()
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 128)
        let source = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7)).cropped(to: bounds).settingProperties([kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifExposureTime as String: 0.008, kCGImagePropertyExifISOSpeedRatings as String: [200]]])
        var color = ColorSettings(); color.grain = 0; color.ratio = 1
        if let jpeg = engine.jpeg(source, settings: color, metadata: "TEST"), let cgSource = CGImageSourceCreateWithData(jpeg as CFData, nil), let image = CGImageSourceCreateImageAtIndex(cgSource, 0, nil) {
            checks["JPEG square crop 96x96"] = image.width == 96 && image.height == 96
            let props = CGImageSourceCopyPropertiesAtIndex(cgSource, 0, nil) as? [String: Any]
            let exif = props?[kCGImagePropertyExifDictionary as String] as? [String: Any]
            checks["EXIF ISO preserved"] = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue == 200
            checks["EXIF exposure preserved"] = abs(((exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0) - 0.008) < 0.0001
            do {
                let raw = Data([0x49, 0x49, 0x2A, 0, 9, 8, 7]) // Storage fixture; not a sensor DNG.
                let item = try CaptureStore.shared.store(jpeg: jpeg, raw: raw, original: jpeg, metadata: "QA fixture")
                checks["RAW sidecar byte integrity"] = try item.rawURL.map { try Data(contentsOf: $0) == raw } ?? false
                checks["Original photo preserved"] = try item.originalURL.map { try Data(contentsOf: $0) == jpeg } ?? false
                checks["Gallery discovers capture"] = CaptureStore.shared.all().contains { $0.id == item.id }
                try CaptureStore.shared.delete(item)
                checks["Delete removes capture sidecars"] = !FileManager.default.fileExists(atPath: item.url.path) && !(item.rawURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
            } catch { checks["Capture store"] = false; notes.append(error.localizedDescription) }
        } else { checks["JPEG encode"] = false }
        if (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("public.heic") {
            let data = engine.jpeg(source, settings: color, metadata: "HEIF", encoding: .heif)
            checks["HEIF encode and decode"] = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil
        } else { notes.append("HEIF encoder unavailable in this simulator") }
        color.frame = true
        if let data = engine.jpeg(source, settings: color, metadata: "FRAME"), let decoded = UIImage(data: data) { checks["Signature frame increases canvas"] = decoded.size.height > 96 && decoded.size.width > 96 }
        else { checks["Signature frame render"] = false }
        var options = ProOptions(); options.zebra = true
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let black = CIImage(color: .black).cropped(to: white.extent)
        let analyzer = FrameAnalyzer()
        let a = analyzer.analyze(white, options: options), b = analyzer.analyze(black, options: options)
        checks["White clipping detected"] = a.clipped > 0.99 && a.luma[63] > 0.99
        notes.append("White clipped=\(a.clipped), last luma bin=\(a.luma[63])")
        checks["Black not clipped"] = b.clipped == 0 && b.luma[0] > 0.99
        checks["Zebra overlay generated"] = a.overlay != nil
        let stack = LongExposureAccumulator(duration: 1, blend: .average)
        _ = stack.append(white, now: stack.start, context: engine.context)
        let done = stack.append(black, now: stack.start + 1.1, context: engine.context)
        checks["Long exposure flattens and finishes"] = done && stack.count == 2 && stack.result != nil
        if let data = try? JSONEncoder().encode(ProOptions()), let restored = try? JSONDecoder().decode(ProOptions.self, from: data) { checks["Options persistence round trip"] = restored == ProOptions() }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            let writer = try FrameMovieWriter(url: url, interval: 0.25)
            for index in 0..<8 {
                writer.append(source, now: Double(index))
                try? await Task.sleep(for: .milliseconds(100))
            }
            let result: Result<URL, Error> = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
            let file = try result.get()
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration)
            checks["Time-lapse MOV readable"] = CMTimeGetSeconds(duration) > 0
            let item = try CaptureStore.shared.storeMovie(url: file, metadata: "QA video")
            checks["Video gallery thumbnail"] = CaptureStore.shared.thumbnail(item.url) != nil
            try CaptureStore.shared.delete(item)
        } catch { checks["Time-lapse file pipeline"] = false; notes.append(error.localizedDescription) }
        let advanced = AdvancedChecks.run(context: engine.context)
        checks.merge(advanced.0) { _, next in next }; notes += advanced.1
        let target = CaptureStore.shared.directory.deletingLastPathComponent().appendingPathComponent("SimulatorChecks.json")
        let result: [String: Any] = ["passed": !checks.values.contains(false), "checks": checks, "notes": notes, "hardware_tested": false]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: target, options: .atomic) }
    }
}
#endif
