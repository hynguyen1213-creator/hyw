import SwiftUI

private let controlRed = Color(red: 0.89, green: 0.19, blue: 0.15)
private let controlPanel = Color(red: 0.095, green: 0.10, blue: 0.098)

struct HardwareControls: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss
    @State private var isoDial = log2(100.0)
    @State private var shutterDial = log2(1.0 / 125)
    @State private var focus = 0.5
    @State private var kelvin = 5500.0
    @State private var ev = 0.0
    @State private var tint = 0.0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                liveReadings
                if camera.imported {
                    Label("Đang chỉnh ảnh đã nhập. Quay lại camera để điều khiển phần cứng.", systemImage: "photo")
                        .font(.system(size: 12)).lineSpacing(4).foregroundStyle(.white.opacity(0.45))
                        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Button(camera.aeLocked ? "AE-L •" : "Khoá AE") { camera.toggleAELock() }.disabled(camera.manualExposure)
                    Button(camera.afLocked ? "AF-L •" : "Khoá AF") { camera.toggleAFLock() }
                    Spacer()
                    Button("Auto tất cả") { camera.resetHardware() }
                }.font(.system(size: 12)).buttonStyle(.bordered).disabled(camera.imported || !camera.running)
                exposureControls
                focusControls
                whiteBalanceControls
                if !camera.mode.isMovie { fileControls }
                zoomControls
                Text("Thông số được áp vào camera đang chọn. Các chức năng không được phần cứng hỗ trợ sẽ bị mờ.")
                    .font(.system(size: 12)).lineSpacing(4).foregroundStyle(.white.opacity(0.25))
                    .padding(.horizontal, 2).padding(.bottom, 12)
            }.padding(.horizontal, 24).padding(.top, 31).padding(.bottom, 22)
        }
        .background(controlPanel.ignoresSafeArea()).foregroundStyle(.white)
        .tint(controlRed)
        .onAppear {
            isoDial = log2(clamp(Double(camera.currentISO), Double(camera.minISO), Double(camera.maxISO)))
            shutterDial = log2(clamp(camera.currentShutter, camera.minShutter, camera.maxShutter))
            ev = Double(camera.exposureBias)
            focus = Double(camera.focusPosition)
            kelvin = clamp(Double(camera.whiteBalanceKelvin), 2000, 12000)
            tint = Double(camera.whiteBalanceTint)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CAMERA CONTROL").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.white.opacity(0.3))
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("Điều khiển").font(.system(size: 27, weight: .light)).tracking(-0.9)
                    Text(".").font(.system(size: 27, weight: .light)).foregroundStyle(controlRed)
                }
                Text(camera.activeCameraName).font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    .frame(width: 31, height: 31).background(.white.opacity(0.05), in: Circle())
            }.accessibilityLabel("Đóng điều khiển camera")
        }.padding(.bottom, 3)
    }

    private var liveReadings: some View {
        HStack(spacing: 0) {
            reading("ISO", String(format: "%.0f", camera.currentISO))
            Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5, height: 26)
            reading("SHUTTER", speed(camera.currentShutter))
            Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5, height: 26)
            reading("MODE", camera.manualExposure ? "MANUAL" : "AUTO")
        }.padding(.vertical, 16).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    private var exposureControls: some View {
        controlGroup("Phơi sáng", symbol: "sun.max", mode: camera.manualExposure ? "MANUAL" : "AUTO") {
            Toggle("ISO & tốc độ thủ công", isOn: Binding(get: { camera.manualExposure }, set: { enabled in
                if enabled {
                    isoDial = log2(clamp(Double(camera.currentISO), Double(camera.minISO), Double(camera.maxISO)))
                    shutterDial = log2(clamp(camera.currentShutter, camera.minShutter, camera.maxShutter))
                }
                camera.setExposure(manual: enabled, iso: Float(pow(2, isoDial)), seconds: pow(2, shutterDial))
            })).disabled(!camera.supportsManual || camera.imported)
            if camera.manualExposure {
                sliderLabel("ISO", "\(Int(pow(2, isoDial)))")
                Slider(value: $isoDial, in: log2(Double(max(1, camera.minISO)))...log2(Double(max(camera.minISO + 1, camera.maxISO))))
                    .onChange(of: isoDial) { _, _ in exposure() }
                sliderLabel("Tốc độ màn trập", speed(pow(2, shutterDial)))
                Slider(value: $shutterDial, in: log2(max(0.000001, camera.minShutter))...log2(max(camera.minShutter + 0.000001, camera.maxShutter)))
                    .onChange(of: shutterDial) { _, _ in exposure() }
            } else {
                sliderLabel("Bù sáng", String(format: "%+.1f EV", ev))
                Slider(value: $ev, in: Double(camera.minEV)...Double(max(camera.minEV + 0.1, camera.maxEV)), step: 0.1)
                    .onChange(of: ev) { _, value in camera.setEV(Float(value)) }.disabled(camera.imported)
            }
        }
    }

    private var focusControls: some View {
        controlGroup("Lấy nét", symbol: "viewfinder", mode: camera.manualFocus ? "MF" : "AF") {
            Toggle("Lấy nét thủ công", isOn: Binding(get: { camera.manualFocus }, set: { camera.setFocus(manual: $0, position: Float(focus)) }))
                .disabled(!camera.supportsFocus || camera.imported)
            if camera.manualFocus {
                sliderLabel("Gần ↔ Vô cực", String(format: "%.2f", focus))
                Slider(value: $focus, in: 0...1).onChange(of: focus) { _, value in camera.setFocus(manual: true, position: Float(value)) }
            }
        }
    }

    private var whiteBalanceControls: some View {
        controlGroup("Cân bằng trắng", symbol: "thermometer.medium", mode: camera.manualWB ? "KELVIN" : "AWB") {
            Toggle("WB thủ công", isOn: Binding(get: { camera.manualWB }, set: { camera.setWB(manual: $0, kelvin: Float(kelvin), tint: Float(tint)) }))
                .disabled(!camera.supportsWB || camera.imported)
            if camera.manualWB {
                sliderLabel("Nhiệt độ", "\(Int(kelvin)) K")
                Slider(value: $kelvin, in: 2000...12000, step: 50).onChange(of: kelvin) { _, value in camera.setWB(manual: true, kelvin: Float(value), tint: Float(tint)) }
                sliderLabel("Tint xanh / tím", String(format: "%+.0f", tint))
                Slider(value: $tint, in: -150...150).onChange(of: tint) { _, value in camera.setWB(manual: true, kelvin: Float(kelvin), tint: Float(value)) }
                HStack { ForEach([3200.0, 4300, 5600, 6500], id: \.self) { value in Button("\(Int(value))K") { kelvin = value }.font(.system(size: 12)).buttonStyle(.bordered) } }
            }
        }
    }

    private var fileControls: some View {
        controlGroup("Định dạng ảnh", symbol: "doc", mode: camera.rawEnabled ? "RAW+" : "JPEG") {
            Toggle("Ảnh màu + DNG gốc", isOn: $camera.rawEnabled)
                .disabled(!camera.supportsRaw || camera.imported || camera.capturing || camera.options.sequence == .bracket || camera.mode == .longExposure)
            Text(camera.rawLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            Text("DNG giữ dữ liệu camera, chưa áp màu hay khung G.LENS. JPEG/HEIF được xử lý riêng.")
                .font(.system(size: 12)).lineSpacing(4).foregroundStyle(.white.opacity(0.25))
        }
    }

    private var zoomControls: some View {
        controlGroup("Zoom số", symbol: "plus.magnifyingglass", mode: "CROP") {
            sliderLabel("Camera đang chọn", String(format: "%.1f×", camera.zoom))
            Slider(value: $camera.zoom, in: 1...max(1.01, camera.maxZoom))
                .onChange(of: camera.zoom) { _, value in camera.setZoom(value) }.disabled(camera.imported)
        }
    }

    private func reading(_ title: String, _ value: String) -> some View {
        VStack(spacing: 7) {
            Text(title).font(.system(size: 6, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(.white.opacity(0.3))
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
        }.frame(maxWidth: .infinity)
    }
    private func controlGroup<Content: View>(_ title: String, symbol: String, mode: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .light)).foregroundStyle(.white.opacity(0.4))
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(mode).font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(0.7)
                    .foregroundStyle(mode == "MANUAL" || mode == "MF" || mode == "KELVIN" || mode == "RAW+" ? controlRed : .white.opacity(0.25))
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
            content().font(.system(size: 12)).tint(controlRed)
        }.padding(16).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.055), lineWidth: 0.5))
    }
    private func sliderLabel(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
        }
    }
    private func exposure() {
        if camera.manualExposure { camera.setExposure(manual: true, iso: Float(pow(2, isoDial)), seconds: pow(2, shutterDial)) }
    }
    private func speed(_ value: Double) -> String { value > 0 && value < 1 ? "1/\(Int((1 / value).rounded()))s" : String(format: "%.1fs", value) }
    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { max(low, min(high, value)) }
}
