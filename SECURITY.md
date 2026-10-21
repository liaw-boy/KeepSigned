# 安全性

## 回報漏洞

請**不要**在公開的 Issue 回報安全問題。請到本 repo 的 **Security → Report a vulnerability**（GitHub 私下漏洞回報）提交，內容盡量包含：

- 受影響的版本
- 重現步驟
- 可能造成的影響

我們會盡快回覆，並在修正版發布後公開說明。

## 支援的版本

只有最新版會收到安全性修正。KeepSigned 會自動更新，請保持開啟自動檢查更新。

## 安全設計

- **不碰帳密**：KeepSigned 不讀取、不儲存、不傳送 Apple ID 或密碼。簽名由 Xcode 用你自己登入的帳號完成。KeepSigned 只從 Xcode 設定讀取 Team ID 與「是否已登入」。
- **只在本機執行**：沒有伺服器，也不收集任何資料。唯一的對外連線是檢查更新（GitHub Releases，HTTPS）。
- **外部指令**：直接以參數陣列呼叫 `xcodebuild`、`devicectl`、`security`，不經過 shell。所有會變成指令參數的值（Scheme、裝置 ID、專案路徑、Team ID、前綴）都會先用白名單驗證，並拒絕以 `-` 開頭的值，防止參數注入。
- **本機檔案**：設定與紀錄存在 `~/Library/Application Support/KeepSigned/`，資料夾權限 700、檔案權限 600。
- **描述檔處理**：續簽前，會把該 App 的快取描述檔**移到備份資料夾**，不會刪除；建置失敗時會還原。只處理 `application-identifier` 完全相符的描述檔。
- **自動更新**：使用 [Sparkle](https://sparkle-project.org/)。
  - 更新檔和更新清單（appcast）都必須帶有專案 EdDSA 私鑰的簽章，簽章不符就拒絕安裝。
  - 解壓縮前會先驗證簽章。
  - 私鑰只存在維護者電腦的鑰匙圈，不在 repo 裡。

## 已知限制

- KeepSigned 沒有 Apple Developer ID 簽章與公證，第一次打開需要在「系統設定 → 隱私權與安全性」手動允許。請只從本 repo 的 Releases 下載。
- KeepSigned 需要執行 Xcode 工具，所以沒有開啟 App Sandbox。
- KeepSigned 會建置並安裝你選擇的專案，而專案裡的程式碼與建置腳本會以你的身分執行。**請只加入你信任的 App 專案。**
