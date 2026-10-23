import SwiftUI
import ImageIO
import UIKit

struct GalleryScreen: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SavedCapture?
    var body: some View {
        NavigationStack {
            ScrollView {
                if camera.captures.isEmpty { ContentUnavailableView("Chưa có ảnh", systemImage: "photo.on.rectangle", description: Text("Chụp một khoảnh khắc hoặc nhập ảnh để bắt đầu.")) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                    ForEach(camera.captures) { item in
                        Button { selected = item } label: {
                            if let image = thumbnail(item.url) {
                                Image(uiImage: image).resizable().aspectRatio(1, contentMode: .fill).clipped()
                                    .overlay(alignment: .bottomTrailing) {
                                        if item.rawURL != nil { Text("RAW").font(.system(size: 8)).padding(5).background(.black.opacity(0.6)) }
                                    }
                            }
                        }
                    }
                }.padding(12)
            }.navigationTitle("Khoảnh khắc").toolbar { Button("Xong") { dismiss() } }
                .sheet(item: $selected) { item in CaptureDetail(item: item) }
        }.tint(Color(red: 0.81, green: 0.25, blue: 0.18))
    }
    private func thumbnail(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
private struct CaptureDetail: View {
    let item: SavedCapture
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var saving = false
    @State private var share = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                if let image = item.image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fit) }
                Spacer()
                Text(item.rawURL == nil ? "JPEG · màu G.LENS" : "JPEG màu + DNG nguyên bản").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { share = true } label: { Label("Chia sẻ", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    Button {
                        saving = true
                        CaptureStore.shared.saveToPhotos(item) { text in DispatchQueue.main.async { saving = false; message = text } }
                    } label: { Label(saving ? "Đang lưu…" : "Lưu vào Ảnh", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.disabled(saving)
                }.buttonStyle(.bordered).padding(.horizontal, 20).padding(.bottom, 15)
            }.navigationTitle("G.LENS").navigationBarTitleDisplayMode(.inline).toolbar { Button("Xong") { dismiss() } }
                .sheet(isPresented: $share) { ShareSheet(urls: [item.url] + (item.rawURL.map { [$0] } ?? [])) }
                .alert("G.LENS", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) { Button("OK") { message = "" } } message: { Text(message) }
        }
    }
}
private struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
