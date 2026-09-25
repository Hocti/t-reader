# Progress

## 這次做了什麼

- 應用程式 id 改為 `riverine.studio.epub`。`MainActivity` 的套件路徑一併改了。通知頻道 id 改為 `riverine.studio.epub.speech`。
- 應用程式名稱改為 `T Reader`（啟動圖示名稱、Flutter 視窗標題、說明文件標題）。Google Drive 同步資料夾仍叫 `EPUB Reader`。
- 新增 `scripts/push-github.sh`：提交並推到 `origin`。加上 `--release` 會建置 release APK，上傳到 GitHub Release（標籤用 `pubspec.yaml` 的版本，同一版本會換掉舊的 APK）。
- 專案放到 GitHub：`Hocti/epub-reader`。

## 下一步

- Google Cloud 的 Android OAuth 用戶端要改成套件名稱 `riverine.studio.epub`，否則 Google Drive 登入會失敗（status 10）。
