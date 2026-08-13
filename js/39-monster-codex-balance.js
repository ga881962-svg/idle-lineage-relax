/*
 * 怪物圖鑑數值校正
 * 來源：https://xn--cksr0a.tw/idle2-lineage/site/mobs.html
 * 僅覆蓋圖鑑可比對的等級、HP、AC、MR、經驗、金幣、屬性與習性。
 * 不改動本遊戲的地圖出沒、掉落表、技能和額外活動怪物。
 */
(function applyMonsterCodexBalance() {
  'use strict';

  if (typeof DB === 'undefined' || !DB.mobs) return;

  const balance = {
    "nm_005": {"lv":5,"hp":50,"ac":10,"mr":80,"exp":26,"goldMin":13,"goldMax":36,"e":"earth","beh":"被動"},
    "nm_035": {"lv":5,"hp":30,"ac":10,"mr":30,"exp":26,"goldMin":13,"goldMax":36,"e":"earth","beh":"被動"},
    "giant_croc": {"lv":32,"hp":4000,"ac":-23,"mr":10,"exp":1025,"goldMin":1730,"goldMax":2850,"e":"water","beh":"主動"},
    "bandit_boss": {"lv":35,"hp":5000,"ac":-25,"mr":50,"exp":1226,"goldMin":2050,"goldMax":3360,"e":"none","beh":"主動"},
    "sema": {"lv":42,"hp":8000,"ac":-32,"mr":80,"exp":1765,"goldMin":1500,"goldMax":3000,"e":"none","beh":""},
    "pirate_drake": {"lv":42,"hp":11200,"ac":-35,"mr":50,"exp":1765,"goldMin":292,"goldMax":470,"e":"earth","beh":"主動"},
    "batus": {"lv":43,"hp":8000,"ac":-32,"mr":80,"exp":1850,"goldMin":1500,"goldMax":3000,"e":"none","beh":"主動"},
    "sanct_hellslave": {"lv":43,"hp":962,"ac":-41,"mr":45,"exp":1850,"goldMin":110,"goldMax":300,"e":"earth","beh":"主動"},
    "casper": {"lv":44,"hp":8000,"ac":-32,"mr":80,"exp":1937,"goldMin":1500,"goldMax":3000,"e":"none","beh":"主動"},
    "ant_guard": {"lv":44,"hp":4400,"ac":-48,"mr":60,"exp":1937,"goldMin":100,"goldMax":135,"e":"none","beh":"主動"},
    "marcus": {"lv":45,"hp":8000,"ac":-32,"mr":80,"exp":2026,"goldMin":1500,"goldMax":3000,"e":"none","beh":"主動"},
    "ashitakio": {"lv":45,"hp":1100,"ac":-18,"mr":30,"exp":2026,"goldMin":250,"goldMax":500,"e":"fire","beh":"主動"},
    "ifrit": {"lv":45,"hp":11000,"ac":-38,"mr":40,"exp":2117,"goldMin":2500,"goldMax":4000,"e":"fire","beh":"主動"},
    "wyvern": {"lv":48,"hp":11000,"ac":-58,"mr":80,"exp":2810,"goldMin":2452,"goldMax":11214,"e":"wind","beh":"主動"},
    "blackelder": {"lv":50,"hp":12000,"ac":-45,"mr":90,"exp":2501,"goldMin":2452,"goldMax":11214,"e":"none","beh":"主動"},
    "doppel_boss": {"lv":50,"hp":13000,"ac":-63,"mr":80,"exp":2501,"goldMin":3452,"goldMax":12214,"e":"wind","beh":"主動"},
    "baphomet": {"lv":50,"hp":14000,"ac":-65,"mr":80,"exp":2602,"goldMin":3652,"goldMax":13514,"e":"earth","beh":"主動"},
    "mambo_rabbit": {"lv":50,"hp":4000,"ac":-40,"mr":65,"exp":20000,"goldMin":493,"goldMax":786,"e":"none","beh":"被動"},
    "kurt": {"lv":51,"hp":15000,"ac":-67,"mr":65,"exp":5185,"goldMin":4216,"goldMax":21515,"e":"none","beh":"主動"},
    "iv_karuta": {"lv":51,"hp":12200,"ac":-51,"mr":50,"exp":2601,"goldMin":3000,"goldMax":6000,"e":"wind","beh":"主動"},
    "kari": {"lv":52,"hp":10000,"ac":-45,"mr":100,"exp":3000,"goldMin":10000,"goldMax":20000,"e":"earth","beh":"主動"},
    "dk": {"lv":52,"hp":18000,"ac":-65,"mr":100,"exp":6185,"goldMin":5216,"goldMax":31515,"e":"earth","beh":"主動"},
    "baless": {"lv":53,"hp":15000,"ac":-66,"mr":80,"exp":2802,"goldMin":3852,"goldMax":15514,"e":"earth","beh":"主動"},
    "obli_bigtaurus": {"lv":53,"hp":15000,"ac":-65,"mr":60,"exp":2810,"goldMin":8000,"goldMax":16000,"e":"earth","beh":"主動"},
    "giant_ancient": {"lv":56,"hp":15000,"ac":-63,"mr":70,"exp":3137,"goldMin":10000,"goldMax":20000,"e":"earth","beh":"主動"},
    "ant_queen": {"lv":57,"hp":16000,"ac":-80,"mr":60,"exp":6500,"goldMin":4216,"goldMax":27845,"e":"earth","beh":"主動"},
    "phoenix": {"lv":59,"hp":18500,"ac":-63,"mr":150,"exp":6964,"goldMin":9236,"goldMax":37248,"e":"fire","beh":"主動"},
    "pride_jenis": {"lv":60,"hp":15000,"ac":-50,"mr":70,"exp":3601,"goldMin":5000,"goldMax":10000,"e":"none","beh":"主動"},
    "pride_phantom_boss": {"lv":60,"hp":16000,"ac":-53,"mr":75,"exp":3601,"goldMin":5000,"goldMax":10000,"e":"none","beh":"主動"},
    "pride_vampire_boss": {"lv":60,"hp":15000,"ac":-53,"mr":85,"exp":3601,"goldMin":5000,"goldMax":10000,"e":"earth","beh":"主動"},
    "abyss_lord": {"lv":60,"hp":24000,"ac":-60,"mr":60,"exp":3601,"goldMin":1000,"goldMax":5000,"e":"none","beh":"被動"},
    "nm_034": {"lv":61,"hp":26666,"ac":-75,"mr":100,"exp":6666,"goldMin":6666,"goldMax":66666,"e":"earth","beh":"主動"},
    "de_king_slayer": {"lv":61,"hp":16202,"ac":-71,"mr":75,"exp":3722,"goldMin":1250,"goldMax":4000,"e":"none","beh":"被動"},
    "pride_zombie_king": {"lv":62,"hp":18000,"ac":-58,"mr":50,"exp":3845,"goldMin":10000,"goldMax":20000,"e":"none","beh":"主動"},
    "de_king_baranka": {"lv":63,"hp":17290,"ac":-58,"mr":65,"exp":3970,"goldMin":1250,"goldMax":4000,"e":"water","beh":"被動"},
    "ice_demon": {"lv":65,"hp":18000,"ac":-70,"mr":80,"exp":3600,"goldMin":10000,"goldMax":20000,"e":"none","beh":"主動"},
    "de_king_laia": {"lv":65,"hp":15070,"ac":-57,"mr":80,"exp":4226,"goldMin":1250,"goldMax":4000,"e":"earth","beh":"被動"},
    "pride_panther_boss": {"lv":65,"hp":20000,"ac":-65,"mr":75,"exp":4226,"goldMin":10000,"goldMax":20000,"e":"none","beh":"主動"},
    "pride_mummy_king": {"lv":65,"hp":15000,"ac":-60,"mr":99,"exp":4226,"goldMin":10000,"goldMax":20000,"e":"none","beh":"主動"},
    "pride_iris_boss": {"lv":65,"hp":20000,"ac":-75,"mr":99,"exp":4226,"goldMin":10000,"goldMax":20000,"e":"none","beh":"主動"},
    "fallen_boss": {"lv":68,"hp":6600,"ac":-75,"mr":100,"exp":4625,"goldMin":285,"goldMax":559,"e":"water","beh":"主動"},
    "thebes_anubis": {"lv":70,"hp":25000,"ac":-140,"mr":80,"exp":4901,"goldMin":0,"goldMax":0,"e":"wind","beh":"主動"},
    "thebes_horus": {"lv":70,"hp":20000,"ac":-140,"mr":80,"exp":4901,"goldMin":0,"goldMax":0,"e":"water","beh":"主動"},
    "de_king_heruby": {"lv":70,"hp":22672,"ac":-78,"mr":85,"exp":4901,"goldMin":2250,"goldMax":5000,"e":"earth","beh":"被動"},
    "chaos_boss": {"lv":70,"hp":15000,"ac":-60,"mr":100,"exp":3601,"goldMin":3000,"goldMax":4860,"e":"none","beh":"主動"},
    "death_boss": {"lv":70,"hp":20000,"ac":-65,"mr":100,"exp":4901,"goldMin":3000,"goldMax":4860,"e":"none","beh":"主動"},
    "ice_queen": {"lv":75,"hp":25000,"ac":-65,"mr":60,"exp":5000,"goldMin":9000,"goldMax":18000,"e":"water","beh":"主動"},
    "pride_vander_boss": {"lv":75,"hp":20000,"ac":-70,"mr":80,"exp":5626,"goldMin":10000,"goldMax":20000,"e":"none","beh":"主動"},
    "de_elder_kina": {"lv":78,"hp":16200,"ac":-81,"mr":75,"exp":9612,"goldMin":0,"goldMax":0,"e":"none","beh":"主動"},
    "de_elder_adiel": {"lv":80,"hp":17746,"ac":-85,"mr":75,"exp":10242,"goldMin":0,"goldMax":0,"e":"none","beh":"主動"},
    "pride_lich_boss": {"lv":80,"hp":25000,"ac":-75,"mr":99,"exp":6401,"goldMin":10000,"goldMax":20000,"e":"none","beh":"主動"},
    "pride_reaper_boss": {"lv":80,"hp":40000,"ac":-80,"mr":80,"exp":6401,"goldMin":10000,"goldMax":20000,"e":"none","beh":"主動"},
    "de_elder_batas": {"lv":85,"hp":18600,"ac":-86,"mr":63,"exp":11562,"goldMin":0,"goldMax":0,"e":"none","beh":"主動"},
    "de_elder_balos": {"lv":88,"hp":19997,"ac":-89,"mr":85,"exp":12252,"goldMin":0,"goldMax":0,"e":"none","beh":"主動"},
    "de_elder_taimas": {"lv":90,"hp":21773,"ac":-94,"mr":89,"exp":12962,"goldMin":0,"goldMax":0,"e":"none","beh":"主動"},
    "de_elder_andis": {"lv":91,"hp":22426,"ac":-98,"mr":88,"exp":13326,"goldMin":0,"goldMax":0,"e":"none","beh":"主動"},
    "de_elder_ramas": {"lv":93,"hp":22382,"ac":-98,"mr":81,"exp":13692,"goldMin":0,"goldMax":0,"e":"none","beh":"主動"},
    "de_elder_balud": {"lv":96,"hp":23626,"ac":-98,"mr":100,"exp":14826,"goldMin":0,"goldMax":0,"e":"none","beh":"主動"}
  };

  Object.entries(balance).forEach(([id, values]) => {
    if (DB.mobs[id]) Object.assign(DB.mobs[id], values);
  });

  window.MONSTER_CODEX_BALANCE_VERSION = '2026-08-09';
})();
