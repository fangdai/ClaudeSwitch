# Claude Switch

Chuyển account **Claude Desktop và Claude Code CLI** trên Windows. Công cụ tự nhận diện phần đã cài và chỉ hiện mục tương ứng. Hai phần có danh sách account riêng; phần Desktop vẫn đồng bộ session giữa hai account. Không cần cài thêm thư viện (Windows PowerShell 5.1 có sẵn).

## Claude CLI

1. Mở mục **CLI**. Nếu vừa cài Claude CLI khi công cụ đang mở, bấm **Quét lại**.
2. Account CLI đã đăng nhập được lưu tự động. Nếu chưa đăng nhập, bấm **Đăng nhập CLI**; công cụ mở `claude auth login --claudeai` trong cửa sổ riêng. Bạn tự đăng nhập trong trình duyệt hoặc nhập mã vào cửa sổ CLI nếu được yêu cầu.
3. Bấm **Thêm account CLI** để đăng nhập account khác. Đăng nhập mới dùng thư mục riêng và không đăng xuất account hiện tại.
4. Thoát các phiên Claude CLI đang chạy rồi bấm **Chuyển CLI sang ...**. Mở một phiên CLI mới bằng lệnh `claude` hoặc nút **Mở Claude CLI** để dùng account đã chọn.

Chỉ thay thông tin OAuth và account tương ứng trong cấu hình CLI; giữ nguyên settings, lịch sử, dự án và đăng nhập MCP khác. Công cụ không tự đóng các phiên CLI đang chạy. Nếu CLI dùng API key, token qua biến môi trường hoặc nhà cung cấp bên ngoài, giao diện giải thích cấu hình đang ghi đè và không giả vờ chuyển account OAuth.

Account CLI được lưu bằng DPAPI trong `cli\profiles\<id>\auth.bin`. Trước khi chuyển, hai file cấu hình được sao lưu mã hóa trong `cli\backups`; lỗi khi ghi sẽ khôi phục cả hai. Tài khoản Desktop không tự trở thành đăng nhập CLI: cần đăng nhập CLI một lần cho mỗi account.

Tham khảo [đăng nhập Claude Code](https://code.claude.com/docs/en/authentication) và [lệnh CLI](https://code.claude.com/docs/en/cli-reference).

## Cài đặt

1. Bấm đúp **`Cai dat.bat`**.
2. Một shortcut **Claude Switch** xuất hiện trên Desktop. Phím tắt mở nhanh: **Ctrl + Alt + C**.

Gỡ cài đặt: bấm đúp `Go cai dat.bat` (mặc định giữ lại các account đã lưu).

## Dùng lần đầu

1. Mở Claude và đăng nhập account thứ nhất, rồi mở Claude Switch. Account này được lưu tự động.
2. Bấm **Thêm account thứ hai**. Claude sẽ đóng rồi mở lại ở màn hình đăng nhập, bạn đăng nhập account còn lại. Claude Switch tự nhận ra và lưu lại. Việc này **không** đăng xuất trên máy chủ nên không làm mất đăng nhập đã lưu.
3. Từ giờ bấm **Chuyển sang ...** là xong. Nếu đổi ý giữa chừng, bấm **Hủy, quay lại account cũ**.

## Lưu ý quan trọng

- Khi chuyển, Claude **đóng và mở lại**. Việc đang chạy (kể cả session Claude Code đang làm dở) sẽ bị dừng. Hãy chuyển lúc rảnh.
- **Đừng chạy Claude Switch từ bên trong một session Claude Code của chính Claude Desktop**: đóng Claude sẽ tắt luôn session đó.
- Đóng cửa sổ chỉ thu xuống khay hệ thống (góc phải thanh tác vụ). Chuột phải vào biểu tượng để chuyển nhanh hoặc **Thoát**.
- Công tắc **Hiện session ở cả 2 account** sao chép (nguyên văn, không sửa) file thông tin session sang account kia. Session nào bạn đã xóa sẽ không bị tạo lại. Menu **...** có **Gỡ session đã sao chép** (chỉ gỡ bản chưa bị sửa).

## Dữ liệu nằm ở đâu

`%LOCALAPPDATA%\ClaudeSwitch`

| Thư mục / file | Nội dung |
|---|---|
| `profiles\<id>\auth.bin` | Đăng nhập + cookie, **mã hóa DPAPI** (chỉ tài khoản Windows này đọc được) |
| `profiles\<id>\meta.json` | Tên, email (không có bí mật) |
| `backups\` | 10 bản sao lưu config/cookie gần nhất trước mỗi lần chuyển (menu **...** > Mở thư mục sao lưu) |
| `logs\` | Nhật ký các bước (không ghi token) |

Nếu có lỗi sau khi sao lưu, công cụ tự khôi phục lại cấu hình cũ và mở lại Claude.

## Cho người kiểm thử

`Tests\Run-Tests.ps1` chạy toàn bộ bài kiểm tra trên **dữ liệu giả** (`-NoAppControl`, không đụng Claude thật):

```
powershell -NoProfile -ExecutionPolicy Bypass -File Tests\Run-Tests.ps1 -Scratch <thư mục tạm>
```

Kiểm tra CLI bằng dữ liệu giả, không đăng nhập thật:

```
powershell -NoProfile -ExecutionPolicy Bypass -STA -File Tests\Run-CliTests.ps1 -Scratch <thư mục tạm> -VerifyGui
```
