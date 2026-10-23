import Foundation
import Photos
import UIKit
import ImageIO

struct SavedCapture: Identifiable {
    let id: UUID
    let url: URL
    let rawURL: URL?
    let date: Date
    var rawWarning: String? = nil
    var image: UIImage? { UIImage(contentsOfFile: url.path) }
}
final class CaptureStore {
    static let shared = CaptureStore()
    let directory: URL
    private init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func store(jpeg: Data, raw: Data?) throws -> SavedCapture {
        let id = UUID(), name = "G_LENS_" + String(Int(Date().timeIntervalSince1970)) + "_" + id.uuidString
        let url = directory.appendingPathComponent(name).appendingPathExtension("jpg")
        try jpeg.write(to: url, options: .atomic)
        var rawURL: URL?
        var rawWarning: String?
        if let raw {
            let target = directory.appendingPathComponent(name).appendingPathExtension("dng")
            do { try raw.write(to: target, options: .atomic); rawURL = target } catch { rawWarning = "JPEG đã lưu; không lưu được DNG: \(error.localizedDescription)" }
        }
        return SavedCapture(id: id, url: url, rawURL: rawURL, date: Date(), rawWarning: rawWarning)
    }
    func thumbnail(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 300, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    func all() -> [SavedCapture] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "jpg" }.map { url in
            let raw = url.deletingPathExtension().appendingPathExtension("dng")
            return SavedCapture(id: UUID(), url: url, rawURL: FileManager.default.fileExists(atPath: raw.path) ? raw : nil, date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }
    func saveToPhotos(_ capture: SavedCapture, completion: @escaping (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion("Chưa có quyền lưu vào Ảnh. Ảnh vẫn trong app; dùng Chia sẻ để xuất."); return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: capture.url, options: nil)
                if let raw = capture.rawURL {
                    let rawRequest = PHAssetCreationRequest.forAsset()
                    rawRequest.addResource(with: .photo, fileURL: raw, options: nil)
                }
            } completionHandler: { success, error in
                completion(success ? (capture.rawURL == nil ? "Đã lưu JPEG vào Ảnh." : "Đã lưu JPEG màu và DNG gốc thành hai ảnh riêng.") : "Lưu Ảnh thất bại: \(error?.localizedDescription ?? "Thử lại sau"). File vẫn trong app.")
            }
        }
    }
}
