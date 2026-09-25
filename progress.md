# Progress

## 這次做了什麼

- 應用程式 id 改為 `riverine.studio.epub`。`MainActivity` 的套件路徑一併改了。通知頻道 id 改為 `riverine.studio.epub.speech`。
- 應用程式名稱改為 `T Reader`（啟動圖示名稱、Flutter 視窗標題、說明文件標題）。Google Drive 同步資料夾仍叫 `EPUB Reader`。
- 新增 `scripts/push-github.sh`：提交並推到 `origin`。加上 `--release` 會建置 release APK，上傳到 GitHub Release（標籤用 `pubspec.yaml` 的版本，同一版本會換掉舊的 APK）。
- 專案放到 GitHub：`Hocti/epub-reader`。

書櫃與 Drive 教學：

- 新增 `docs/google-drive-setup.md`：繁中的 Google Drive 設定教學（SHA-1、Cloud 專案、Drive API、同意畫面、Android 用戶端、常見錯誤）。
- 書櫃上方一行不再左右捲動：搜尋改成左下角的圓形浮動按鈕；篩選按鈕只有圖示，不是預設時填色；排序拿掉「修改日期」（加入時間），按鈕和讀設定的那行留在註解裡，舊設定回到「最近閱讀」。
- 每本書在時間前面顯示狀態小框：閱讀中、未開始、已完結（填色）、封存。未開始不再寫「尚未閱讀」。
- 已完結不一定要 100%：`book_text.dart` 的 `endChapter` 在最後 10% 的章節（按章數）找章名含致謝、版權、註釋、譯者（含簡體和「注釋」）的第一章，讀到那一章就算完結。結果存在 `book_meta_v1` 的 `end`；舊快取沒有這欄，會重讀一次書（章節份量保留）。
- `flutter analyze` 沒有問題，53 個測試全部通過。新增完結位置和狀態的測試。沒有建 APK。

## 下一步

- Google Cloud 的 Android OAuth 用戶端要改成套件名稱 `riverine.studio.epub`，否則 Google Drive 登入會失敗（status 10）。步驟見 `docs/google-drive-setup.md`。
- 實機看書櫃上方一行在窄螢幕是否放得下，浮動搜尋鈕有沒有擋到最後一本書。
