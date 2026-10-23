# G.LENS Pro 0.4 — phạm vi thay đổi đã triển khai

**Đã được người dùng cho phép công bố và đã compile iPhoneOS.** Xem RELEASE_0.4_VI.md và QA_STATUS_VI.txt cho trạng thái bản giao. Tài liệu này ghi phạm vi thay đổi đã được duyệt.

Repository: repository **công khai** `hynguyen1213-creator/hyw`, nhánh `main`. Đưa thay đổi lên đó sẽ khiến mọi người xem/tải được mã nguồn và kích hoạt workflow macOS để build IPA + chạy simulator. Không upload Apple ID, mật khẩu, chứng chỉ hoặc provisioning profile trong thay đổi này.

| Phần mới | File chính | Hành vi |
|---|---|---|
| Ghép HDR và Night | `GLens/ImageFusion.swift`, `GLens/AdvancedCapture.swift` | Căn chỉnh ảnh, loại khung không khớp, ghép SDR hoặc giảm nhiễu; giữ ảnh nguồn nếu ghép không đủ |
| Panorama | `GLens/ImageFusion.swift`, `GLens/AdvancedCapture.swift` | Lia ngang một hướng, hướng dẫn chồng hình, ghép 2–18 khung; không tạo ảnh nếu không đủ khung hợp lệ |
| Theo mắt/chủ thể | `GLens/SubjectTracker.swift` | Vision chọn điểm mắt hoặc theo vùng chạm, cập nhật điểm AF; tôn trọng MF và khóa AF |
| Chụp tài liệu | `GLens/AdvancedCapture.swift` | Nhận bốn góc, sửa phối cảnh, tùy chọn đen trắng |
| RAW import | `GLens/CameraController.swift`, `GLens/CameraScreen.swift` | Mở từ Files, CIRAWFilter giải mã RAW được iOS hỗ trợ, giữ DNG gốc khi có |
| Giao diện và lưu thiết lập | `GLens/CameraScreen.swift`, `GLens/ProPanels.swift`, `GLens/ProTypes.swift` | Mode HDR/NIGHT/PANO/DOC, khung tracking, tùy chọn số ảnh, migrate cấu hình cũ |
| Kiểm thử | `GLens/AdvancedChecks.swift`, `GLens/SimulatorChecks.swift` | Phép thử bằng ảnh tổng hợp; kết quả bản giao tại QA_STATUS_VI.txt |
| Đóng gói | `GLens/Info.plist`, project và `scripts/` | Phiên bản 0.4.0/build 4; IPA được đặt rõ là unsigned nếu chưa có chữ ký |

Phạm vi công bố là các file được liệt kê trong `git status --short` của repo; không thêm dependency hay máy chủ tải ảnh. Xem `PRO_FEATURES_VI.md` để biết giới hạn từng chế độ và phần còn thiếu.

Chưa đạt 1:1: Live Photo, Dolby Vision/ACES, multi-cam, video LUT, landscape, voice shutter, Super Moon, beauty, Master Lens; các thuật toán/hiệu ứng độc quyền chưa có. Phần cứng cảm biến và ống kính Xiaomi không thể được bổ sung cho iPhone bằng code.

Quy trình build: upload đúng bản thay đổi, compile iPhoneOS, sửa lỗi nếu có, chạy các test cũ và mới + kiểm tra ảnh giao diện; chỉ giao IPA 0.4 sau khi có kết quả build thực. IPA unsigned vẫn cần ký hợp lệ trước khi cài.

Bổ sung theo yêu cầu tiếp theo: UX/UI lấy cảm hứng Leica LUX và sáu preset film. Mã nằm trong CameraScreen.swift, LuxControls.swift, FilmProfiles.swift và ColorEngine.swift.
