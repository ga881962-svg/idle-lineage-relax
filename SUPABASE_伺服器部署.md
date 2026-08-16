# 雲端伺服器部署

目前已完成的雲端資料：帳號、8 個角色欄位、角色身分、存檔檢查點與操作紀錄。

這個資料夾內的 `supabase/functions/game-api/index.ts` 是遊戲伺服器的第一個入口。它只接受已登入玩家的請求，並只允許讀取自己的角色與存檔；不能由瀏覽器直接寫入金幣、等級或物品。

## 部署前準備

1. 安裝 Supabase CLI：到 Supabase 官方 CLI 安裝頁，依 Windows 指示安裝。
2. 開啟 PowerShell，切換至這個遊戲資料夾。
3. 執行 `supabase login`，瀏覽器會要求登入你的 Supabase 帳號；不用把任何 Token 傳給我。
4. 執行：

```powershell
supabase link --project-ref fsolkoidqqzwjitbycds
supabase functions deploy game-api
```

部署完成後，雲端入口網址會是：

```text
https://fsolkoidqqzwjitbycds.supabase.co/functions/v1/game-api
```

## 目前刻意尚未開放的事情

目前不接受瀏覽器直接上傳「整包角色資料」。這是為了避免有人把瀏覽器內的金幣、經驗、掉落物改成任意數字再存到雲端。

下一階段會由伺服器接手：戰鬥結算、掉落、離線收益、GM 發送與存檔寫入。每次操作會驗證玩家、角色歸屬、地圖與可用時間，再寫入操作紀錄。
