import Foundation
@main struct ProMathTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ text: String) { precondition(value, text); count += 1 }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00001 }
        let c = ProMath.crop(width: 3000, height: 4000, ratio: 1)
        check(c.width == 3000 && c.height == 3000 && c.y == 500, "Square crop must be centered")
        let wide = ProMath.crop(width: 3000, height: 4000, ratio: 9.0 / 16)
        check(wide.width == 2250 && wide.x == 375 && wide.height == 4000, "16:9 crop must preserve full height")
        let center = ProMath.sensorPoint(x: 0.5, y: 0.5, width: 1080, height: 1920, ratio: 0.75, mirrored: false)
        check(near(center.x, 0.5) && near(center.y, 0.5), "Center focus must remain centered")
        let left = ProMath.sensorPoint(x: 0, y: 0.5, width: 1080, height: 1920, ratio: 0.75, mirrored: false)
        let mirrored = ProMath.sensorPoint(x: 0, y: 0.5, width: 1080, height: 1920, ratio: 0.75, mirrored: true)
        check(near(left.y, 1) && near(mirrored.y, 0), "Front camera must reverse sensor horizontal mapping")
        check(near(ProMath.luminance(255, 255, 255), 1), "White luminance")
        check(ProMath.luminance(0, 0, 0) == 0, "Black luminance")
        check(ProMath.luminance(0, 255, 0) > ProMath.luminance(255, 0, 0), "Luminance weighting")
        check(ProMath.bracketBiases(center: 1.5, step: 2, minimum: -2, maximum: 2) == [-0.5, 1.5, 2], "Bracket must respect device EV limits")
        check(ProMath.shutterLabel(1.0 / 125) == "1/125", "Exposure display")
        check(ProMath.shutterLabel(.nan) == "—" && ProMath.shutterLabel(0) == "—", "Invalid exposure must not crash integer conversion")
        check(ProMath.durationLabel(65) == "01:05", "Recording time")
        check(ProMath.durationLabel(-1) == "00:00", "Negative time")
        print("PASS: \(count) camera math checks")
    }
}
