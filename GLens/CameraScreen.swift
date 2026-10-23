import SwiftUI
import PhotosUI

private let cameraRed = Color(red: 0.89, green: 0.19, blue: 0.15)
private let cameraWhite = Color(white: 0.96)
private let cameraBlack = Color(red: 0.045, green: 0.049, blue: 0.047)
private let cameraPanel = Color(red: 0.095, green: 0.10, blue: 0.098)

struct CameraScreen: View {
    @ObservedObject var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @State private var color = ColorSettings.restored()
    @StateObject private var horizon = HorizonMeter()
    @State private var showProSettings = false
    @State private var showPresets = false
    @State private var pinchStart: CGFloat?
    @State private var showControls = false
    @State private var showGallery = false
    @State private var showLooks = false
    @State private var showColor = false
    @State private var showHelp = false
    @State private var picker: PhotosPickerItem?
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var shutterPending = false
    @State private var focusPoint: CGPoint?
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 690
            VStack(spacing: 0) {
                header(compact: compact)
                utilityBar
                if camera.mode == .pro { quickControls }
                viewfinder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                captureDeck(compact: compact)
                colorBar
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(cameraBlack.ignoresSafeArea())
        .foregroundStyle(cameraWhite)
        .task {
            if !ProcessInfo.processInfo.arguments.contains("--ui-smoke") { camera.authorizeAndStart(); horizon.start() }
            update(); camera.updateOptions()
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--self-check") { Task.detached { await SimulatorChecks.run() } }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--pro-settings") { showProSettings = true }
            if ProcessInfo.processInfo.arguments.contains("--pro-controls") { showControls = true }
        }
        .onDisappear { horizon.stop() }
        .onChange(of: camera.options) { _, _ in camera.updateOptions() }
        .onChange(of: camera.colorRevision) { _, _ in color = camera.currentColor() }
        .onChange(of: camera.mode) { _, mode in
            if mode.isMovie { color.ratio = 9.0 / 16 } else { color.ratio = 3.0 / 4 }
            update()
        }
        .onChange(of: scenePhase) { _, phase in
            camera.setActive(phase == .active && !showGallery)
            if phase == .active { horizon.start() } else { horizon.stop() }
            if phase != .active {
                countdownTask?.cancel(); countdown = 0; shutterPending = false
                focusTask?.cancel(); focusPoint = nil
                camera.setCompare(false)
            }
        }
        .onChange(of: picker) { _, item in
            Task {
                guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                camera.importPhoto(data)
            }
        }
        .onChange(of: showGallery) { _, visible in camera.setActive(!visible && scenePhase == .active) }
        .sheet(isPresented: $showProSettings) { ProSettingsPanel(camera: camera) }
        .sheet(isPresented: $showPresets) { PresetPanel(camera: camera) }
        .sheet(isPresented: $showControls) {
            HardwareControls(camera: camera)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .presentationCornerRadius(26)
        }
        .sheet(isPresented: $showGallery) { GalleryScreen(camera: camera) }
        .sheet(isPresented: $showLooks) {
            looksDrawer.presentationDetents([.height(460), .large])
                .presentationDragIndicator(.visible).presentationCornerRadius(26)
                .presentationBackground(cameraPanel)
        }
        .sheet(isPresented: $showColor) {
            colorDrawer.presentationDetents([.height(460), .large])
                .presentationDragIndicator(.visible).presentationCornerRadius(26)
                .presentationBackground(cameraPanel)
        }
        .sheet(isPresented: $showHelp) { help }
        .overlay(alignment: .top) {
            if !camera.toast.isEmpty { Text(camera.toast).font(.system(size: 12, weight: .medium)).padding(12).background(.ultraThinMaterial, in: Capsule()).padding(.top, 90).allowsHitTesting(false) }
        }
        .alert("G.LENS", isPresented: Binding(get: { !camera.message.isEmpty }, set: { if !$0 { camera.message = "" } })) {
            Button("OK") { camera.message = "" }
        } message: { Text(camera.message) }
    }

    private func header(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(cameraRed).frame(width: 8, height: 8)
                Text("G.LENS").font(.system(size: 20, weight: .semibold)).tracking(-0.8)
            }
            Spacer()
            Text(camera.imported ? "DARKROOM" : "PRO CAMERA")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(2.3).foregroundStyle(.white.opacity(0.35))
            Spacer()
            PhotosPicker(selection: $picker, matching: .images) {
                Image(systemName: "photo.badge.plus").font(.system(size: 17, weight: .light))
                    .frame(width: 36, height: 36)
            }.accessibilityLabel("Mở ảnh").disabled(camera.recording || camera.recordingBusy || camera.capturing || camera.sequenceActive)
            Button { showProSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 19, weight: .regular))
                    .frame(width: 32, height: 36)
            }.accessibilityLabel("Thiết lập chụp")
        }
        .padding(.horizontal, 21).frame(height: compact ? 44 : 52)
    }

    private var utilityBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(camera.running ? Color.green.opacity(0.7) : cameraRed.opacity(0.8))
                    .frame(width: 3, height: 3)
                Text(camera.recording ? "REC " + ProMath.durationLabel(camera.elapsed) : camera.imported ? "EDIT" : "LIVE")
                    .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.2)
            }.foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button {
                if camera.supportsRaw && !camera.imported { camera.rawEnabled.toggle() }
            } label: {
                Text(camera.mode.isMovie ? (camera.selectedVideo?.tone.rawValue ?? "VIDEO") : camera.rawEnabled && !camera.imported ? "RAW+" : camera.options.encoding.rawValue)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.white.opacity(camera.rawEnabled ? 0.75 : 0.25), lineWidth: 0.6))
                    .frame(minWidth: 44, minHeight: 34)
            }
            .disabled(!camera.supportsRaw || camera.imported || camera.capturing || camera.mode.isMovie || camera.mode == .longExposure || camera.options.sequence == .bracket)
            .accessibilityLabel(camera.rawEnabled ? "Tắt RAW" : "Bật RAW nếu camera hỗ trợ")
            Button { camera.options.grid = camera.options.grid == .off ? .thirds : .off } label: {
                Image(systemName: "grid").font(.system(size: 15, weight: .light))
                    .foregroundStyle(camera.options.grid != .off ? cameraWhite : .white.opacity(0.4))
                    .frame(width: 43, height: 34)
            }.accessibilityLabel("Lưới bố cục")
            Button { camera.options.timerSeconds = camera.options.timerSeconds == 0 ? 3 : camera.options.timerSeconds == 3 ? 10 : 0 } label: {
                HStack(spacing: 3) {
                    Image(systemName: "timer").font(.system(size: 15, weight: .light))
                    if camera.options.timerSeconds > 0 { Text("\(camera.options.timerSeconds)").font(.system(size: 8, design: .monospaced)) }
                }.foregroundStyle(camera.options.timerSeconds > 0 ? cameraWhite : .white.opacity(0.4))
                    .frame(width: 43, height: 34)
            }.accessibilityLabel(camera.options.timerSeconds == 0 ? "Bật hẹn giờ" : "Hẹn giờ \(camera.options.timerSeconds) giây")
            Menu {
                Button("4:3") { color.ratio = 3.0 / 4; update() }
                Button("3:2") { color.ratio = 2.0 / 3; update() }
                Button("1:1") { color.ratio = 1; update() }
                Button("16:9") { color.ratio = 9.0 / 16; update() }
            } label: {
                Text(ratioName).font(.system(size: 9, weight: .medium, design: .monospaced))
                    .frame(width: 38, height: 34)
            }.accessibilityLabel("Tỷ lệ ảnh \(ratioName)").disabled(camera.mode.isMovie || camera.capturing || camera.recording || camera.sequenceActive)
        }
        .foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 21).frame(height: 34)
    }

    private var viewfinder: some View {
        GeometryReader { available in
            let width = min(available.size.width, available.size.height * color.ratio)
            let height = width / color.ratio
            ZStack {
                Color.black
                ZStack {
                    Color(white: 0.065)
                    if let image = camera.preview {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: width, height: height)
                    } else {
                        permissionView
                    }
                    if camera.options.grid != .off { ProGrid(style: camera.options.grid).stroke(.white.opacity(0.24), lineWidth: 0.5).allowsHitTesting(false) }
                    if let overlay = camera.analysis.overlay, !camera.imported, camera.options.zebra || camera.options.peaking {
                        Image(uiImage: overlay).resizable().interpolation(.none).frame(width: width, height: height).allowsHitTesting(false)
                    }
                    if camera.options.safeFrame { Rectangle().strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3])).padding(.horizontal, width * 0.05).padding(.vertical, height * 0.05).allowsHitTesting(false) }
                    if camera.options.level && !camera.imported && camera.preview != nil {
                        ZStack {
                            Rectangle().fill(.white.opacity(0.45)).frame(width: 68, height: 1)
                            Rectangle().fill(abs(horizon.degrees) < 1.5 ? Color.green : Color.yellow).frame(width: 68, height: 2).rotationEffect(.degrees(-horizon.degrees))
                            Circle().stroke(abs(horizon.degrees) < 1.5 ? Color.green : Color.yellow, lineWidth: 1).frame(width: 7, height: 7)
                        }.allowsHitTesting(false)
                    }
                    LinearGradient(colors: [.black.opacity(0.27), .clear, .clear, .black.opacity(0.52)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    if camera.preview != nil && !camera.imported {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { point in
                                let normalized = CGPoint(x: min(1, max(0, point.x / width)), y: min(1, max(0, point.y / height)))
                                camera.focus(at: normalized)
                                focusPoint = normalized
                                focusTask?.cancel()
                                focusTask = Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1.2))
                                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.18)) { focusPoint = nil } }
                                }
                            }
                    }
                    if camera.options.histogram && !camera.imported && camera.preview != nil { VStack { HStack { Spacer(); ProHistogram(analysis: camera.analysis) }; Spacer() }.padding(.top, 59).padding(.trailing, 18).allowsHitTesting(false) }
                    RangefinderCorners().stroke(.white.opacity(0.45), lineWidth: 0.7)
                        .padding(11).allowsHitTesting(false)
                    if let focusPoint {
                        FocusReticle().stroke(cameraRed, lineWidth: 1)
                            .frame(width: 55, height: 55)
                            .position(x: focusPoint.x * width, y: focusPoint.y * height)
                            .allowsHitTesting(false)
                    }
                    viewfinderOverlays(width: width)
                    if countdown > 0 {
                        Text("\(countdown)").font(.system(size: 84, weight: .ultraLight, design: .rounded))
                            .shadow(color: .black.opacity(0.5), radius: 12).allowsHitTesting(false)
                    }
                    if camera.interrupted {
                        Label("Camera đang tạm gián đoạn", systemImage: "pause.circle")
                            .font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 11)
                            .background(.black.opacity(0.8), in: Capsule())
                    }
                }
                .frame(width: max(1, width), height: max(1, height)).clipped()
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    guard !camera.imported, !camera.changingLens, !camera.capturing else { return }
                    if pinchStart == nil { pinchStart = camera.zoom }
                    camera.zoom = max(1, min(camera.maxZoom, (pinchStart ?? 1) * value.magnification)); camera.setZoom(camera.zoom)
                }.onEnded { _ in pinchStart = nil })
            }.frame(width: available.size.width, height: available.size.height)
        }
    }

    private var permissionView: some View {
        VStack(spacing: 15) {
            Image(systemName: "camera.aperture").font(.system(size: 43, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.25))
            Text(camera.permissionDenied ? "Mở một góc nhìn mới." : "Chậm lại. Nhìn sâu hơn.")
                .font(.system(size: 15, weight: .light)).foregroundStyle(.white.opacity(0.6))
            if camera.permissionDenied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Cho phép camera", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 11)
                        .background(.white.opacity(0.08), in: Capsule())
                }
                Text("Mở Cài đặt → G.LENS → Camera")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
            } else {
                Button("Bật camera") { camera.authorizeAndStart() }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(cameraRed)
                    .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }.padding(24)
    }

    private func viewfinderOverlays(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { showLooks = true } label: {
                    HStack(spacing: 6) {
                        Rectangle().fill(cameraRed).frame(width: 4, height: 4)
                        Text(camera.mode.isMovie ? (camera.selectedVideo?.title ?? "VIDEO") : color.look.name.uppercased()).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1)
                    }.padding(8).background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 3))
                }.accessibilityLabel("Chọn chất ảnh").disabled(camera.mode.isMovie)
                Spacer()
                Text("GỐC").font(.system(size: 8, weight: .medium)).tracking(0.4)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.25), lineWidth: 0.5))
                    .onLongPressGesture(minimumDuration: 0.05, pressing: { camera.setCompare($0) }, perform: {})
                    .accessibilityLabel("Giữ để xem ảnh gốc")
            }
            Spacer(minLength: 8)
            if !camera.sequenceProgress.isEmpty { Text(camera.sequenceProgress).font(.system(size: 18, weight: .medium, design: .monospaced)).padding(10).background(.black.opacity(0.5), in: Capsule()) }
            if camera.mode == .portrait { Text("Xoá phông người khi lưu").font(.system(size: 10)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            if camera.mode == .longExposure { Text("STACK · \(Int(camera.options.longSeconds))s · tripod").font(.system(size: 10, design: .monospaced)).padding(6).background(.black.opacity(0.35), in: Capsule()) }
            HStack(spacing: 9) {
                Text(camera.imported ? "ON-DEVICE COLOR" : camera.running ? String(format: "ISO %.0f", camera.currentISO) : "CAMERA CHƯA BẬT")
                if !camera.imported && camera.running {
                    Text(shutterName(camera.currentShutter))
                    if camera.manualExposure { Text("M").foregroundStyle(cameraRed) }
                    Text(String(format: "%+.1f", camera.meterEV))
                    if camera.aeLocked { Text("AE-L").foregroundStyle(.yellow) }
                    if camera.afLocked { Text("AF-L").foregroundStyle(.yellow) }
                }
                Spacer()
                if !camera.imported && !camera.mode.isMovie { Text(camera.mode == .longExposure ? "1920px" : camera.photoResolution) }
            }
            .font(.system(size: 8, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.72)).padding(.horizontal, 7).padding(.bottom, 14)
            cameraLenses(compact: width < 300)
        }.padding(15)
    }

    private func cameraLenses(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if camera.imported {
                Button { camera.returnToCamera() } label: {
                    Label("Quay lại camera", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium)).padding(.horizontal, 17).padding(.vertical, 11)
                }.background(.black.opacity(0.6), in: Capsule())
            } else {
                Menu {
                    ForEach(camera.lenses) { lens in
                        Button { camera.selectLens(lens.id) } label: {
                            if camera.selectedLens == lens.id { Label(lens.title, systemImage: "checkmark") }
                            else { Text(lens.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(camera.lenses.first(where: { $0.id == camera.selectedLens })?.title.uppercased() ?? "CHÍNH")
                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .medium))
                    }.font(.system(size: 8, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(.black.opacity(0.65), in: Capsule())
                }
                .disabled(!camera.running || camera.capturing || camera.changingLens || camera.recording || camera.recordingBusy || camera.sequenceActive)
                .accessibilityLabel("Chọn camera vật lý")
                HStack(spacing: 1) {
                    ForEach(compact ? [1.0, 2.0, 3.0] : [1.0, 1.2, 1.5, 2.0, 3.0], id: \.self) { value in
                        if CGFloat(value) <= camera.maxZoom {
                            let selected = abs(camera.zoom - CGFloat(value)) < 0.035
                            Button {
                                camera.zoom = CGFloat(value); camera.setZoom(CGFloat(value))
                            } label: {
                                Text(String(format: "%g", value))
                                    .font(.system(size: 10, weight: selected ? .semibold : .regular, design: .monospaced))
                                    .frame(width: 31, height: 31)
                                    .foregroundStyle(selected ? cameraRed : .white.opacity(0.75))
                                    .background(selected ? Color.white : Color.clear, in: Circle())
                            }.disabled(!camera.running || camera.capturing || camera.changingLens)
                                .accessibilityLabel("Zoom số \(String(format: "%g", value)) lần")
                        }
                    }
                }.padding(3).background(.black.opacity(0.65), in: Capsule())
            }
        }.frame(maxWidth: .infinity)
    }

    private func captureDeck(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 23) {
                    ForEach(ShootingMode.allCases) { mode in
                        modeButton(mode.rawValue, selected: camera.mode == mode) { camera.changeMode(mode) }
                    }
                }.padding(.horizontal, 23)
            }.frame(height: 32).disabled(camera.recording || camera.recordingBusy || camera.capturing || camera.sequenceActive || shutterPending)
            HStack {
                Button { showGallery = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06))
                        if let image = camera.lastThumbnail {
                            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 19, weight: .light)).foregroundStyle(.white.opacity(0.55))
                        }
                    }.frame(width: 42, height: 46).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.16), lineWidth: 0.6))
                }.frame(width: 62, height: 70).accessibilityLabel("Thư viện ảnh").disabled(camera.recording || camera.recordingBusy || camera.capturing || camera.sequenceActive)
                Spacer()
                Button { timedCapture() } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.85), lineWidth: 1.5)
                        if camera.recording || camera.sequenceActive { RoundedRectangle(cornerRadius: 5).fill(cameraRed).frame(width: 27, height: 27) }
                        else { Circle().fill(camera.mode.isMovie ? cameraRed : cameraWhite).padding(6) }
                        if camera.capturing || camera.recordingBusy { ProgressView().tint(.black) }
                        if shutterPending { Text("\(max(1, countdown))").font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(.black) }
                    }.frame(width: compact ? 68 : 76, height: compact ? 68 : 76)
                }
                .buttonStyle(CameraShutterStyle())
                .disabled((camera.capturing && !camera.sequenceActive) || camera.changingLens || camera.recordingBusy || camera.adjustingExposure || (!camera.running && !camera.imported) || (camera.mode.isMovie && camera.selectedVideo == nil))
                .accessibilityLabel(camera.recording || camera.sequenceActive ? "Dừng" : camera.mode.isMovie ? "Quay video" : camera.imported ? "Lưu ảnh đã chỉnh màu" : "Chụp ảnh")
                Spacer()
                Button { showControls = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 21, weight: .light))
                        Text(camera.manualExposure ? "MANUAL" : "PRO").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(1.2)
                    }.frame(width: 62, height: 70).foregroundStyle(camera.manualExposure ? cameraRed : .white.opacity(0.75))
                }.accessibilityLabel("Điều khiển camera phần cứng").disabled(camera.recordingBusy || camera.capturing || camera.sequenceActive)
            }.padding(.horizontal, 28)
        }
        .padding(.top, compact ? 5 : 10).padding(.bottom, compact ? 8 : 15)
        .background(cameraBlack)
    }

    private var colorBar: some View {
        HStack(spacing: 0) {
            Button { showLooks = true } label: {
                HStack(spacing: 9) {
                    HStack(spacing: -3) {
                        ForEach(0..<3) { index in Circle().fill(palette(for: color.look)[index]).frame(width: 12, height: 12).overlay(Circle().stroke(cameraBlack, lineWidth: 1)) }
                    }
                    Text(color.look.name).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.up").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                }.frame(height: 43)
            }.accessibilityLabel("Chọn chất ảnh \(color.look.name)").disabled(camera.mode.isMovie)
            Spacer()
            Button { showPresets = true } label: { Image(systemName: "bookmark").font(.system(size: 17)).frame(width: 42, height: 43) }.accessibilityLabel("Preset cá nhân").disabled(camera.recording || camera.capturing)
            Button { showColor = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dial.low").font(.system(size: 14, weight: .light))
                    Text("Tinh chỉnh").font(.system(size: 10))
                }.foregroundStyle(.white.opacity(0.55)).frame(height: 43)
            }.accessibilityLabel("Tinh chỉnh màu và khung ảnh").disabled(camera.mode.isMovie)
        }.padding(.horizontal, 25)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 20) }
    }

    private var looksDrawer: some View {
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 23) {
            drawerHeader(eyebrow: "THE COLOR OF A MOMENT", title: "Chất ảnh", close: { showLooks = false })
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)], spacing: 11) {
                ForEach(Array(Look.all.enumerated()), id: \.element.id) { index, look in
                    let selected = color.look == look
                    Button {
                        color.look = look; update()
                    } label: {
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                Text(String(format: "%02d", index + 1)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
                                Spacer()
                                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(cameraRed) }
                            }
                            HStack(spacing: 4) {
                                ForEach(0..<3) { n in RoundedRectangle(cornerRadius: 2).fill(palette(for: look)[n]).frame(height: 18) }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(look.name).font(.system(size: 12, weight: .medium)).foregroundStyle(cameraWhite)
                                Text(look.subtitle).font(.system(size: 6, weight: .medium, design: .monospaced)).tracking(0.7).foregroundStyle(.white.opacity(0.35))
                            }
                        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(selected ? 0.065 : 0.025), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? cameraRed.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 0.7))
                    }.buttonStyle(.plain).accessibilityLabel("Chất ảnh \(look.name)").accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 20)
            .foregroundStyle(cameraWhite)
        }
    }

    private var colorDrawer: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 25) {
                drawerHeader(eyebrow: "MAKE IT YOURS", title: "Tinh chỉnh", close: { showColor = false })
                VStack(spacing: 24) {
                    colorSlider("Cường độ màu", value: $color.strength)
                    colorSlider("Hạt ảnh", value: $color.grain)
                    colorSlider("Tối viền", value: $color.vignette)
                    adjustmentSlider("Bù sáng xử lý", value: $color.exposure, range: -2...2)
                    adjustmentSlider("Tương phản", value: $color.contrast, range: 0.7...1.4)
                    adjustmentSlider("Bão hoà", value: $color.saturation, range: 0...1.5)
                    adjustmentSlider("Ấm / lạnh", value: $color.temperature, range: -1...1)
                    adjustmentSlider("Tint xanh / tím", value: $color.tint, range: -1...1)
                    adjustmentSlider("Vùng tối", value: $color.shadows, range: -0.5...1)
                    adjustmentSlider("Vùng sáng", value: $color.highlights, range: 0...1)
                    colorSlider("Độ nét", value: $color.sharpness)
                }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
                Toggle(isOn: $color.frame) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.inset.filled").font(.system(size: 21, weight: .ultraLight)).foregroundStyle(.white.opacity(0.55))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Signature frame").font(.system(size: 12, weight: .medium))
                            Text("Khung trắng, thông số và tên tác giả").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }.tint(cameraRed).onChange(of: color.frame) { _, _ in update() }
                if color.frame {
                    TextField("Tên tác giả", text: $color.author)
                        .font(.system(size: 12)).padding(13)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .onChange(of: color.author) { _, _ in update() }
                }
                Button {
                    let look = color.look; color = ColorSettings(); color.look = look; update()
                } label: {
                    Label("Đặt lại tinh chỉnh", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity)
                }.padding(.top, 1)
            }.padding(.horizontal, 25).padding(.top, 30).padding(.bottom, 28)
        }.foregroundStyle(cameraWhite)
    }

    private func drawerHeader(eyebrow: String, title: String, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow).font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.white.opacity(0.3))
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(title).font(.system(size: 27, weight: .light)).tracking(-0.9)
                    Text(".").font(.system(size: 27, weight: .light)).foregroundStyle(cameraRed)
                }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5)).frame(width: 30, height: 30)
                    .background(.white.opacity(0.05), in: Circle())
            }.accessibilityLabel("Đóng")
        }
    }

    private func colorSlider(_ title: String, value: Binding<Float>) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(Int(value.wrappedValue * 100))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
            Slider(value: value, in: 0...1).tint(cameraRed)
                .onChange(of: value.wrappedValue) { _, _ in update() }
        }
    }

    private func adjustmentSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack { HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit() }.font(.system(size: 12)); Slider(value: value, in: range).tint(cameraRed).onChange(of: value.wrappedValue) { _, _ in update() } }
    }
    private var quickControls: some View {
        HStack(spacing: 0) {
            ForEach([("WB", camera.manualWB ? "\(Int(camera.whiteBalanceKelvin))K" : "AUTO"), ("ISO", String(format: "%.0f", camera.currentISO)), ("S", ProMath.shutterLabel(camera.currentShutter)), ("EV", String(format: "%+.1f", camera.exposureBias)), ("FOCUS", camera.manualFocus ? "MF" : "AF")], id: \.0) { item in
                Button { showControls = true } label: { VStack(spacing: 4) { Text(item.0).font(.system(size: 9)); Text(item.1).font(.system(size: 11, weight: .medium, design: .monospaced)) }.frame(maxWidth: .infinity).frame(height: 43) }
            }
        }.background(.white.opacity(0.025))
    }
    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(0.5)
                    .foregroundStyle(selected ? cameraWhite : .white.opacity(0.3))
                Circle().fill(selected ? cameraRed : .clear).frame(width: 3, height: 3)
            }
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func palette(for look: Look) -> [Color] {
        switch look.id {
        case "vibrant": return [Color(red: 0.21, green: 0.46, blue: 0.40), Color(red: 0.78, green: 0.33, blue: 0.23), Color(red: 0.86, green: 0.72, blue: 0.42)]
        case "m9": return [Color(red: 0.22, green: 0.35, blue: 0.33), Color(red: 0.65, green: 0.31, blue: 0.25), Color(red: 0.75, green: 0.64, blue: 0.47)]
        case "m3": return [Color(white: 0.20), Color(white: 0.45), Color(white: 0.77)]
        case "gold": return [Color(red: 0.40, green: 0.43, blue: 0.31), Color(red: 0.70, green: 0.50, blue: 0.28), Color(red: 0.87, green: 0.74, blue: 0.51)]
        case "noir": return [Color(white: 0.08), Color(white: 0.30), Color(white: 0.92)]
        default: return [Color(red: 0.22, green: 0.30, blue: 0.26), Color(red: 0.62, green: 0.34, blue: 0.27), Color(red: 0.73, green: 0.68, blue: 0.54)]
        }
    }

    private var isEssential: Bool { color.look.id == "m9" || color.look.id == "m3" }
    private var ratioName: String { color.ratio == 1 ? "1:1" : color.ratio < 0.6 ? "16:9" : color.ratio < 0.7 ? "3:2" : "4:3" }
    private func update() { camera.updateColor(color) }
    private func timedCapture() {
        if shutterPending { countdownTask?.cancel(); countdown = 0; shutterPending = false; return }
        if camera.recording || camera.sequenceActive { camera.shutterAction(); return }
        let timer = camera.options.timerSeconds
        if timer == 0 { camera.shutterAction(); return }
        shutterPending = true
        countdownTask = Task { @MainActor in
            for count in stride(from: timer, through: 1, by: -1) {
                if Task.isCancelled { break }
                countdown = count
                try? await Task.sleep(for: .seconds(1))
            }
            countdown = 0; shutterPending = false
            if !Task.isCancelled { camera.shutterAction() }
        }
    }

    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Text("The art of seeing.").font(.system(size: 32, weight: .light)).tracking(-1)
                    helpParagraph("CHỤP THEO CÁCH CỦA MÀY", "G.LENS dùng AVFoundation để truy cập camera iPhone. Cấp quyền Camera khi hệ thống hỏi, rồi chụp bằng nút tròn trắng.")
                    helpParagraph("ỐNG KÍNH & ĐIỀU KHIỂN", "Chọn camera vật lý trong menu ở kính ngắm. Các mức 1.2×, 1.5×… là zoom số trên camera đang chọn. Nút PRO mở ISO, tốc độ, lấy nét và cân bằng trắng; chức năng không hỗ trợ sẽ bị mờ.")
                    helpParagraph("MỘT CHÚT CHẤT RIÊNG", "Chọn chất ảnh ở thanh dưới. Giữ GỐC trên kính ngắm để so sánh. Cường độ, hạt ảnh, tối viền và khung chữ ký nằm trong Tinh chỉnh.")
                    helpParagraph("ẢNH Ở LẠI TRÊN IPHONE", "Ảnh được giữ trong app cho đến khi chọn Lưu vào Ảnh hoặc Chia sẻ. RAW/ProRAW chỉ hiện khi camera hỗ trợ; DNG giữ nguyên dữ liệu gốc, JPEG áp màu riêng.")
                    Text("Màu do G.LENS tự xây dựng, lấy cảm hứng từ nhiếp ảnh Leica; không sử dụng LUT độc quyền hay tái tạo phần cứng Xiaomi. Camera2 API thuộc Android. Không quảng cáo, không tải ảnh lên mạng.")
                        .font(.system(size: 10)).lineSpacing(5).foregroundStyle(.white.opacity(0.35))
                }.padding(25)
            }.background(cameraBlack).navigationTitle("G.LENS").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Xong") { showHelp = false }.font(.system(size: 12)).foregroundStyle(cameraWhite) }
        }.tint(cameraRed)
    }
    private func helpParagraph(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(cameraRed)
            Text(detail).font(.system(size: 13, weight: .light)).lineSpacing(5).foregroundStyle(.white.opacity(0.65))
        }
    }
}

private func shutterName(_ value: Double) -> String {
    value > 0 && value < 1 ? "1/\(Int((1 / value).rounded()))s" : String(format: "%.1fs", value)
}
private struct CameraShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
private struct CompositionGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                }
            }.stroke(.white.opacity(0.28), lineWidth: 0.5)
        }
    }
}
private struct RangefinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let length: CGFloat = 11
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let dx: CGFloat = point.x == rect.minX ? length : -length
            let dy: CGFloat = point.y == rect.minY ? length : -length
            p.move(to: CGPoint(x: point.x + dx, y: point.y)); p.addLine(to: point)
            p.addLine(to: CGPoint(x: point.x, y: point.y + dy))
        }
        return p
    }
}
private struct FocusReticle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = RangefinderCorners().path(in: rect)
        p.move(to: CGPoint(x: rect.midX - 3, y: rect.midY)); p.addLine(to: CGPoint(x: rect.midX + 3, y: rect.midY))
        p.move(to: CGPoint(x: rect.midX, y: rect.midY - 3)); p.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 3))
        return p
    }
}
