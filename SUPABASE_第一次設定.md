# 放置天堂－休閒養老：Supabase 第一次設定

這份設定只建立線上帳號與空白角色資料結構；不會匯入或更動目前單機版角色。

## 1. 建立資料表與安全規則

1. 進入 Supabase 專案左側的 **SQL Editor**。
2. 點 **New query**。
3. 開啟同資料夾的 `online-schema.sql`，完整複製貼上。
4. 按右下角 **Run**。
5. 成功時畫面會回傳四個資料表名稱：
   `account_wallets`、`gm_audit_log`、`player_characters`、`player_profiles`。

資料表已啟用保護規則：玩家只能讀自己的資料，不能從瀏覽器直接竄改金幣、贊助鑽石、掉落或角色等級。

## 2. 開啟帳密註冊

到 **Authentication → Providers → Email**，確認 Email provider 已啟用。
測試階段可以保留 Email confirmation 開啟；註冊者需要先點信箱中的驗證連結。

## 3. Google 登入（可稍後設定）

遊戲畫面已有「使用 Google 登入」按鈕。要讓它可用，還需要：

1. 在 Google Cloud 建立 OAuth 網頁用戶端。
2. 將 Client ID 與 Client secret 填入 **Authentication → Providers → Google**。
3. 在 Supabase 的 **Authentication → URL Configuration** 加入日後的正式網站網址；本機測試可加入 `http://127.0.0.1:8765`。

不要把資料庫密碼、Service role 或 Secret key 放進遊戲前端或傳給任何人。

## 下一階段

完成以上設定後，回傳 SQL Editor 的成功畫面。我會接著建立「建立角色、雲端讀檔、伺服器端結算與安全存檔」；到那一步才會正式做到網頁與 Windows 安裝版共用同一份角色。

## 第二階段：雲端角色名冊

登入確認完成後，在 SQL Editor 以同一方式執行 `online-character-roster.sql`。
它會安全建立「每帳號最多 8 名角色」的建立與讀取功能；尚不允許瀏覽器寫入金幣、掉落或等級。

## 第三階段：雲端進度保護區

執行 `online-progress-schema.sql` 後，會建立角色進度快照與事件紀錄。玩家只能讀取自己的資料，所有進度寫入會留給後續的遊戲伺服器處理，避免公開版可直接改數字。
