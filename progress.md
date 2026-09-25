# Progress

## 這次做了什麼

- `scripts/push-github.sh --release` 在沒有改動可提交時，仍然會建置 release APK 並上傳到 GitHub Release。Samsung SSD 沒掛上時不再中止；Gradle 快取沿用本機的 `~/.gradle`。有寫提交說明時，那段文字會變成 Release 的說明。

## 下一步

- 再跑一次 `./scripts/push-github.sh --release "first version"`，把 APK 放到 GitHub Release。
