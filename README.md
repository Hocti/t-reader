# T Reader

Android 閱讀 app。書櫃、一次一章的閱讀，和設定。

點查的解釋、雲端朗讀、手錶控制還沒做。書店不會做，也沒有後端。

功能以 [docs/features.html](docs/features.html) 為準。那份是繁中，可以直接改。

## 現在有什麼

- 書櫃：掃描已加入的目錄。`.epub` 檔，或是裡面有 `mimetype` 的資料夾，各算一本書。只看目錄第一層。
- 閱讀：全螢幕，一次一章，按頁翻。版面、目錄、劃線、系統朗讀。語言預設廣東話。點查是下半個畫面，內容是空的。
- 設定：多個本機目錄、主題、已隱藏的書、版本號。主題預設是電子紙用的白（完全黑白），另外可以選黑、略有顏色的淺色、深色。
- 沒有動畫。

## 建置 Android 安裝檔

本機的 Flutter SDK 在 `/home/hocti/sdk/flutter`，不在這個專案裡。

在專案根目錄執行：

```bash
./scripts/build-android.sh
```

沒有參數時，這支腳本會建置 debug 版，並安裝到目前連接的裝置。檔案留在 `build/app/outputs/flutter-apk/app-debug.apk`。有多個裝置時，先設定 `ANDROID_SERIAL`。

```bash
./scripts/build-android.sh --release
./scripts/build-android.sh --dl
```

`--release` 會另外建置 release 版。`--dl` 會建置 release 版，並複製到 `/mnt/nas4/web/subdomains/dl/epub-reader-release.apk`。

下載網址是 [https://dl.sitepreview.cc/epub-reader-release.apk](https://dl.sitepreview.cc/epub-reader-release.apk)。

有 `android/key.properties` 時，debug 和 release 都用 `android/signing/` 裡的憑證。這兩個都已忽略、不進版控。這台機器還沒有這組憑證時，release 會改用 debug 簽章，仍然可以安裝。

應用程式 id 是 `riverine.studio.epub`，名稱是 T Reader。

## 推上 GitHub

```bash
./scripts/push-github.sh "提交說明"
./scripts/push-github.sh --release "提交說明"
```

第一行會提交目前的改動並推到 `origin`。加上 `--release` 會再建置 release APK，上傳到 GitHub Release。標籤用 `pubspec.yaml` 的版本。同一個版本再跑一次會換掉那個 Release 上的 APK。

## 限制

全 app 不要動畫。設定不做成底部 tab，只從書櫃右上角一顆按鈕進入。

`demo/` 已在 `.gitignore`，不要把試用檔放進版控。
