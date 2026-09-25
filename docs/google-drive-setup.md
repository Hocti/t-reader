# 設定 Google Drive 同步

T Reader 用你自己的 Google Drive 同步每本書的閱讀資料：讀到哪裏、劃線、標籤。書本身不會上傳。資料放在 Drive 的 `EPUB Reader` 資料夾，一本書一個 JSON 檔。

app 只要求 `drive.file` 權限，只看得到它自己建立的檔案，看不到你 Drive 裏其他東西。

Google 只讓登記過的 app 登入。未登記時，按「連接 Google Drive」會顯示「這個 app 還沒在 Google Cloud 登記，所以 Google 拒絕登入」（錯誤碼 10）。以下步驟做一次就可以。

## 你需要準備

- 一個 Google 帳號。
- app 的套件名稱：`riverine.studio.epub`
- 簽署金鑰的 SHA-1 指紋（見第 1 步）。

## 1. 取得 SHA-1 指紋

Google 用「套件名稱 + SHA-1」認出這個 app。不同金鑰簽出來的 APK，SHA-1 不同，每一把都要登記。

現在沒有 `android/key.properties`，debug 和 release 都用這部電腦的 debug 金鑰 `~/.android/debug.keystore`。它的 SHA-1 是：

```
A9:A7:73:87:FC:A0:B8:86:06:B8:36:09:D8:B7:AD:DF:38:D8:4D:AD
```

自己查（換了電腦或金鑰時要再查）：

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android | grep SHA1
```

之後加上 `android/key.properties`（臨時自簽金鑰）時，用那把金鑰再查一次：

```bash
keytool -list -v -keystore <storeFile 的路徑> -alias <keyAlias>
```

也可以在 `android/` 目錄跑 `./gradlew signingReport`，它會列出每個建置類型用的 SHA-1。

如果將來經 Google Play 發佈並使用 Play 應用程式簽署，Play Console 的「應用程式完整性」頁有另一個 SHA-1，那個也要登記。

## 2. 開一個 Google Cloud 專案

1. 打開 [Google Cloud Console](https://console.cloud.google.com/)，用你的 Google 帳號登入。
2. 最上方的專案選單 →「新增專案」。名稱隨意，例如 `T Reader`。建立後切換到這個專案。

## 3. 啟用 Google Drive API

1. 左邊選單 →「API 和服務」→「程式庫」。
2. 搜尋 `Google Drive API`，打開，按「啟用」。

沒有啟用的話，登入會成功，但同步時會失敗。

## 4. 設定 OAuth 同意畫面

Google 近年把這部分改名為「Google Auth Platform」，以下用新介面的名稱，括號是舊名稱。

1. 左邊選單 →「API 和服務」→「OAuth 同意畫面」。第一次進入會請你按「開始」。
2. **品牌塑造**（應用程式資訊）：應用程式名稱填 `T Reader`，使用者支援電子郵件和開發人員聯絡資訊填你自己的電郵。
3. **目標對象**（使用者類型）：選「外部」（External）。
4. **資料存取**（範圍）：按「新增或移除範圍」，搜尋 `drive.file`，勾選
   `https://www.googleapis.com/auth/drive.file`（查看、編輯、建立及刪除這個應用程式使用的 Google 雲端硬碟檔案），儲存。
5. 回到**目標對象**，在「測試使用者」按「新增使用者」，加入每一個要用來同步的 Google 帳號。

發布狀態是「測試中」時，只有測試使用者能登入，最多 100 個。自己用的話這樣就夠了。

如果之後發現大約每星期就要重新登入一次，可以在「目標對象」按「發布應用程式」改成「正式版」。`drive.file` 不是敏感範圍，一般不用經過 Google 審查；登入時可能會看到「Google 尚未驗證這個應用程式」，按「進階」→「前往 T Reader」即可。

## 5. 建立 Android OAuth 用戶端

1. 左邊選單 →「API 和服務」→「憑證」（新介面是 Google Auth Platform 的「用戶端」）。
2. 「建立憑證」→「OAuth 用戶端 ID」。
3. 應用程式類型選「Android」。
4. 名稱隨意，例如 `T Reader debug`。
5. 套件名稱填 `riverine.studio.epub`。
6. SHA-1 憑證指紋貼上第 1 步的值。
7. 按「建立」。

不用下載任何 JSON，也不用把用戶端 ID 放進程式碼。Android 會用套件名稱和簽署金鑰自動對上。

每多一把金鑰（臨時自簽金鑰、Play 簽署金鑰），就再建一個 Android 用戶端，套件名稱相同，SHA-1 換成那一把。

## 6. 在 app 裏連接

1. 打開 T Reader →書櫃右上角的設定圖示。
2. 捲到 Google Drive，按「連接 Google Drive」。
3. 選第 4 步加進測試使用者的帳號，允許存取。
4. 顯示「上次同步：……」就是成功。

剛在 Google Cloud 建好用戶端，可能要等幾分鐘才生效。仍然出現錯誤碼 10 的話，先等五分鐘再試。

之後 app 會在開啟時、回到 app 時、離開 app 時、改動後 8 秒自動同步，也可以按「立即同步」。在第二部裝置上用同一個帳號連接，兩邊的進度、劃線、標籤就會合併。

## 常見問題

| 畫面顯示 | 原因與做法 |
| --- | --- |
| 這個 app 還沒在 Google Cloud 登記（錯誤碼 10） | 套件名稱或 SHA-1 不對，或用戶端還未生效。確認第 5 步的套件名稱是 `riverine.studio.epub`，SHA-1 是簽這個 APK 的那把金鑰。換過金鑰或換了電腦建置都要重新查 SHA-1。 |
| 選帳號後 Google 顯示「存取遭拒」或登入失敗 | 這個帳號不在測試使用者名單。回第 4 步第 5 點加入。 |
| 同步失敗 | 多數是沒有啟用 Google Drive API（第 3 步）。 |
| 連不上 Google Drive | 沒有網絡，或網絡擋了 Google。 |
| 要重新登入 Google | 登入過期。按「連接 Google Drive」再登入一次。常常出現的話，把同意畫面改成正式版（第 4 步最後一段）。 |

## 資料在哪裏

- 手機：設定頁「閱讀資料目錄」，預設是 app 自己的儲存空間。
- Drive：`我的雲端硬碟 / EPUB Reader /`，一本書一個 `書名.json`。

中斷連接不會刪除 Drive 或手機上的檔案。要完全移除，到 Drive 刪掉 `EPUB Reader` 資料夾，再到 [Google 帳戶的第三方連結](https://myaccount.google.com/connections) 移除 T Reader。
