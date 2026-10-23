import SwiftUI

struct ProSettingsPanel: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Hỗ trợ ngắm") {
                    Picker("Lưới", selection: $camera.options.grid) { ForEach(GridStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Histogram RGB", isOn: $camera.options.histogram)
                    Toggle("Zebra · cảnh báo vùng sáng", isOn: $camera.options.zebra)
                    if camera.options.zebra { valueSlider("Ngưỡng zebra", value: $camera.options.zebraThreshold, range: 0.7...1, suffix: "%", multiplier: 100) }
                    Toggle("Focus peaking · viền đỏ", isOn: $camera.options.peaking)
                    if camera.options.peaking { valueSlider("Ngưỡng biên nét", value: $camera.options.peakingThreshold, range: 0.05...0.5, suffix: "", multiplier: 100) }
                    Toggle("Cân bằng đường chân trời", isOn: $camera.options.level)
                    Toggle("Khung an toàn 90%", isOn: $camera.options.safeFrame)
                    Text("Histogram và zebra đo ảnh xem trước sau xử lý. Peaking đánh dấu biên tương phản để hỗ trợ lấy nét.").font(.caption).foregroundStyle(.secondary)
                }
                if !camera.mode.isMovie {
                    Section("File ảnh") {
                        Picker("Định dạng", selection: $camera.options.encoding) {
                            Text("JPEG").tag(PhotoEncoding.jpeg)
                            if camera.supportsHEIF || camera.imported { Text("HEIF").tag(PhotoEncoding.heif) }
                        }
                        Toggle("Độ phân giải cao nhất", isOn: $camera.options.maximumResolution).disabled(camera.options.sequence == .bracket || camera.mode == .longExposure)
                        LabeledContent("Camera đang chọn", value: camera.photoResolution)
                        Toggle("Lưu thêm DNG gốc", isOn: $camera.rawEnabled).disabled(!camera.supportsRaw || camera.mode == .longExposure || camera.options.sequence == .bracket || camera.imported)
                        Text(camera.rawLabel).font(.caption).foregroundStyle(.secondary)
                        Toggle("Giữ ảnh chưa áp màu", isOn: $camera.options.saveOriginal)
                        Toggle("Tự lưu vào ứng dụng Ảnh", isOn: $camera.options.autoSavePhotos)
                    }
                    if camera.mode != .longExposure {
                        Section("Chụp chuỗi") {
                            Picker("Kiểu chụp", selection: $camera.options.sequence) {
                                ForEach(SequenceKind.allCases, id: \.self) { kind in
                                    if kind != .bracket || camera.supportsBracket { Text(kind.rawValue).tag(kind) }
                                }
                            }
                            if camera.options.sequence == .burst || camera.options.sequence == .interval {
                                Stepper("Số ảnh: \(camera.options.sequenceCount)", value: $camera.options.sequenceCount, in: 2...99)
                            }
                            if camera.options.sequence == .interval { valueSlider("Khoảng cách", value: $camera.options.intervalSeconds, range: 0.5...30, suffix: "s") }
                            if camera.options.sequence == .bracket {
                                Picker("Bước EV", selection: $camera.options.bracketEV) { ForEach([Float(0.5), 1, 2], id: \.self) { Text("±\($0, specifier: "%.1f") EV").tag($0) } }
                                Text("Lưu 3 ảnh sáng khác nhau để chọn hoặc ghép HDR sau. Không ghép HDR tự động. Flash và DNG tắt trong BKT.").font(.caption).foregroundStyle(.secondary)
                            }
                            if camera.options.sequence == .burst { Text("Tốc độ phụ thuộc thời gian phơi sáng và xử lý; không cố định số ảnh/giây.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if camera.mode == .longExposure {
                        Section("Phơi sáng ghép khung hình") {
                            Picker("Hiệu ứng", selection: $camera.options.longBlend) { ForEach(LongBlend.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            Picker("Thời gian", selection: $camera.options.longSeconds) { ForEach([1.0, 2, 4, 8, 15, 30], id: \.self) { Text("\(Int($0)) giây").tag($0) } }
                            Text("Giữ máy trên tripod. Ghép luồng camera, cạnh dài tối đa 1920 px; không phải phơi cảm biến 30 giây. Không xuất RAW.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if camera.mode == .portrait {
                        Section("Chân dung") {
                            valueSlider("Mờ hậu cảnh", value: $camera.options.portraitBlur, range: 0...1, suffix: "%", multiplier: 100)
                            Text("Tách người trên thiết bị và xoá phông khi lưu. Ảnh xem trước chưa xoá phông; ảnh gốc được giữ nếu bật tuỳ chọn trên.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("Quay video") {
                        Picker("Định dạng", selection: Binding(get: { camera.selectedVideo?.id ?? "" }, set: { id in if let choice = camera.videoChoices.first(where: { $0.id == id }) { camera.selectVideo(choice) } })) {
                            ForEach(visibleChoices) { Text($0.title).tag($0.id) }
                        }.disabled(camera.changingLens)
                        Toggle("Chống rung", isOn: $camera.options.stabilization)
                            .onChange(of: camera.options.stabilization) { _, _ in if let choice = camera.selectedVideo { camera.selectVideo(choice) } }
                        Toggle("Thu tiếng micro", isOn: $camera.options.microphone).disabled(camera.mode != .video)
                        Toggle("Tự lưu vào Ảnh", isOn: $camera.options.autoSavePhotos)
                        if camera.mode == .timeLapse { valueSlider("Chụp mỗi", value: $camera.options.lapseInterval, range: 0.25...10, suffix: "s") }
                        Text(camera.mode == .timeLapse ? "1080p dọc, phát 30 fps, không âm thanh." : camera.mode == .slowMotion ? "Quay tốc độ cao rồi xuất chậm về 30 fps, không âm thanh." : "Video giữ màu camera hoặc Log/HDR đã chọn. Bộ màu và khung ảnh G.LENS chỉ áp cho ảnh chụp.").font(.caption).foregroundStyle(.secondary)
                        Text("4K, FPS cao, HDR HLG và Apple Log chỉ xuất hiện khi camera hỗ trợ. HDR HLG không đồng nghĩa Dolby Vision.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Chụp ảnh") {
                    Picker("Hẹn giờ", selection: $camera.options.timerSeconds) { ForEach([0, 3, 5, 10], id: \.self) { Text($0 == 0 ? "Tắt" : "\($0) giây").tag($0) } }
                    if camera.supportsFlash && !camera.mode.isMovie { Picker("Flash", selection: $camera.options.flash) { Text("Tắt").tag(0); Text("Tự động").tag(1); Text("Bật").tag(2) } }
                    if camera.supportsTorch { Toggle("Đèn liên tục", isOn: Binding(get: { camera.torchOn }, set: { camera.setTorch($0) })) }
                }
                Section("G.LENS Pro 0.3") {
                    Text("Bộ màu tự xây dựng lấy cảm hứng từ nhiếp ảnh Leica. Các thuật toán, LUT độc quyền và phần cứng Xiaomi không nằm trong ứng dụng.").font(.caption).foregroundStyle(.secondary)
                    Text("Ảnh và video xử lý trên iPhone. Không tải ảnh lên máy chủ.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Thiết lập chụp").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Xong") { dismiss() } }
                .disabled(camera.recording || camera.recordingBusy || camera.capturing || camera.sequenceActive)
        }.tint(.red)
    }
    private var visibleChoices: [VideoChoice] {
        camera.videoChoices.filter {
            if camera.mode == .slowMotion { return $0.fps >= 120 && $0.tone == .standard }
            if camera.mode == .timeLapse { return $0.width == 1920 && $0.fps == 30 && $0.tone == .standard }
            return $0.fps <= 120
        }
    }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, multiplier: Double = 1) -> some View {
        VStack(alignment: .leading) { HStack { Text(title); Spacer(); Text(String(format: "%.1f", value.wrappedValue * multiplier) + suffix).monospacedDigit().foregroundStyle(.secondary) }; Slider(value: value, in: range) }
    }
}
struct ProHistogram: View {
    let analysis: ExposureAnalysis
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Canvas { context, size in
                for (bins, color) in [(analysis.red, Color.red), (analysis.green, Color.green), (analysis.blue, Color.blue)] {
                    var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                    for (i, value) in bins.enumerated() { path.addLine(to: CGPoint(x: Double(i) * size.width / 63, y: size.height * (1 - value))) }
                    path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                    context.fill(path, with: .color(color.opacity(0.38)))
                }
            }.frame(width: 110, height: 42)
            Text(String(format: "CLIP %.1f%%", analysis.clipped * 100)).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
        }.padding(6).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5)).allowsHitTesting(false)
    }
}
struct ProGrid: Shape {
    let style: GridStyle
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let positions: [CGFloat] = style == .golden ? [0.382, 0.618] : style == .square ? [0.25, 0.5, 0.75] : style == .thirds ? [1.0 / 3, 2.0 / 3] : []
        for n in positions { p.move(to: CGPoint(x: rect.width * n, y: 0)); p.addLine(to: CGPoint(x: rect.width * n, y: rect.height)); p.move(to: CGPoint(x: 0, y: rect.height * n)); p.addLine(to: CGPoint(x: rect.width, y: rect.height * n)) }
        return p
    }
}
struct PresetPanel: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Lưu màu và thông số hiện tại") {
                    TextField("Ví dụ: Phố chiều · Gold", text: $name)
                    Button("Lưu preset") { camera.savePreset(name: name, color: camera.currentColor()); name = "" }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Preset của mày") {
                    ForEach(camera.presets) { preset in
                        Button { camera.applyPreset(preset); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name).foregroundStyle(.primary)
                                Text(preset.color.look.name + (preset.manualExposure ? " · ISO \(Int(preset.iso)) · " + ProMath.shutterLabel(preset.shutter) : " · Auto exposure")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete { camera.presets.remove(atOffsets: $0); CameraPreset.save(camera.presets) }
                    if camera.presets.isEmpty { Text("Chọn màu, chỉnh thông số rồi lưu để gọi lại nhanh.").foregroundStyle(.secondary) }
                }
            }.navigationTitle("Preset cá nhân").navigationBarTitleDisplayMode(.inline).toolbar { Button("Xong") { dismiss() } }
        }.tint(.red)
    }
}
