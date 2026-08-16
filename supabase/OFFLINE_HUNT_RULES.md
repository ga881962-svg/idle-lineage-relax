# 離線掛機 authoritative 資料方案

## 唯一資料來源

- 怪物、地圖怪物池：`js/00-data.js` 的 `DB.mobs`、`DB.maps`。
- 一般靜態掉落：`js/01-drops-config.js` 的 `MOB_DROPS`、`DARK_WEAPON_DROPS`、`DARK_CRYSTAL_DROPS`、`DRAGON_DROPS`、`WARRIOR_DROPS`、`MEM_DROPS`。
- 線上擊殺結算：`js/05-kill-progression.js` 的 `killMob()`、`monsterGoldRange()`、`partyExpBonusPct()`、`partyRewardMult()` 與 `partyDropRate()`。

伺服器 catalog migration 是上述 canonical JS 的建置產物，不是另一份可手改的遊戲資料。前端只回報 map ID、mob ID 與 request ID；EXP、金幣、掉落結果及每分鐘收益不得作為 API 輸入。

## 最小同步流程

1. 修改怪物、地圖、掉落或其線上結算規則後，執行 `npm run build:offline-catalog` 重建 `202608160000_offline_hunt_catalog.sql`。
2. 執行 `npm run verify:offline-catalog`。來源 hash 不一致必須失敗，禁止部署舊 catalog。
3. catalog 與結算 migration 一起審查、一起發布。既有 departure 會綁定 catalog hash；離線期間版本改變時拒絕混版結算。

catalog 由 `tools/build-offline-hunt-catalog.cjs` 產生，包含怪物 hard／boss／noGold 資訊、地圖池、六種靜態掉落表的來源類別，以及區域與試煉規則的 metadata。它只解析 canonical JS 並覆寫建置產物，不建立人工維護的第二套資料庫。

## 效率與收益

伺服器以收到時間計算已驗證擊殺率，並以樣本中的實際 mob 組成推估離線擊殺；沒有可信樣本就不結算。EXP、金幣與靜態掉落只從綁定版本的 server catalog 計算。一般怪金幣沿用線上的等級曲線與 70% 掉錢率；頭目使用其設定區間。

目前 migration 尚未把 catalog 的 hard／掉落類別與條件 metadata 接進完整的 departure 規則快照；因此這版不得宣稱完整等同所有線上倍率。尤其贊助券仍只有前端存檔來源、動態世界旗標與卡片掉落尚無伺服器來源。這些規則不能由前端傳值補足，也不可用固定 EXP/min、Gold/min 取代。
