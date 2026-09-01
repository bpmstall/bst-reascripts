-- bst: Snap Offset at Peak (无 GUI 动作, 建议绑定快捷键)
-- 把选中 item 的吸附偏移 (D_SNAPOFFSET) 设到各自的 RMS 峰值时刻。
-- 对标 nvk_AUTODOPPLER 的 snap 偏移 EEL; 用于炸点对齐 / 多普勒经过时刻参考。
-- 依赖同目录 bst_lib.lua

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local items = lib.selected_items()
if #items == 0 then
  r.MB("请先选中至少一个 item。", "bst Snap Offset at Peak", 0)
  return
end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)
local n = 0
for _, it in ipairs(items) do
  local t = lib.item_rms_peak_time(it, "rms")
  if t then
    local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
    r.SetMediaItemInfo_Value(it, "D_SNAPOFFSET", t - pos)
    n = n + 1
  end
end
r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: 峰值吸附 %d 个 item", n), -1)
r.ShowConsoleMsg(string.format("bst Snap Offset at Peak: %d 个 item 吸附点已设到 RMS 峰值\n", n))
