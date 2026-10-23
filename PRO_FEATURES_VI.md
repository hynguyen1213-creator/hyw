# G.LENS Pro 0.3 — camera iPhone

Ứng dụng native SwiftUI + AVFoundation, iOS 17 trở lên. Nâng cấp từ G.LENS 0.2. Mã nguồn có trên GitHub; bản IPA vẫn cần chữ ký và provisioning hợp lệ để cài. Build mới không giải quyết lỗi xác thực Apple ID của Sideloadly/3uTools.

## Đã triển khai

| Nhóm | Chức năng | Cách dùng / giới hạn |
|---|---|---|
| Camera | Camera trước/sau, siêu rộng/tele khi có, pinch zoom | Chọn camera vật lý trong kính ngắm; các mức × trong cùng camera là crop số |
| Phơi sáng | Auto hoặc ISO + tốc độ thủ công, EV, đồng hồ lệch sáng, khoá AE | Nút PRO; giới hạn lấy trực tiếp từ camera đang chọn |
| Lấy nét | Chạm chọn điểm, AF/MF, khoá AF, focus peaking | Thanh MF biểu diễn vị trí lens 0–1, không giả số mét |
| WB | Auto, Kelvin 2000–12000, tint xanh/tím, preset nhiệt độ | Gain thực được giới hạn theo camera |
| Hỗ trợ | Histogram RGB, zebra chỉnh ngưỡng, peaking chỉnh ngưỡng, thước cân bằng, lưới 1/3/vàng/ô vuông, safe frame | Histogram/zebra đo ảnh xem trước; peaking là biên tương phản |
| File | JPEG/HEIF, DNG hoặc Apple ProRAW khi hỗ trợ, chọn độ phân giải, giữ ảnh gốc | DNG chưa áp màu/crop/khung; ảnh màu xuất riêng. Độ phân giải cao đọc từ active format, không nội suy lên 48/200 MP |
| Chụp | Hẹn giờ 3/5/10s, flash auto/on/off, torch, chụp liên tiếp, cách quãng 2–99 ảnh | Chụp liên tiếp chờ ảnh trước hoàn tất; không hứa tốc độ burst cố định |
| Bracket | 3 ảnh ±0.5/1/2 EV, auto hoặc manual | Lưu ba ảnh riêng, không hợp nhất HDR; không flash/RAW trong chế độ này |
| Phơi ghép | Nước mịn hoặc vệt sáng 1–30 giây | Ghép luồng video trên tripod; tối đa cạnh dài 1920 px, không phải bulb cảm biến hay RAW |
| Chân dung | Tách người bằng Vision, xoá phông khi lưu | Chỉ dành cho người, chưa xem trước xoá phông; không mô phỏng quang học ống kính Leica |
| Màu ảnh | Authentic, Vibrant, M9 CCD, M3 Mono, Gold, Noir; màu, tương phản, nhiệt độ, tint, shadows/highlights, grain, vignette, sharpness | Bộ màu tự viết lấy cảm hứng; không phải LUT Leica chính hãng |
| Preset | Lưu và gọi lại màu + ISO/tốc độ/focus/WB/EV, xoá preset | Cấu hình được giới hạn lại theo camera đang dùng |
| Video Pro | 1080p/4K; 24/25/30/50/60/120 fps theo thiết bị, mic, chống rung | HEVC nếu đầu ra hỗ trợ, H.264 dự phòng; chưa áp bộ màu ảnh vào video |
| HDR / Log | HDR HLG / Apple Log khi format tương thích | Chỉ hiện các format 10-bit được camera công bố. HLG không phải Dolby Vision |
| Slow motion | 120/240 fps nếu có; xuất chậm về 30 fps | Không âm thanh; nếu xuất chậm lỗi giữ video tốc độ cao gốc |
| Time-lapse | Chụp mỗi 0.25–10s, xuất 1080p dọc / 30 fps | Không âm thanh |
| Thư viện | Ảnh/video, phát video, xem ảnh gốc, chia sẻ, lưu Photos, xoá có xác nhận | File lưu trong app trước; tự lưu Photos là tuỳ chọn |

## Khác biệt với Xiaomi–Leica

Không thể đưa phần cứng cảm biến 1 inch, tele quang 75–100 mm, 200 MP hoặc vòng zoom cơ của Xiaomi vào iPhone bằng phần mềm. Màu, HDR, ProFocus, bokeh, Leica Essential, chứng thực C2PA và các thuật toán độc quyền của hãng không được sao chép.

Chưa triển khai: panorama tự ghép, Live Photo, theo mắt/chủ thể, ghép HDR/đêm có căn chỉnh chống rung, Dolby Vision/ACES, quay nhiều camera đồng thời, video LUT, chỉnh sửa DNG và giao diện quay ngang. Đây là bản Pro beta có những chức năng trong bảng, không phải bản sao đầy đủ 1:1 của toàn bộ ứng dụng Xiaomi.

## Kiểm thử

- Kiểm tra cú pháp shell, plist và cấu trúc project trước khi build.
- CI chạy 12 kiểm tra toán học cho crop/điểm lấy nét/mirroring/luma/bracket/time.
- CI archive bằng SDK iPhoneOS, kiểm tra Mach-O ARM64, ZIP và SHA256 rồi đóng IPA.
- CI build simulator, mở camera / Pro / thiết lập và chụp giao diện. Kiểm tra pipeline JPEG/HEIF, EXIF, ảnh gốc, sidecar RAW, histogram, phơi ghép và file time-lapse bằng ảnh mẫu tổng hợp; không dùng camera giả để báo đã thử phần cứng.
- Camera vật lý, RAW/ProRAW, flash, mic, HLG/Log, thermal và vòng đời khi khóa máy cần kiểm tra trên iPhone thật. Simulator không chứng minh các tính năng này hoạt động trên phần cứng.

## Kiểm tra nhanh sau khi cài

1. Cấp quyền camera, chụp JPEG Auto; mở thư viện và lưu vào Photos.
2. PRO: chỉnh ISO/tốc độ; kiểm tra EXIF ảnh gốc. Chạm lấy nét, thử MF và peaking.
3. Chọn từng camera thật; kiểm tra nút RAW, flash và menu video thay đổi theo khả năng.
4. Chụp HEIF + DNG nếu hỗ trợ; kiểm tra file trong Chia sẻ/Files. BKT phải có ba ảnh riêng.
5. Quay 10 giây SDR có mic; phát lại, kiểm tra tiếng và lưu vào Photos. Thử slow motion/time-lapse sau đó.
6. Log/HLG chỉ kiểm tra khi menu có; mở video trong ứng dụng hỗ trợ quản lý màu.
7. Thử về nền / quay lại, đổi camera, từ chối quyền mic/Photos, hết chỗ lưu.
8. Phơi ghép dùng tripod; chân dung kiểm tra mép tóc và bật so sánh ảnh gốc.

## Tài liệu tham chiếu

- Xiaomi: https://www.mi.com/global/support/faq/details/KA-667490/
- Xiaomi thông số: https://www.mi.com/vn/product/xiaomi-17-ultra/specs/
- Apple RAW: https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats
- Apple bracket: https://developer.apple.com/documentation/avfoundation/capturing-a-bracketed-photo-sequence
- Apple video formats: https://developer.apple.com/documentation/avfoundation/recording-movies-in-alternative-formats
