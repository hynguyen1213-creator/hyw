import Foundation

enum ProMath {
    static func crop(width: Double, height: Double, ratio: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let w = max(1, width), h = max(1, height), r = max(0.01, ratio)
        let cw = min(w, h * r), ch = min(h, w / r)
        return ((w - cw) / 2, (h - ch) / 2, cw, ch)
    }
    static func sensorPoint(x: Double, y: Double, width: Double, height: Double, ratio: Double, mirrored: Bool) -> (x: Double, y: Double) {
        let c = crop(width: width, height: height, ratio: ratio)
        let px = (c.x + max(0, min(1, x)) * c.width) / max(1, width)
        let py = (c.y + max(0, min(1, y)) * c.height) / max(1, height)
        return (py, mirrored ? px : 1 - px)
    }
    static func shutterLabel(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "—" }
        return seconds < 0.5 ? "1/\(Int((1 / seconds).rounded()))" : String(format: "%.1fs", seconds)
    }
    static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
        (Double(red) * 0.2126 + Double(green) * 0.7152 + Double(blue) * 0.0722) / 255
    }
    static func bracketBiases(center: Float, step: Float, minimum: Float, maximum: Float) -> [Float] {
        [-abs(step), 0, abs(step)].map { max(minimum, min(maximum, center + $0)) }
    }
    static func durationLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
