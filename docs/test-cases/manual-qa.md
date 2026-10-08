# pillr: test case cho tester (test tay)

Bộ này dành cho người test bằng tay trên máy thật, trước mỗi lần release và
khi cho user mới dùng thử. Phần logic đã có test tự động (`swift test`, xem
[end-to-end.md](end-to-end.md)); phần approvals chi tiết ở
[approvals-and-questions.md](approvals-and-questions.md). File này lo những
thứ test tự động không bắt được: cài đặt, quyền hệ thống, phần cứng, phiên
bản macOS, và cảm giác dùng thật.

**Ưu tiên:** P0 = lỗi là không release. P1 = phải sửa trong bản kế. P2 = nên có.

**Ghi kết quả:** mỗi case ghi `Pass / Fail / Skip`, máy (model + chip), bản
macOS (`sw_vers`), bản pillr (Settings → General), và ảnh hoặc crash report
nếu Fail. Crash report nằm ở `~/Library/Logs/DiagnosticReports/pillr-*.ips`.

---

## 0. Ma trận tương thích

pillr yêu cầu **macOS 15.0 trở lên** và **Apple silicon** (binary chỉ có
`arm64`). Từ macOS 26 app dùng Liquid Glass; trên macOS 15 nó tự chuyển sang
nền đặc (solid). Hai nhánh giao diện này phải được test riêng.

### 0.1 Phiên bản macOS

| Bản macOS | Vai trò | Cần test | Ghi chú |
|---|---|---|---|
| 14 Sonoma trở xuống | Không hỗ trợ | Chỉ case **K1** | Phải bị macOS chặn mở, có thông báo cần bản mới hơn, không crash |
| **15.0** Sequoia | Bản thấp nhất | Smoke test (mục 1) + toàn bộ mục **J** | Nhánh nền đặc, không có Liquid Glass. Dễ lộ API mới bị gọi nhầm |
| 15.x mới nhất | Phổ biến | Smoke test + J | |
| **26.0** Tahoe | Bản đầu có Liquid Glass | Smoke test + J | Kiểm tra glass trên notch, card, Settings, tour |
| 26.x mới nhất | Phổ biến | Smoke test + J | Nhiều user còn ở đây (tester đầu tiên dùng 26.6.2) |
| **27.x** mới nhất | Bản mới nhất | **Toàn bộ** file này | Máy test chính |
| Beta macOS kế tiếp | Phát hiện sớm | Smoke test | Không chặn release, chỉ ghi nhận |

### 0.2 Phần cứng

| Máy | Vì sao khác | Case đặc biệt |
|---|---|---|
| MacBook có notch (Air M2+, Pro 14"/16") | Pill nằm quanh notch thật | F1, F2, C1 to C4 |
| MacBook không notch (Air M1, Pro 13") | Notch vẽ giả, vẫn có cảm biến nắp | F3, C1 to C4 |
| Mac để bàn (mini, Studio, iMac) | Không có cảm biến nắp | C5, F3 |
| MacBook gập nắp, dùng màn rời (clamshell) | Cảm biến nắp không dùng được, màn chính đổi | C6, F5 |
| Nhiều màn hình | Pill chọn màn nào, kéo qua màn khác | F4, F5 |
| Mac Intel | Không hỗ trợ | Chỉ case **K2** |

### 0.3 Cách có máy macOS cũ để test

- **Máy ảo trên Apple silicon** (UTM, Tart, VirtualBuddy) chạy được macOS 12 trở lên, tải IPSW
  của macOS 15.0 từ Apple. Máy ảo **không có** cảm biến nắp và notch, nên chỉ test
  được cài đặt, giao diện nền đặc, Settings, agent, API key. Mục C và F phải test
  trên máy thật.
- Máy thật đang ở macOS 15: đừng nâng cấp, giữ làm máy test nhánh nền đặc.
- Mỗi máy ảo nên tạo **user macOS mới** (sạch, chưa có `~/.claude`, chưa cấp quyền) để test như người mới.

---

## 1. Smoke test 10 phút (chạy trên MỌI bản macOS ở bảng 0.1)

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| S1 | Tải DMG bằng nút Download trên landing, mở DMG, kéo pillr vào Applications | DMG có nền và mũi tên, đúng tên `pillr-x.y.z.dmg`, đúng bản mới nhất | P0 |
| S2 | Mở pillr từ Applications lần đầu | Không có "Open Anyway", chỉ hộp xác nhận tải từ internet. **App mở và còn chạy sau 30 giây** | P0 |
| S3 | Xem trong Settings → General | Đúng số version, mục "What's new" có note của bản này | P0 |
| S4 | Pill hiện ở notch / mép màn hình | Thấy pill, có ít nhất một agent nếu máy đã cài agent | P0 |
| S5 | Mở Settings (mở lại app khi app đang chạy) | Settings mở, chữ và icon agent đầy đủ, không ô trống | P0 |
| S6 | Bấm qua từng tab: Lid, Notch, Sessions, Alerts, Accounts, API, Costs, Local models, General | Tab nào cũng hiện, không treo, không crash | P0 |
| S7 | Nút sáng/tối ở thanh trên Settings | Bấm được, đổi Light → Dark → System | P1 |
| S8 | Đổi ngôn ngữ sang 简体中文 rồi về English | Chữ đổi ngay, không cần mở lại | P1 |
| S9 | Thoát (nút nguồn ở Settings) rồi mở lại | Thoát sạch, mở lại giữ nguyên cài đặt | P0 |

> Bài học từ 1.1.1: S2 phải chạy trên **máy không phải máy build**. Máy build
> luôn chạy được vì nó có thư mục `.build` ở đó.

---

## A. Cài đặt, mở lần đầu, gỡ

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| A1 | User macOS mới hoàn toàn, cài và mở | Không crash, onboarding / tour hiện | P0 |
| A2 | `spctl -a -vv /Applications/pillr.app` | `accepted`, `source=Notarized Developer ID` | P0 |
| A3 | Chạy pillr ngay trong DMG hoặc từ Downloads | Không crash; Setup Assistant đề nghị chuyển vào Applications, chuyển xong vẫn chạy | P1 |
| A4 | Đổi tên app thành `pillr 2.app` hoặc để trong `~/Applications` | Vẫn chạy, chữ và icon vẫn đầy đủ | P1 |
| A5 | Cài đè bản mới lên bản cũ đang chạy | Bản cũ thoát, bản mới mở, giữ cài đặt | P1 |
| A6 | Bật "Mở khi đăng nhập", khởi động lại máy | pillr tự mở, chỉ một bản chạy | P1 |
| A7 | Kéo pillr vào Thùng rác khi đang chạy | Không treo máy; mở lại từ Thùng rác không làm hỏng dữ liệu | P2 |
| A8 | Tắt mạng, mở app lần đầu | App mở bình thường, phần usage báo không có mạng, không treo | P1 |

## B. Quyền hệ thống

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| B1 | Lần đầu cần Accessibility | App giải thích vì sao, nút mở đúng trang System Settings | P0 |
| B2 | Từ chối Accessibility | App vẫn chạy, chỗ cần quyền ghi rõ lý do, không crash | P0 |
| B3 | Cấp Accessibility khi app đang chạy | App nhận ra mà không cần mở lại (hoặc nói rõ cần mở lại) | P1 |
| B4 | Automation cho Terminal, iTerm2, Ghostty, Warp, VS Code, Cursor, Zed, cmux, Superset | Mỗi app hỏi đúng một lần, từ chối thì app ghi rõ | P1 |
| B5 | Thông báo (Notifications): cho phép rồi tắt | Bật: có banner khi agent xong/hỏi. Tắt: không banner, app vẫn chạy | P1 |
| B6 | Keychain: đọc đăng nhập của Claude Code / Antigravity | Mặc định **tắt** (General → Sign-ins). Bật mới đọc, không hiện hộp mật khẩu bất ngờ | P0 |
| B7 | Thu hồi quyền trong System Settings khi app đang chạy | App không crash, báo mất quyền | P1 |

## C. Cảm biến nắp (Lid gesture)

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| C1 | Settings → Lid: xem "Lid sensor on" và góc nắp | Góc đổi khi gập/mở nắp | P0 |
| C2 | Giữ ⌘, mở nắp thêm khoảng 7°, thả | Effort tăng một mức, card hiện mức mới | P0 |
| C3 | Mở/gập nắp **không** giữ ⌘ | Không đổi effort | P0 |
| C4 | Gập máy cho ngủ, mở lại | Mức giữ nguyên, 2 giây đầu không nhận cử chỉ | P1 |
| C5 | Mac để bàn | Không có cảm biến: tab Lid ghi rõ, không lỗi, vẫn chỉnh effort bằng thanh kéo | P0 |
| C6 | Clamshell với màn rời | Không nhận cử chỉ sai khi nắp đóng | P1 |
| C7 | Auto-eco bật, agent sắp hết hạn mức | Effort tự giảm một mức, có thông báo | P2 |

## D. Agent và phiên làm việc

Test với những agent tester có: Claude Code, Codex, Grok, Cursor, GitHub Copilot,
Gemini CLI, Antigravity, Kimi, GLM, OpenCode, DeepSeek, Devin, Perplexity,
Command Code, Ollama, LM Studio, app Claude desktop.

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| D1 | Chưa cài agent nào | Pill không hiện agent rỗng; Settings gợi ý thêm | P1 |
| D2 | Agent đã đăng nhập và có dữ liệu | Hiện trên pill với vòng usage đúng | P0 |
| D3 | Agent đã bật nhưng chưa có dữ liệu | **Không** hiện trên pill, vẫn có trong Settings | P1 |
| D4 | Chạy Claude Code, cho nó làm việc | Vòng quay khi đang chạy, vàng khi chờ, card "done" khi xong | P0 |
| D5 | Bấm card done | Mở đúng terminal / tab của phiên đó | P1 |
| D6 | Nhiều phiên cùng lúc ở nhiều terminal | Đổi effort chỉ ảnh hưởng phiên đang xem | P0 |
| D7 | Đổi effort khi agent đang trả lời | Chờ hết lượt mới gõ lệnh, card nói rõ đang chờ | P1 |
| D8 | Bộ gõ tiếng Việt (Telex) bật khi đổi effort trong app Claude | Lệnh gõ đúng `/effort <mức>`, không bị biến dấu | P0 |
| D9 | Approval / câu hỏi từ notch | Xem [approvals-and-questions.md](approvals-and-questions.md) | P0 |

## E. API key và chi phí

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| E1 | API → Add key, tìm "openrouter" | Tìm ra, dán key, hiện số dư / usage | P0 |
| E2 | Dán key sai | Báo key sai rõ ràng, không lưu | P1 |
| E3 | Thêm key, thoát app, mở lại | Key còn (trong Keychain), không lộ ra file thường | P0 |
| E4 | Xoá key | Mất khỏi pill và Keychain | P1 |
| E5 | Tab Costs với vài key | Chi phí theo ngày / tháng hợp lý | P2 |
| E6 | Menu agent → "Add API Key…" | Mở thẳng tab API | P2 |
| E7 | Hai key cùng nhà cung cấp | Gộp đúng nhóm, không trùng | P2 |

## F. Notch, pill, màn hình

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| F1 | Máy có notch: rê chuột vào notch | Pill mở rộng mượt, không che menu bar | P0 |
| F2 | Mở app toàn màn hình (video, Xcode full screen) | Pill ẩn hoặc không vướng, card chỉ có âm thanh | P1 |
| F3 | Máy không notch | Pill vẫn hiện đúng vị trí, không lệch | P0 |
| F4 | Kéo pill sang mép khác / màn khác | Bám mép, nhớ vị trí sau khi mở lại | P1 |
| F5 | Rút màn rời khi pill đang ở màn đó | Pill về màn còn lại, không biến mất | P0 |
| F6 | Đổi độ phân giải / scale màn hình | Pill vẽ lại đúng | P2 |
| F7 | Dark mode, Light mode, màu nhấn hệ thống khác | Chữ đọc được, tương phản đủ | P1 |
| F8 | Bật "Reduce transparency" / "Reduce motion" (Accessibility) | Không mất chữ, chuyển động giảm | P1 |
| F9 | Zoom chữ to hơn (Display → Larger text) | Không cắt chữ trong card | P2 |

## G. Thông báo và âm thanh

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| G1 | Agent xong việc khi đang dùng app khác | Card + âm thanh đúng loại | P1 |
| G2 | Bật Focus / Do Not Disturb | Không có banner, card vẫn ở pill | P2 |
| G3 | Usage chạm ngưỡng cảnh báo | Báo một lần, không lặp liên tục | P1 |

## H. Cập nhật (Sparkle)

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| H1 | Cài bản trước, bấm Check for Updates | Thấy bản mới, release note hiện đúng | P0 |
| H2 | Cập nhật | Tải, cài, mở lại thành bản mới, giữ cài đặt | P0 |
| H3 | Đang ở bản mới nhất, Check for Updates | Báo đã là bản mới nhất | P1 |
| H4 | Tắt mạng khi kiểm tra | Báo lỗi gọn, không treo | P2 |
| H5 | Kiểm tra chữ ký trong `appcast.xml` | Khớp key trong `SUPublicEDKey` của app | P0 |

## I. Ngôn ngữ

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| I1 | Lần lượt English, Français, 日本語, Português, Русский, 简体中文 | Mọi tab có chữ dịch, không lộ key tiếng Anh lẻ tẻ | P1 |
| I2 | Ngôn ngữ hệ thống là tiếng Việt (chưa có bản dịch) | Rơi về English, không ô trống | P1 |
| I3 | Tiếng Nga / Pháp (chữ dài) | Không cắt chữ trong card và nút | P2 |

## J. Riêng theo bản macOS

| ID | Bước | macOS | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|---|
| J1 | Xem pill, card, Settings, tour | 15.x | Nền đặc, viền rõ, **không** ô xám phẳng thay cho kính | P0 |
| J2 | Xem pill, card, Settings, tour | 26.x và 27.x | Liquid Glass hiện đúng, chữ đọc được trên nền sáng và tối | P0 |
| J3 | Chọn kiểu nền "Glass" trên máy 26, rồi mang cài đặt sang máy 15 (hoặc khôi phục backup) | 15.x | Tự dùng nền đặc, không vẽ trống | P1 |
| J4 | Tay cầm kéo (move handle), tay cầm Settings, tooltip | 15.x và 26.x | Đều bấm và kéo được, hình hợp với bản macOS | P1 |
| J5 | Trả lời nhanh trong orb (OrbReply) | 15.x và 26.x | Gõ được, gửi được | P1 |
| J6 | Menu bar, phím tắt ⌘, (Settings) | 15.x và 26.x | Hoạt động | P1 |
| J7 | Accessibility và Automation hỏi quyền | 15.x và 26.x | Hộp hỏi quyền đúng, nút mở đúng trang System Settings (đường dẫn trang đổi giữa các bản macOS) | P0 |
| J8 | Thông báo hệ thống | 15.x và 26.x | Banner hiện đúng | P1 |

## K. Máy không được hỗ trợ

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| K1 | Mở pillr trên macOS 14 | macOS báo cần bản mới hơn và không mở app; **không** crash report | P1 |
| K2 | Mở pillr trên Mac Intel | macOS báo app không chạy được trên máy này; landing và README đã ghi "Apple silicon" | P1 |

## L. Ổn định và hiệu năng

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| L1 | Để app chạy 8 tiếng làm việc bình thường | Không crash, RAM không tăng mãi (Activity Monitor) | P0 |
| L2 | CPU khi rảnh | Gần 0%, không làm nóng máy | P1 |
| L3 | Sleep / wake nhiều lần, đổi Wi-Fi | Usage tự lấy lại, không treo | P1 |
| L4 | Hết pin, chế độ Low Power | Không tốn pin rõ rệt (Activity Monitor → Energy) | P2 |
| L5 | Một agent không phản hồi (mạng chậm) | Các agent khác vẫn cập nhật | P1 |

## M. Riêng tư và an toàn

| ID | Bước | Kết quả mong đợi | Ưu tiên |
|---|---|---|---|
| M1 | Mở Console.app, lọc "pillr" | Không thấy nội dung tin nhắn, API key, token | P0 |
| M2 | Gỡ tính năng trả lời từ notch | Chỉ dòng hook của pillr bị xoá khỏi `~/.claude/settings.json`, phần khác giữ nguyên | P0 |
| M3 | Market data (giá token) | Mặc định tắt, chỉ gọi mạng khi bật | P1 |

---

## Checklist trước mỗi release (người build)

1. `swift test` không có lỗi thật (2 test đo thời gian có thể chập chờn khi máy bận, chạy lại riêng).
2. Build release, rồi kiểm tra: `strings pillr.app/Contents/MacOS/pillr | grep "\.build/"` có thể vẫn có đường dẫn máy build, **nhưng app không được phụ thuộc vào nó**. Đã có `ResourceBundleTests` chặn việc gọi `Bundle.module`.
3. Cài DMG thật lên **một máy khác máy build** (hoặc user macOS mới, hoặc máy ảo), chạy smoke test mục 1.
4. Ít nhất một máy macOS 15.x và một máy 26.x chạy smoke test.
5. `spctl -a -vv` báo Notarized Developer ID; chữ ký Sparkle trong `appcast.xml` khớp.
6. Nút Download trên landing trỏ đúng bản mới (cache tối đa 10 phút).
