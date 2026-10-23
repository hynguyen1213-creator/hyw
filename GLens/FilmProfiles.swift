import Foundation
import CoreImage

// Artist-authored interpretations, not measured scans or licensed manufacturer LUTs.
struct FilmProfile {
    let red: [Float]
    let green: [Float]
    let blue: [Float]
    let saturation: Float
    let grain: Float
    let halation: Float
    let caption: String
    static let all: [String: FilmProfile] = [
        "gold200": .init(red:[0.025,0.25,0.55,0.80,0.99],green:[0.022,0.235,0.51,0.77,0.965],blue:[0.035,0.20,0.445,0.705,0.91],saturation:1.02,grain:0.24,halation:0.025,caption:"Vàng ấm · xanh olive · nắng chiều"),
        "portra400": .init(red:[0.035,0.265,0.54,0.78,0.98],green:[0.04,0.26,0.515,0.76,0.97],blue:[0.055,0.25,0.49,0.735,0.95],saturation:0.86,grain:0.18,halation:0.012,caption:"Da dịu · pastel · vùng sáng mềm"),
        "ektar100": .init(red:[0.012,0.205,0.53,0.825,0.99],green:[0.02,0.23,0.52,0.795,0.98],blue:[0.035,0.245,0.53,0.80,0.98],saturation:1.16,grain:0.10,halation:0.008,caption:"Màu đậm · hạt mịn · phong cảnh"),
        "c200": .init(red:[0.03,0.22,0.49,0.755,0.97],green:[0.04,0.255,0.535,0.79,0.98],blue:[0.055,0.255,0.52,0.755,0.94],saturation:0.96,grain:0.25,halation:0.018,caption:"Xanh dịu · đời thường · hơi lạnh"),
        "hp5": .init(red:[0.025,0.20,0.49,0.78,0.975],green:[0.025,0.20,0.49,0.78,0.975],blue:[0.025,0.20,0.49,0.78,0.975],saturation:0,grain:0.38,halation:0,caption:"Đen trắng · hạt rõ · phố xá"),
        "cine800": .init(red:[0.025,0.19,0.46,0.78,0.995],green:[0.04,0.235,0.50,0.765,0.955],blue:[0.075,0.29,0.555,0.80,0.96],saturation:0.91,grain:0.32,halation:0.09,caption:"Bóng xanh · đèn tungsten · quầng đỏ")
    ]
    static func curve(_ x: Float, _ points: [Float]) -> Float {
        let t = max(0,min(1,x))*4, index = min(3,Int(t)), f = t-Float(index)
        let a = points[index], b = points[index+1]
        let m0 = index == 0 ? b-a : (b-points[index-1])*0.5
        let m1 = index == 3 ? b-a : (points[index+2]-a)*0.5
        return max(a,min(b,(2*f*f*f-3*f*f+1)*a + (f*f*f-2*f*f+f)*m0 + (-2*f*f*f+3*f*f)*b + (f*f*f-f*f)*m1))
    }
    func cube(dimension: Int = 32) -> Data {
        var values = [Float](); values.reserveCapacity(dimension*dimension*dimension*4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let rgb = [Float(r),Float(g),Float(b)].map { $0/Float(dimension-1) }
            let luma = rgb[0]*0.2126 + rgb[1]*0.7152 + rgb[2]*0.0722
            let rr = luma+(rgb[0]-luma)*saturation, gg = luma+(rgb[1]-luma)*saturation, bb = luma+(rgb[2]-luma)*saturation
            values += [Self.curve(rr,red),Self.curve(gg,green),Self.curve(bb,blue),1]
        } } }
        return values.withUnsafeBufferPointer { Data(buffer:$0) }
    }
}
