# G.LENS Pro 0.4

Bản nâng cấp native iPhone, iOS 17 trở lên.

## Giao diện

Bố cục lấy cảm hứng từ Leica LUX: khung ngắm lớn, nút chụp trắng, Mode cạnh nút chụp; thanh EV có vạch chia và phản hồi khi đổi preset; bảng thiết lập nhanh dạng ô. Giữ tên G.LENS và không sử dụng logo, tài nguyên hay mã nguồn Leica.

- Chạm nút màu bên phải thanh EV để mở dải preset ngang. Khi camera đang chạy hoặc đã nhập ảnh, từng preset có ảnh thu nhỏ từ chính cảnh đang xem.
- Kéo thước EV để bù sáng; mở nút AUTO/M bên trái để chỉnh ISO, tốc độ, WB, MF và khóa AF/AE.
- Portrait dùng thanh mức bokeh; con số không giả khẩu độ quang học của iPhone.
- Nút MODE mở Photo/Pro/Portrait/HDR/Night/Pano/Doc/Video/Slow/Time-lapse/Long.
- Bảng màu → Hạt/màu/khung → Mở ảnh hoặc Mở DNG/Tệp. File không rời iPhone.

## Film

Sáu mô phỏng mới: Gold 200, Portra 400, Ektar 100, Fuji C200, HP5 400 và Cine 800T. Mỗi mô phỏng có đường cong kênh màu, bão hòa, mức hạt đề xuất và quầng sáng riêng. Chọn preset sẽ áp mức hạt/cường độ/tối viền gợi ý; các tinh chỉnh phơi sáng và WB của người dùng vẫn giữ.

Đây là bộ màu tự thiết kế theo cảm hứng film, chưa được hiệu chuẩn bằng các bản quét film thật và không phải LUT được cấp phép bởi Kodak, Fujifilm, Ilford hoặc Leica. Sáu bộ màu trước đó vẫn còn.

## Camera tính toán

HDR ghép ba mức sáng; Night ghép 3–12 ảnh; panorama ngang có kiểm tra chồng hình; theo nét mắt/mặt hoặc vùng chạm; tài liệu tự sửa phối cảnh; giải mã RAW/DNG được iOS hỗ trợ. Xem PRO_FEATURES_VI.md cho giới hạn độ phân giải và cách dùng.

## Trạng thái

Đã compile iPhoneOS thành công ở commit `16e6720a0f29c5b5817ef8b93c0b69b67450a2e5`. 12 kiểm tra toán học + 39 kiểm tra native simulator đều qua. Đã xem ảnh giao diện simulator. Chưa kiểm thử camera vật lý. Chi tiết tại `QA_STATUS_VI.txt`.

IPA 606.148 byte, native ARM64, iOS 17+. SHA256: `3b988350c967f31f94e94eca1860b8507b014206827aa322d9595701d1f81fb4`.

Không đạt 1:1 Xiaomi–Leica: còn thiếu Live Photo, multi-cam, video LUT, Dolby Vision/ACES, giao diện ngang và một số chức năng khác. Phần cứng và thuật toán riêng của Xiaomi không thể được tái tạo nguyên vẹn bằng app này.

IPA unsigned cần chữ ký/provisioning hợp lệ; bản cập nhật không xử lý lỗi đăng nhập Apple ID trong công cụ ký.
