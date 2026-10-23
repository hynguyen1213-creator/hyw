import SwiftUI
import AVKit

struct GalleryScreen: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss
    @State private var selected: SavedCapture?
    var body: some View {
        NavigationStack {
            ScrollView {
                if camera.captures.isEmpty { ContentUnavailableView("Chưa có ảnh", systemImage: "photo.on.rectangle", description: Text("Chụp ảnh, quay video hoặc nhập ảnh để bắt đầu.")) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(camera.captures) { item in
                        Button { selected = item } label: { GalleryThumbnail(item: item) }
                    }
                }.padding(8)
            }.navigationTitle("Khoảnh khắc").toolbar { Button("Xong") { dismiss() } }
                .sheet(item: $selected) { item in CaptureDetail(item: item, onDelete: { camera.refreshGallery() }) }
        }.tint(.red)
    }
}
private struct GalleryThumbnail: View {
    let item: SavedCapture
    @State private var thumbnail: UIImage?
    var body: some View {
        Color(white: 0.12).aspectRatio(1, contentMode: .fit)
            .overlay { if let thumbnail { GeometryReader { g in Image(uiImage: thumbnail).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped() } } }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo || item.rawURL != nil { Text(item.isVideo ? "▶ VIDEO" : "RAW+").font(.system(size: 10, weight: .semibold)).padding(5).background(.black.opacity(0.65)) }
            }
            .task(id: item.id) { thumbnail = await Task.detached(priority: .utility) { CaptureStore.shared.thumbnail(item.url) }.value }
    }
}
private struct CaptureDetail: View {
    let item: SavedCapture
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var saving = false
    @State private var share = false
    @State private var confirmDelete = false
    @State private var original = false
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Spacer()
                if item.isVideo { VideoPlayer(player: player).onAppear { player = AVPlayer(url: item.url) }.onDisappear { player?.pause() } }
                else if let image = original ? item.originalURL.flatMap({ UIImage(contentsOfFile: $0.path) }) : item.image { Image(uiImage: image).resizable().scaledToFit() }
                Spacer()
                if item.originalURL != nil { Toggle("So sánh ảnh gốc", isOn: $original).padding(.horizontal) }
                Text(item.metadata).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button { share = true } label: { Label("Chia sẻ", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    Button {
                        saving = true
                        CaptureStore.shared.saveToPhotos(item) { text in DispatchQueue.main.async { saving = false; message = text } }
                    } label: { Label(saving ? "Đang lưu…" : "Lưu Ảnh", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.disabled(saving)
                }.buttonStyle(.bordered).padding(.horizontal).padding(.bottom)
            }.navigationTitle("G.LENS").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") } }; ToolbarItem(placement: .topBarTrailing) { Button("Xong") { dismiss() } } }
                .sheet(isPresented: $share) { ShareSheet(urls: [original ? (item.originalURL ?? item.url) : item.url] + (item.rawURL.map { [$0] } ?? [])) }
                .confirmationDialog("Xoá ảnh/video này trong G.LENS? Bản đã lưu vào Ảnh vẫn còn.", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Xoá khỏi G.LENS", role: .destructive) {
                        do { try CaptureStore.shared.delete(item); onDelete(); dismiss() } catch { message = error.localizedDescription }
                    }
                }
                .alert("G.LENS", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) { Button("OK") { message = "" } } message: { Text(message) }
        }
    }
}
private struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
