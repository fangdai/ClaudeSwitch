# Claude Switch

Chuyển nhanh giữa nhiều account **Claude Desktop** và **Claude Code CLI**, xem usage (giới hạn 5 giờ / 7 ngày) của từng account. Chạy trên **Windows, macOS và Linux**: một file duy nhất (~8 MB), không cần cài Node, Python hay .NET.

- Viết bằng Go. Mở trong khoảng 0,2 giây, dùng khoảng 30 MB RAM.
- Cửa sổ ứng dụng thật, dùng WebView có sẵn của hệ điều hành: **WebView2** trên Windows 10/11, **WKWebView** trên macOS. Không mở trình duyệt, nên không có profile, tiện ích mở rộng, đồng bộ hay thanh địa chỉ. Mở lại khi cửa sổ đang mở thì cửa sổ cũ được đưa lên trước. Đóng cửa sổ là thoát hẳn.
- Linux (hoặc Windows thiếu WebView2 Runtime): giao diện mở trong cửa sổ Chrome/Edge dạng ứng dụng, dùng profile riêng và tắt tiện ích mở rộng.
- Dữ liệu đăng nhập được mã hóa theo tài khoản người dùng của máy. Token không bao giờ được ghi vào log hay hiện ra màn hình.

## Tải về

Vào trang **Releases** của repo và tải gói đúng máy:

| Máy | File |
|---|---|
| Windows 10/11 (Intel/AMD) | `ClaudeSwitch-<phiên bản>-windows-x64.zip` |
| Windows trên ARM | `ClaudeSwitch-<phiên bản>-windows-arm64.zip` |
| macOS chip Apple (M1–M4…) | `ClaudeSwitch-<phiên bản>-macos-apple-silicon.zip` |
| macOS chip Intel | `ClaudeSwitch-<phiên bản>-macos-intel.zip` |
| Linux x64 | `ClaudeSwitch-<phiên bản>-linux-x64.tar.gz` |
| Linux ARM64 | `ClaudeSwitch-<phiên bản>-linux-arm64.tar.gz` |

`SHA256SUMS.txt` có mã kiểm tra của từng gói.

## Cài đặt

### Windows

1. Giải nén file zip.
2. Bấm đúp **`Cai dat.cmd`**. Công cụ chép ứng dụng vào `%LOCALAPPDATA%\ClaudeSwitch\app`, tạo shortcut **Claude Switch** trên Desktop và Start Menu, rồi mở ứng dụng.
3. Phím tắt mở nhanh: **Ctrl + Alt + C**.

Không cần quyền admin. Nếu muốn dùng mà không cài, chỉ cần bấm đúp `claude-switch.exe`.

> Nâng cấp từ bản PowerShell cũ: account đã lưu được dùng tiếp ngay, không cần đăng nhập lại. Chạy `Cai dat.cmd` để shortcut cũ trỏ sang bản mới.

### macOS

1. Giải nén file zip, kéo **Claude Switch.app** vào thư mục **Applications**.
2. Lần đầu mở: **chuột phải → Open → Open**. Ứng dụng chưa được Apple ký nên macOS hỏi lại một lần. Nếu macOS báo app "bị hỏng", chạy lệnh dưới đây rồi mở lại:

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Switch.app"
```

3. Lần đầu lưu account, macOS có thể hỏi quyền truy cập **Keychain**: bấm **Always Allow**.

Muốn dùng lệnh `claude-switch` trong Terminal:

```bash
"/Applications/Claude Switch.app/Contents/MacOS/claude-switch" install
```

### Linux

```bash
tar -xzf ClaudeSwitch-*-linux-x64.tar.gz
```

```bash
./claude-switch/install.sh
```

Lệnh trên chép file vào `~/.local/bin/claude-switch` và thêm **Claude Switch** vào menu ứng dụng. Claude Desktop chưa có bản chính thức cho Linux, nên trên Linux công cụ dùng cho Claude Code CLI và xem usage.

## Sử dụng

### Claude Desktop (Windows, macOS)

1. Mở Claude, đăng nhập account thứ nhất, rồi mở Claude Switch. Account này được **lưu tự động**.
2. Bấm **Thêm account thứ hai**. Claude đóng rồi mở lại ở màn hình đăng nhập; bạn đăng nhập account còn lại. Claude Switch tự nhận ra và lưu account đó. Việc này **không** đăng xuất trên máy chủ, nên đăng nhập đã lưu vẫn dùng được.
3. Từ đó về sau chỉ cần bấm **Chuyển sang …**. Nếu đổi ý giữa chừng, bấm **Hủy, quay lại account cũ**.

Lưu ý:
- Khi chuyển, Claude sẽ **đóng và mở lại**. Việc đang chạy trong Claude (kể cả session Claude Code) bị dừng, nên hãy chuyển lúc rảnh. Có session vừa hoạt động thì công cụ cảnh báo trước.
- **Đừng chạy Claude Switch từ bên trong một session Claude Code của Claude Desktop**: đóng Claude sẽ tắt luôn session đó.
- Menu **⋯** có:
  - **Hiện session ở mọi account**: sao chép nguyên văn session Claude Code sang account kia. Session bạn đã xóa sẽ không bị tạo lại.
  - **Gỡ session đã sao chép**: chỉ gỡ những bản chưa bị sửa.
  - Mở thư mục sao lưu và mở nhật ký.

### Claude Code CLI (Windows, macOS, Linux)

1. Mở tab **CLI**. Account CLI đang đăng nhập được lưu tự động.
2. Bấm **Thêm account CLI**. Một cửa sổ terminal mở `claude auth login`, đăng nhập vào thư mục riêng nên account hiện tại không bị đăng xuất. Đăng nhập xong, account mới tự được lưu và chọn.
3. Thoát các phiên `claude` đang chạy, rồi bấm **Chuyển CLI sang …**. Mở phiên mới bằng lệnh `claude` hoặc nút **Mở Claude CLI**.

Công cụ chỉ thay thông tin đăng nhập OAuth của CLI. Settings, lịch sử, dự án và đăng nhập MCP khác được giữ nguyên.

Công cụ không chuyển và giải thích lý do khi CLI dùng:
- biến môi trường `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`…;
- `apiKeyHelper`;
- Bedrock, Vertex hoặc Foundry.

**Về lỗi "2 account cùng usage":** các phiên Claude Code chạy bên trong Claude Desktop dùng chung file `~/.claude.json` với CLI, và có thể ghi tên account Desktop vào đó. Claude Switch xác định account CLI bằng **chính token**: so mã băm đã biết, hoặc hỏi máy chủ một lần. Tên trong file cấu hình không được tin. Nếu một profile lưu nhầm token của account khác, nó được chuyển sang file `auth.wrong-*.bin` (không xóa) và account đó hiện **Cần đăng nhập lại**.

### Usage

Mỗi thẻ account hiện phần trăm **đã dùng** của cửa sổ 5 giờ, 7 ngày (và theo model nếu có), kèm giờ reset. Công cụ tự cập nhật khoảng 3 phút một lần khi cửa sổ đang mở. Bấm **Cập nhật usage** để lấy ngay; mỗi account được kiểm tra tối đa 1 lần mỗi phút.

- Usage lấy trực tiếp bằng đăng nhập CLI của account đó. Token của account chưa được chọn sẽ tự làm mới khi cần.
- Nếu không lấy trực tiếp được, thẻ hiện số liệu Claude Desktop đã ghi nhận cho đúng organization, có dòng **Dữ liệu lưu lúc …**.
- Khi máy chủ giới hạn lượt kiểm tra, công cụ đợi đúng thời gian máy chủ yêu cầu rồi mới thử lại.

### Dòng lệnh

```
claude-switch                      mở cửa sổ ứng dụng
claude-switch status               in trạng thái (JSON)
claude-switch switch <account>     chuyển Claude Desktop (tên, email hoặc mã)
claude-switch cli-switch <account> chuyển Claude Code CLI
claude-switch usage [--force]      cập nhật và in usage
claude-switch install              tạo shortcut / mục trong menu ứng dụng
claude-switch uninstall [--purge]  gỡ shortcut (--purge xóa cả account đã lưu)
```

## Dữ liệu nằm ở đâu

| Hệ điều hành | Thư mục | Mã hóa account đã lưu |
|---|---|---|
| Windows | `%LOCALAPPDATA%\ClaudeSwitch` | DPAPI của tài khoản Windows |
| macOS | `~/Library/Application Support/ClaudeSwitch` | AES-256-GCM, khóa trong Keychain |
| Linux | `~/.local/share/ClaudeSwitch` | AES-256-GCM, khóa trong file `.profile-key` (quyền 0600) |

| Trong thư mục | Nội dung |
|---|---|
| `profiles/<id>/` | Account Desktop: `auth.bin` (đã mã hóa), `meta.json` (tên, email; không có bí mật) |
| `cli/profiles/<id>/` | Account CLI, cùng cách lưu |
| `backups/`, `cli/backups/` | 10–20 bản sao lưu gần nhất trước mỗi lần chuyển |
| `usage.json` | Usage đã lưu (không chứa token) |
| `logs/` | Nhật ký các bước (không chứa token) |

Nếu có lỗi sau bước sao lưu, công cụ tự khôi phục cấu hình cũ và mở lại Claude.

Gỡ cài đặt: `claude-switch uninstall`. Mặc định account đã lưu vẫn được giữ lại; thêm `--purge` để xóa hết.

## Cho người phát triển

Cần Go 1.26 trở lên. Bản macOS phải build trên máy Mac (cần cgo cho WKWebView); build ở nơi khác thì bản macOS dùng cửa sổ trình duyệt thay thế.

```bash
go test ./...
```

```bash
go run ./cmd/claude-switch
```

```bash
go run ./tools/release -version 2.0.0
```

Lệnh cuối build và đóng gói cả 6 bản vào `dist/`. Đẩy tag `v*` lên GitHub thì workflow `.github/workflows/ci.yml` tự chạy test trên Windows, macOS, Linux, rồi build trên máy macOS và tạo Release kèm các gói.

Cấu trúc:

```
cmd/claude-switch/   điểm vào, dòng lệnh, mở cửa sổ, cài shortcut
internal/core/       Claude Desktop, Claude CLI, usage, sao lưu/khôi phục (có test)
internal/web/        máy chủ giao diện 127.0.0.1 (có token) + HTML/CSS/JS nhúng sẵn
internal/window/     cửa sổ native: WebView2 (Windows), WKWebView (macOS)
internal/secure/     mã hóa account đã lưu theo từng hệ điều hành
internal/platform/   tiến trình, terminal, Keychain, trình duyệt theo từng hệ điều hành
tools/release/       build và đóng gói
```
