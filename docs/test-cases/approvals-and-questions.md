# Test cases — Approvals & questions từ notch

Tính năng: trả lời `PermissionRequest` (Allow / Always / Deny) và `AskUserQuestion`
của Claude Code ngay trên notch (Settings → Approvals and questions).

**Cách test**
- **Auto**: XCTest trong `Tests/LidEffortTests` — chạy `swift test --filter "Prompt"`.
- **Render**: vẽ card ra PNG, không đụng màn hình —
  `EFFORT_RENDER_DIR=/tmp/r swift test --filter "PromptRenderTests|PromptDesignRenderTests"`.
- **E2E**: prompt giả gửi vào app đang chạy bằng
  `build/pillr.app/Contents/MacOS/pillr --prompt-hook < prompt.json`,
  đối chiếu với log `/usr/bin/log show --predicate 'subsystem == "dev.lideffort"'`.
- **Thủ công**: cần người ngồi máy (hover, click thật) hoặc Claude thật (đã `/login`, bật công tắc).

Kết quả lần chạy 2026-09-23: toàn bộ suite 1373 XCTest + 63 Swift Testing — pass,
trừ 2 test đo thời gian không liên quan (LMStudioMetrics, UsageRefreshDeadline) lúc
máy đang tải nặng; chạy riêng thì pass.

## Test tay bằng prompt giả

`script/fake-prompt.sh` gửi prompt giống hệt hook của Claude vào app đang chạy,
chờ bạn trả lời trên notch, rồi in JSON Claude sẽ nhận và giải thích nó
(ALLOW / ALLOW ALWAYS / DENY / ANSWERED / rỗng = Claude tự hỏi). Không lệnh nào chạy thật.

| Lệnh | Case |
|---|---|
| `script/fake-prompt.sh bash` | TC08–10, TC28, TC36 |
| `script/fake-prompt.sh edit` | TC02 |
| `script/fake-prompt.sh ask1` | TC12 |
| `script/fake-prompt.sh ask2` | TC13–17, TC26, TC36 |
| `script/fake-prompt.sh two` | TC29–31 |
| `script/fake-prompt.sh open` | TC11 — gắn với session CLI thật mới nhất |
| `script/fake-prompt.sh switch` | TC35 — gắn với session CLI thật mới nhất |
| `script/fake-prompt.sh list` | xem session để chọn `--session PID` |

`--dry` in JSON sẽ gửi mà không gửi. `open`/`switch` chờ 4 s trước khi gửi để bạn
rời khỏi terminal của session đó (đang nhìn đúng session thì app trả ngay cho
Claude — đó là TC05). Ctrl-C giả lập session bị ngắt (TC33).

## A. Nhận và hiển thị prompt

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC01 | Claude xin chạy lệnh Bash | Card "Needs your OK" cạnh pill gập: lệnh trong ô, nút Allow · Always · Deny | Auto `testAPermissionPromptIsReadWithItsCommandAndSuggestion` + Render | Pass |
| TC02 | Claude xin sửa file | Đường dẫn hiện tương đối theo thư mục session | Auto `testAFilePathIsShownRelativeToTheSession` | Pass |
| TC03 | AskUserQuestion | Đọc đủ câu hỏi, option, mô tả, single/multi | Auto `testAQuestionIsReadWithItsOptions` | Pass |
| TC04 | Input rác | Không thành prompt; Claude tự hỏi như thường | Auto `testGarbageIsNotAPrompt` | Pass |
| TC05 | Đang nhìn đúng session đó | Trả ngay cho dialog của Claude, không giữ | Auto `testAPromptInViewIsHandedStraightBack` | Pass |
| TC06 | App không chạy | Hook không in gì, thoát 0, Claude không bị treo | Auto `testNobodyRunningMeansNoAnswerAndNoStall` | Pass |
| TC07 | Prompt tới app thật | Log "prompt received: Bash for session …" | E2E | Pass |

| TC44 | Prompt của một session có trong danh sách | Session đó lên đầu, ghi "waiting · just now", card câu hỏi/approval nằm ngay dưới nó, không lặp lại tên session | Auto `SessionListPlanTests` + Render · tay: `fake-prompt.sh bash --session <PID>` | Pass (auto) |
| TC45 | Prompt không gắn được với session nào | Card nằm trên danh sách như cũ, tự ghi tên session | Auto `testAPromptFromASessionTheListDoesNotKnowStaysAboveIt` | Pass |

## B. Trả lời approval

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC08 | Bấm Allow | Hook in `behavior: allow` | Auto `testTheHookOutputForEachAnswer` | Pass |
| TC09 | Bấm Always | `allow` + `updatedPermissions` lấy từ gợi ý của Claude | như trên | Pass |
| TC10 | Bấm Deny | `deny` + message "Declined from the pillr notch." | như trên | Pass |
| TC11 | Bấm icon Open ↗ | Trả prompt về dialog của Claude + nhảy tới session | Auto `PromptClickMapTests` (vùng bấm ↗ ≥ 4 ô lưới, trước đây chỉ 1) · tay: `fake-prompt.sh open` | Lỗi → đã sửa, chờ test tay lại |

## C. Trả lời câu hỏi

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC12 | 1 câu, chọn 1 | Click option = gửi luôn | Auto `testOneSingleChoiceQuestionIsAnsweredByTheClick` | Pass |
| TC13 | Chọn nhiều | Chờ Send; thứ tự theo thứ tự option | Auto `testAMultipleChoiceQuestionWaitsForSendAndKeepsOfferedOrder` | Pass |
| TC14 | Bỏ chọn hết | Send tắt lại | Auto `testUnpickingEverythingTurnsSendOffAgain` | Pass |
| TC15 | 2–3 câu | Đi lần lượt, gửi tất cả một lần | Auto `testSeveralQuestionsStepThroughAndSendTogether` | Pass |
| TC16 | Back | Giữ lựa chọn cũ | Auto `testBackKeepsWhatWasPicked` | Pass |
| TC17 | Hook nhận đáp án | `updatedInput.answers`, multi nối bằng dấu phẩy | Auto `testTheHookGetsEveryAnswerWithMultipleChoicesJoined`, `testAnswersGoBackInTheToolInputWithMultiSelectJoined` | Pass |
| TC18 | Câu dài/ngắn khác nhau | Card cao theo câu dài nhất, không nhảy kích thước | Auto `testTheCardIsSizedForItsTallestQuestion` | Pass |
| TC19 | Tiêu đề, dòng trạng thái | Theo câu đang hiện ("Pick one" / "Pick one or more") | Auto `testTitleAndStatusFollowTheQuestionOnScreen` + Render | Pass |

### C2. Thiết kế mới (ApprovalCard)

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC46 | Chọn 1 đáp án (radio) | Chỉ chọn; không tự sang câu sau, không tự gửi — phải bấm Continue / Send | Auto `testASingleChoiceIsSentByContinueOrByItselfAfterABeat` · tay `ask1` | Pass (auto) |
| TC47 | "Something else…" | Gõ chữ + Return = câu trả lời; radio: thay cho lựa chọn; checkbox: thêm vào | Auto `testSomethingElseIsAnAnswerOfItsOwn`, `testPickingAfterTypingClearsTheTypingOnASingleChoice` · tay `ask1`/`ask2` | Pass (auto) |
| TC48 | Skip | Sang câu sau không trả lời; câu cuối: gửi những gì có, không có gì thì trả về Claude | Auto `testSkipMovesOnAndTheLastSkipSendsWhatThereIs` | Pass (auto) |
| TC49 | ⌃ ⌄ và bộ đếm "1 / 2" | Đi tự do, không mất lựa chọn; số lăn khi đổi | Auto `testTheArrowsMoveFreelyAndKeepWhatWasPicked` | Pass (auto) |
| TC50 | Card đổi chiều cao theo câu | Câu nhiều option → card cao hơn; trượt lên giữa các câu | Auto `testTheCardFitsTheQuestionOnScreen`, `testALongQuestionTakesMoreLinesUpToThree` + Render | Pass (auto) |
| TC51 | ✕ | Trả về dialog của Claude (reply rỗng) | Auto `PromptClickMapTests` (vùng ✕) · tay | Pass (auto) |
| TC52 | Sau khi trả lời | "Answers sent ✓" / "Allowed" / "Declined" hiện ~1,4 s thay chỗ card | Auto `testTheEchoSaysWhatHappened` + Render · tay | Pass (auto) |
| TC53 | Gõ xong gửi đi | Bàn phím về lại app trước đó (terminal), không kẹt ở notch | Thủ công | Chưa chạy |

### C3. Thông báo cho approval và câu hỏi (Settings → Notifications → When Claude asks)

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC54 | Approval tới / câu hỏi tới | Hai âm khác nhau (mặc định Funk / Ping); tắt "Play a sound" thì im | Auto `testApprovalsAndQuestionsSoundDifferentAndSilenceIsSilence` · tay `bash`, `ask1` | Pass (auto) |
| TC55 | Remind me = 2 phút, không trả lời | Kêu lại sau 2 phút, rồi mỗi 2 phút; trả lời xong thì thôi | Auto `testRemindersComeEveryFewMinutesOnlyWhileSomethingWaits` | Pass (auto) |
| TC56 | macOS notification bật | Banner "Needs your OK · session" / "Claude asks · session"; trả lời xong banner được gỡ | Auto `testTheNotificationSaysWhoAndWhat` · tay | Pass (auto) |
| TC57 | Over full-screen apps = Sound only, đang full-screen | Không hiện card, chỉ kêu; thoát full-screen thì card hiện | Auto `testSoundOnlyHoldsTheCardWhileAFullScreenAppIsInFront` | Pass (auto) |
| TC58 | Prompt tới cho session đang chờ | Chỉ kêu một lần (âm của prompt), không kêu thêm âm "Waiting on you" | Đọc code | — |

### C4. Ngữ cảnh khi nhiều session chạy cùng lúc

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC59 | Prompt có transcript | Dòng phụ "session · thư mục · ⎇ nhánh"; trên câu hỏi: "You" = câu bạn yêu cầu gần nhất (tối đa 2 dòng), "Claude" = câu Claude nói ngay trước khi hỏi | Auto `PromptContextTests` + Render · **Claude thật** 2026-09-24 00:15: đủ You, Claude, PillLid, thư mục, nhánh | **Pass** |
| TC60 | Transcript thật của một session | Đúng tên, nhánh, câu yêu cầu, câu dẫn | Auto `testARealTranscript` (EFFORT_TRANSCRIPT) — chạy trên session PillLid: đúng | Pass |
| TC61 | Banner macOS | Có dòng phụ trích câu bạn yêu cầu | Đọc code | — |

## D. Không tự ẩn — chỉ mất khi đã trả lời

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC20 | Notch gập, có prompt | Card cạnh pill ở mãi, không hẹn giờ | Đọc code: card chỉ phụ thuộc `currentPrompt`, không có timer · E2E: giữ 13 s tới khi hook bị kill | Pass |
| TC21 | Mở notch khi có prompt | Tooltip Claude có câu hỏi tự bật, không cần trỏ vào vòng Claude | Auto `testAnOpenQuestionHoldsTheNotchUntilItIsAnswered` | Pass |
| TC22 | Rê chuột ra xa, chờ > thời gian gập | Notch vẫn mở, tooltip vẫn hiện | như trên | Pass |
| TC23 | Trỏ vào vòng khác rồi rời ra | Hiện card vòng đó, rời ra thì quay về câu hỏi | Auto `testAnotherRingStillShowsItsOwnCardThenTheQuestionComesBack` | Pass |
| TC24 | Trả lời xong prompt cuối | Notch về hover thường, tự gập | Auto (cuối `testAnOpenQuestionHolds…`) | Pass |
| TC25 | App full-screen lên trước | Không gập notch đang giữ câu hỏi | Auto `testAFullScreenAppDoesNotFoldAWaitingQuestionAway` | Pass |
| TC26 | Trả lời câu 1 trong tooltip | Tooltip ở lại cho câu 2, không nhảy sang terminal | Auto `testAClickInTheTooltipNeverFoldsTheNotchOrJumpsToTheTerminal` | Pass |
| TC27 | Click vào card cạnh pill gập | Notch không mở, không nhảy session, không trả lời gì | Auto `testAClickOnTheFoldedCardNeitherOpensTheNotchNorTheSession` | Pass |
| TC28 | Hover thật + chuột thật | Như TC21–24 | Thủ công | Chưa chạy |
| TC28a | Trả lời/duyệt ngay trong terminal hoặc app Claude (không bấm trong pillr) | Card rút khỏi notch trong ~1,5 s, gỡ notification, không nhắc lại âm thanh; hook đóng im lặng, không gửi quyết định nào về Claude | Auto `PromptSettlementTests` (transcript có tool_result của đúng lệnh; registry `waiting` → `busy`), `PromptReleaseTests` · Thủ công: duyệt trong terminal | Pass (auto) |
| TC28b | Session Claude thoát khi card đang chờ | Card rút | Auto `testASessionWhoseProcessIsGoneSettlesIt` | Pass |
| TC28c | Hai prompt song song, chỉ một được trả lời ở terminal | Chỉ card đó rút, card kia ở lại | Auto `testParallelPromptsAreSettledEachOnTheirOwn` | Pass |

## E. Nhiều session hỏi cùng lúc

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC29 | 2 session chờ | Pager ‹ 1/2 ›, mỗi prompt giữ lựa chọn riêng | Auto `testTwoWaitingSessionsArePagedAndKeepTheirOwnPicks` + Render | Pass |
| TC30 | Trả lời 1 cái | Cái còn lại vẫn trên màn hình | Auto `testAnsweringOneLeavesTheOtherOnScreen` | Pass |
| TC31 | Lật qua lại | Vòng từ cuối về đầu và ngược lại | Auto `testThePagerWrapsBothWays` | Pass |
| TC32 | 2 hook thật qua socket, trả lời ngược thứ tự | Mỗi hook nhận đúng đáp án của mình | Auto `testTwoSessionsAreAnsweredIndependently` | Pass |

## F. Vòng đời

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC33 | Session bị ngắt (hook chết) | Prompt tự rút khỏi notch | Auto `testAHookThatGoesAwayWithdrawsItsPrompt` + E2E (log "prompt withdrawn: its hook went away") | Pass |
| TC34 | Không ai trả lời 9 phút | Trả về dialog của Claude | Auto `testAnUnansweredPromptIsLetGoAfterItsPatience` | Pass |
| TC35 | Chuyển sang đúng session đó | Trong ≤ 1,5 s prompt được trả về dialog của Claude | Thủ công | Chưa chạy |

## G. An toàn

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC36 | Card hiện ra ngay dưới chuột đang click (game, app khác, double-click) | 0,7 s đầu nút mờ và không nhận click; hiện câu mới/lật session thì khóa lại | Auto `testAFreshScreenOfChoicesIsArmedAgain` (khóa theo màn hình) · thời gian thật: thủ công | Pass / thủ công chưa chạy |
| TC37 | Profile Claude khác mặc định | Không mang prompt; không giữ notch | Auto `testOnlyTheDefaultClaudeProfileCarriesThePrompt` | Pass |

## H. Cài / gỡ hook

| ID | Tình huống | Kỳ vọng | Cách test | KQ |
|---|---|---|---|---|
| TC38 | Bật công tắc | Thêm đúng 1 hook, giữ nguyên mọi thứ khác | Auto `testInstallAddsOneEntryAndKeepsEverythingElse` | Pass |
| TC39 | Tắt công tắc | Chỉ gỡ hook của mình | Auto `testRemoveTakesOnlyOurs` | Pass |
| TC40 | Gỡ hook cuối | Không để lại mảng/đối tượng rỗng | Auto `testRemovingTheLastHookLeavesNoEmptyShells` | Pass |

## I. Với Claude thật

| ID | Tình huống | Kỳ vọng | KQ |
|---|---|---|---|
| TC41 | Claude Code xin chạy Bash → Allow trên notch | Lệnh chạy, không có dialog trong terminal | Bị chặn: CLI hết hạn OAuth, công tắc đang tắt |
| TC42 | Claude hỏi AskUserQuestion 2 câu (1 single, 1 multi) | Claude nhận đúng đáp án | **Pass** 2026-09-24 00:03 — Claude Desktop session, hỏi qua notch, 4 lựa chọn của câu multi về đủ |
| TC43 | 2 terminal cùng hỏi | Pager, trả lời độc lập | Bị chặn như trên |
