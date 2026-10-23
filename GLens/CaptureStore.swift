import Foundation
import Photos
import UIKit
import ImageIO
import AVFoundation

struct SavedCapture: Identifiable {
    let id: String
    let url: URL
    let rawURL: URL?
    let date: Date
    var rawWarning: String? = nil
    var metadata: String = ""
    var isVideo: Bool { ["mov", "mp4"].contains(url.pathExtension.lowercased()) }
    var originalURL: URL? {
        let candidate = url.deletingPathExtension().appendingPathExtension("original.jpg")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
    var image: UIImage? { isVideo ? nil : UIImage(contentsOfFile: url.path) }
}
final class CaptureStore {
    static let shared = CaptureStore()
    let directory: URL
    private init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func store(jpeg: Data, raw: Data?, encoding: PhotoEncoding = .jpeg, original: Data? = nil, metadata: String = "") throws -> SavedCapture {
        let name = "G_LENS_" + String(Int(Date().timeIntervalSince1970)) + "_" + UUID().uuidString
        let url = directory.appendingPathComponent(name).appendingPathExtension(encoding == .heif ? "heic" : "jpg")
        try jpeg.write(to: url, options: .atomic)
        var rawURL: URL?, warning: String?
        if let raw {
            let target = directory.appendingPathComponent(name).appendingPathExtension("dng")
            do { try raw.write(to: target, options: .atomic); rawURL = target } catch { warning = "Ảnh màu đã lưu; lỗi DNG: " + error.localizedDescription }
        }
        if let original {
            do { try original.write(to: url.deletingPathExtension().appendingPathExtension("original.jpg"), options: .atomic) }
            catch { warning = "Ảnh màu đã lưu; lỗi lưu ảnh gốc: " + error.localizedDescription }
        }
        try? metadata.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        return SavedCapture(id: name, url: url, rawURL: rawURL, date: Date(), rawWarning: warning, metadata: metadata)
    }
    func storeMovie(url source: URL, metadata: String) throws -> SavedCapture {
        let name = "G_LENS_" + String(Int(Date().timeIntervalSince1970)) + "_" + UUID().uuidString
        let url = directory.appendingPathComponent(name).appendingPathExtension("mov")
        try FileManager.default.moveItem(at: source, to: url)
        try? metadata.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        return SavedCapture(id: name, url: url, rawURL: nil, date: Date(), metadata: metadata)
    }
    func thumbnail(_ url: URL) -> UIImage? {
        if ["mov", "mp4"].contains(url.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 360, height: 360)
            guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return UIImage(cgImage: cg)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    func all() -> [SavedCapture] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { ["jpg", "heic", "mov", "mp4"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.contains(".original.") }.map { url in
            let raw = url.deletingPathExtension().appendingPathExtension("dng")
            let metadata = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
            return SavedCapture(id: url.deletingPathExtension().lastPathComponent, url: url, rawURL: FileManager.default.fileExists(atPath: raw.path) ? raw : nil, date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, metadata: metadata)
        }.sorted { $0.date > $1.date }
    }
    func delete(_ capture: SavedCapture) throws {
        guard capture.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try FileManager.default.removeItem(at: capture.url)
        for url in [capture.rawURL, capture.originalURL, capture.url.deletingPathExtension().appendingPathExtension("txt")].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }
    func saveToPhotos(_ capture: SavedCapture, completion: @escaping (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { completion("Chưa có quyền lưu vào Ảnh. File vẫn trong G.LENS."); return }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: capture.isVideo ? .video : .photo, fileURL: capture.url, options: nil)
                if let raw = capture.rawURL { PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: raw, options: nil) }
            } completionHandler: { success, error in
                completion(success ? "Đã lưu vào Ảnh." : "Lưu Ảnh thất bại: \(error?.localizedDescription ?? "Thử lại sau"). File vẫn trong app.")
            }
        }
    }
}
