# G.LENS iOS · 0.2.0 beta

Camera iPhone viết bằng SwiftUI + AVFoundation, xử lý màu bằng Core Image ngay trên máy. Có project Xcode đầy đủ; không cần API key, không có máy chủ xử lý ảnh, không tích hợp quảng cáo.

**IPA unsigned đã build thành công bằng Xcode 26.6 trên GitHub macOS.** Build [39903900318](https://github.com/hynguyen1213-creator/hyw/actions/runs/39903900318) từ commit `d9d0f5d7f9f03aada29bf322d715f8525529b4f1` đã archive, đóng gói và tải artifact thành công. Đã kiểm tra checksum, executable Mach-O arm64 cho iPhone và iOS tối thiểu 17.0. Chưa có chứng chỉ/provisioning profile để ký cài trực tiếp; chưa thử camera native trên iPhone. Bản web đã được chạy thử riêng. Màu tự xây dựng, không phải LUT Leica chính hãng hoặc cam kết giống Xiaomi 90–100%.


## Bản 0.2: giao diện camera mới và đường build IPA

Màn hình chụp được viết lại: nền đen, kính ngắm lớn, nút chụp rõ, không cuộn qua các thanh chỉnh. Chất ảnh, tinh chỉnh màu và phần cứng mở bằng các bảng kéo lên. Đã sửa trường hợp mất JPEG khi ghi DNG thất bại và đưa thông số EXIF thực vào khung ảnh khi có.

Có hai chế độ build trong `scripts/build_ipa.sh`:

- `unsigned`: Xcode phải biên dịch/archive thành ứng dụng Mach-O thật trước rồi mới đóng IPA; file vẫn cần được ký để cài.
- `signed`: xuất IPA bằng chứng chỉ và provisioning profile đã có, rồi kiểm tra chữ ký. Profile cho cài trực tiếp phải còn hạn và có thiết bị được phép; profile chỉ dành App Store không đáp ứng bước này.

Workflow `.github/workflows/ios-ipa.yml` chạy bằng máy macOS của GitHub Actions. Push vào `main` tự build IPA unsigned; có thể mở Actions → G.LENS iOS IPA → Run workflow để chọn chế độ ký. Chưa có chứng chỉ thì chọn `unsigned`; file đó cần ký trước khi cài.

Khi đã có chứng chỉ/profile, thêm vào GitHub Actions Secrets: `IOS_P12_BASE64`, `IOS_P12_PASSWORD`, `IOS_PROFILE_BASE64`. Không commit file chứng chỉ/private key và không gửi mật khẩu Apple ID qua chat. Bundle ID mặc định là `com.gstudio.glens`; nếu profile khác thì đặt repository variable `IOS_BUNDLE_ID` tương ứng. Chọn `signed` để build có ký.

Nếu không có chứng chỉ phân phối, có thể ký cài IPA đã build trên máy Windows qua Apple ID bằng AltStore Classic/AltServer. Đó là bước ký cài riêng, không phải bấm một file IPA chưa ký là chạy. Tham khảo chính thức: https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows

Chỉ khi workflow thực sự chạy xong và artifact đã được tải/kiểm tra mới xác nhận có IPA. Tình trạng build thực tế được báo trong phiên làm việc, không suy ra từ việc có script. Workflow chạy khi push `main` hoặc bấm Run và giới hạn 35 phút.

## Cài bản native lên iPhone

1. Dùng máy Mac có Xcode 16 trở lên; iPhone iOS 17 trở lên.
2. Giải nén, mở `GLens.xcodeproj`.
3. Trong target GLens → Signing & Capabilities: chọn Team của mày, bật Automatically manage signing. Đổi Bundle Identifier `com.gstudio.glens` nếu cần để tránh trùng.
4. Kết nối iPhone với Mac, chọn iPhone làm thiết bị chạy. Tin cậy máy Mac và bật Developer Mode trên iPhone khi Xcode yêu cầu.
5. Bấm Run. Khi mở app, chọn **Cho phép Camera**. Nếu đã từ chối, dùng nút **Mở Cài đặt iPhone** trong app để cấp lại.
6. Khi muốn lưu ra thư viện hệ thống: mở ảnh trong app → **Lưu vào Ảnh** → cho phép thêm ảnh. PhotosPicker nhập ảnh không đòi quyền đọc cả thư viện.

Để phân phối bằng TestFlight/App Store hoặc tạo IPA cài được, phải build trên macOS và ký theo tài khoản/cách phân phối Apple tương ứng. App web không thể cấp thay các quyền camera native.

## API và các tính năng đã viết

- AVFoundation: `requestAccess(for: .video)` xin quyền; không dùng Camera2 vì đó là API Android.
- Tìm camera vật lý Chính/Siêu rộng/Tele/Trước đang có trên thiết bị; không giả định mọi iPhone có đủ ống kính.
- Đọc `activeFormat`, ISO min/max, min/max exposure duration và maximum zoom trước khi cấu hình.
- ISO và tốc độ: `setExposureModeCustom(duration:iso:)`, tự giới hạn giá trị. Ảnh manual dùng `photoQualityPrioritization = .speed` theo yêu cầu của Apple để giữ thông số phơi sáng.
- AF/MF và tap-to-focus: `setFocusModeLocked(lensPosition:)`, `focusPointOfInterest`. Toạ độ được đổi theo crop và hướng portrait; cần xác minh thực tế trên từng camera, đặc biệt camera trước.
- AWB/WB: nhiệt độ Kelvin → white balance gains; chuẩn hoá gains trong khoảng phần cứng chấp nhận trước khi khoá WB.
- Bù sáng EV dùng phần cứng ở chế độ tự động. Zoom số dùng `videoZoomFactor` trên camera đang chọn.
- Tắt nút khi camera không hỗ trợ manual exposure, manual focus, WB lock hoặc RAW.
- RAW/Apple ProRAW: chỉ dùng format mà `availableRawPhotoPixelFormatTypes` thực sự trả về. DNG giữ nguyên dữ liệu ảnh gốc; JPEG áp màu được lưu riêng. DNG có thể không phản ánh crop/khung của JPEG.
- `AVCaptureVideoDataOutput` + Core Image xem trước 15 fps. `AVCapturePhotoOutput` chụp ảnh tĩnh theo kích thước tối đa camera cung cấp; JPEG màu giới hạn cạnh ảnh trước khi thêm khung ở 6000 px để giảm bộ nhớ.
- Sáu look: Authentic, Vibrant, M9 CCD, M3 Mono, Classic Gold, Noir. Có cường độ, grain, vignette, khung chữ ký, so sánh ảnh gốc khi giữ nút GỐC.
- Tỷ lệ portrait 4:3, 3:2, 1:1, 16:9; lưới bố cục; hẹn giờ 3/10 giây.
- Nhập ảnh bằng PhotosPicker, gallery trong app, chia sẻ JPEG/DNG, lưu vào Photos theo quyền add-only. JPEG giữ EXIF khả dụng và cập nhật kích thước/hướng sau xử lý.
- Camera dừng khi app vào nền; quan sát interruption và media services reset. Ngăn chụp đè, đổi camera trong lúc chụp và hẹn giờ lặp.

## Cấu trúc

- `CameraController.swift`: cấp quyền, session, chọn phần cứng, điều khiển và chụp.
- `ColorEngine.swift`: màu, crop, grain/vignette, khung và mã hoá JPEG/EXIF.
- `CameraScreen.swift`: màn hình camera, nhập ảnh, look, hẹn giờ.
- `HardwareControls.swift`: bảng điều khiển phần cứng.
- `CaptureStore.swift`: lưu JPEG/DNG nội bộ và PhotoKit.
- `GalleryScreen.swift`: thư viện, xem ảnh, chia sẻ và lưu ra Photos.

Ảnh nội bộ nằm trong Documents/Captures, có thể lấy bằng Files/Finder File Sharing. Xoá app sẽ xoá ảnh nội bộ của app; xuất các ảnh cần giữ vào Photos hoặc Files. Không có chức năng tự tải lên mạng.

## Xác minh trước phát hành

Trên Mac chạy `./verify_macos.sh` để build iOS không ký. Sau đó chạy trực tiếp trên iPhone và kiểm tra:

1. Từ chối/cho phép camera; thay quyền trong Settings; đóng/mở app.
2. Chuyển từng camera. Nút không hỗ trợ phải bị mờ, không crash khi đổi lens.
3. ISO thấp/cao, shutter nhanh/chậm: chụp rồi đối chiếu ISO/ExposureTime trong EXIF JPEG. Kiểm tra phơi sáng trên ảnh thật, không chỉ preview.
4. AF/MF gần/vô cực; tap-to-focus; WB auto và 2500/5500/9000 K.
5. Chụp JPEG; bật RAW trên từng camera có hỗ trợ; mở DNG ở Lightroom/Photos để kiểm tra dữ liệu thực.
6. Bốn tỷ lệ; camera trước không bị xoay ngược; vị trí nét đúng khi crop.
7. Xuất Photos và chia sẻ khi quyền add-only được cho phép/từ chối; ảnh gốc và RAW vẫn ở app khi lưu Photos thất bại.
8. Hẹn giờ rồi vào nền, cuộc gọi/ngắt camera, chụp nhiều ảnh liên tiếp, bộ nhớ thấp và máy nóng.
9. Đánh giá màu da, đỏ, xanh lá, vùng sáng và thiếu sáng bằng ảnh thực. Điều chỉnh look sau khi có bộ ảnh đối chiếu; không thể xác nhận màu giống Leica chỉ qua giao diện.

## Tài liệu tham chiếu chính hãng

- https://developer.android.com/media/camera/camera2
- https://developer.apple.com/documentation/avfoundation/avcapturedevice
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)
- https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawenabled
- https://www.mi.com/global/product/leica-leitzphone-powered-by-xiaomi/
