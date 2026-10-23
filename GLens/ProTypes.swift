import Foundation
import AVFoundation

// Features are offered from device discovery, never from a model-name whitelist.
enum ShootingMode: String, CaseIterable, Codable, Identifiable {
    case photo = "PHOTO", pro = "PRO", portrait = "PORTRAIT", hdr = "HDR", night = "NIGHT", panorama = "PANO", document = "DOC", video = "VIDEO", slowMotion = "SLOW", timeLapse = "TIME-LAPSE", longExposure = "LONG"
    var id: String { rawValue }
    var computational: Bool { self == .hdr || self == .night || self == .panorama || self == .document || self == .longExposure }
    var isMovie: Bool { self == .video || self == .slowMotion || self == .timeLapse }
}
enum TrackingMode: String, CaseIterable, Codable { case off = "Tắt", eye = "Mắt / khuôn mặt", subject = "Chủ thể · chạm để chọn" }
enum PhotoEncoding: String, CaseIterable, Codable { case jpeg = "JPEG", heif = "HEIF" }
enum VideoTone: String, CaseIterable, Codable { case standard = "SDR", hlg = "HDR HLG", log = "Apple Log" }
enum SequenceKind: String, CaseIterable, Codable { case single = "Một ảnh", burst = "Chụp liên tiếp", interval = "Chụp cách quãng", bracket = "BKT ±EV" }
enum GridStyle: String, CaseIterable, Codable { case off = "Tắt", thirds = "1/3", golden = "Tỷ lệ vàng", square = "Ô vuông" }
enum LongBlend: String, CaseIterable, Codable { case average = "Nước mịn", lighten = "Vệt sáng" }
struct VideoChoice: Identifiable, Equatable {
    let width: Int32
    let height: Int32
    let fps: Int32
    let tone: VideoTone
    var id: String { "\(width)x\(height)-\(fps)-\(tone.rawValue)" }
    var title: String { "\(width >= 3840 ? "4K" : "1080p") · \(fps) fps · \(tone.rawValue)" }
}
struct ProOptions: Codable, Equatable {
    var encoding = PhotoEncoding.jpeg
    var maximumResolution = false
    var flash = 0 // 0 off, 1 auto, 2 on
    var grid = GridStyle.thirds
    var histogram = true
    var zebra = false
    var zebraThreshold = 0.95
    var peaking = false
    var peakingThreshold = 0.16
    var level = true
    var safeFrame = false
    var sequence = SequenceKind.single
    var sequenceCount = 5
    var intervalSeconds = 2.0
    var bracketEV: Float = 1
    var longSeconds = 4.0
    var longBlend = LongBlend.average
    var lapseInterval = 1.0
    var portraitBlur = 0.6
    var stabilization = true
    var microphone = true
    var saveOriginal = true
    var autoSavePhotos = false
    var timerSeconds = 0
    var tracking = TrackingMode.off
    var nightFrames = 6
    var documentMono = false
    static func restored() -> ProOptions {
        guard let data = UserDefaults.standard.data(forKey: "glens.pro.options") else { return Self() }
        return migrated(data) ?? Self()
    }
    static func migrated(_ data: Data) -> ProOptions? {
        guard let defaults = try? JSONEncoder().encode(Self()),
              var fields = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any],
              let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        fields.merge(stored) { _, old in old }
        guard let merged = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: merged)
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "glens.pro.options") } }
}
struct CameraPreset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var color: ColorSettings
    var manualExposure: Bool
    var iso: Float
    var shutter: Double
    var manualFocus: Bool
    var focus: Float
    var manualWB: Bool
    var kelvin: Float
    var tint: Float
    var ev: Float
    static func load() -> [CameraPreset] {
        guard let data = UserDefaults.standard.data(forKey: "glens.pro.presets") else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
    static func save(_ presets: [CameraPreset]) {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: "glens.pro.presets") }
    }
}
