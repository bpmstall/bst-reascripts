-- bst: Quick Variations (Medium) (无 GUI 动作, 建议绑定快捷键)
-- 快速变奏公式动作 (无 GUI): Medium 档。对标 LKC Variator 的公式动作分离,
-- 需要细调请用 bst Variations Studio 面板。
-- 依赖同目录 bst_lib.lua

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local TITLE = "Medium"
local FORMULA = {
  count = 2,
  pitch_st = 2.0,
  vol_db = 1.5,
  pan = 0.25,
  gap_s = 0.01,
  fade_max_ms = 40,
}

local items = lib.selected_items()
if #items == 0 then
  r.MB("请先选中至少一个 item。", TITLE, 0)
  return
end

math.randomseed(os.time())
r.Undo_BeginBlock()
r.PreventUIRefresh(1)
local created, skipped = lib.generate_variations(items, {
  count       = FORMULA.count,
  pitch_st    = FORMULA.pitch_st,
  vol_db      = FORMULA.vol_db,
  pan         = FORMULA.pan,
  gap_s       = FORMULA.gap_s,
  ppitch      = true,
  fade_max_ms = FORMULA.fade_max_ms,
})
r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: 快速变奏 (%s) %d 个", TITLE, created), -1)
r.ShowConsoleMsg(string.format("bst Quick Variations (%s): %d 个变奏, %d 跳过\n",
  TITLE, created, #skipped))
