-- bst: Decontaminate (无 GUI 动作, 建议绑定快捷键)
-- 还原选中 item 的变奏/随机参数: 音量=1, 声像=中, 音高=0, 播放速率=1。
-- 对标 LKC Variator 的 Decontaminate —— 变奏/随机摆位后一键回干净态。
-- 不动: 长度/位置/淡化/take。

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local items = lib.selected_items()
if #items == 0 then
  r.MB("请先选中至少一个 item。", "bst Decontaminate", 0)
  return
end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)
local n = 0
for _, it in ipairs(items) do
  r.SetMediaItemInfo_Value(it, "D_VOL", 1)
  local take = r.GetActiveTake(it)
  if take then
    r.SetMediaItemTakeInfo_Value(take, "D_PAN", 0)
    r.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
    r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1)
  end
  n = n + 1
end
r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: Decontaminate %d 个 item", n), -1)
r.ShowConsoleMsg(string.format("bst Decontaminate: %d 个 item 已还原 (vol/pan/pitch/rate)\\n", n))
