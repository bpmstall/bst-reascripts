-- bst: Randomize Positions (无 GUI 动作, 建议绑定快捷键)
-- 时选内随机摆位: 选中 item 各自在时选范围内随机平移 (保留原时选)。
-- 对标 LKC Variator 的 position 随机化; 用于脚步/Foley 铺位去机械感。
-- 恢复: 撤销 (Ctrl+Z) 即可。
-- 依赖同目录 bst_lib.lua

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
ts, te = ts or 0, te or 0
local items = lib.selected_items()
if #items == 0 then
  r.MB("请先选中至少一个 item。", "bst Randomize Positions", 0)
  return
end
if te - ts < 0.01 then
  r.MB("请先框选时间选区 (随机摆位范围)。", "bst Randomize Positions", 0)
  return
end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)
local span = te - ts
local n = 0
for _, it in ipairs(items) do
  local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
  if len < span then
    local newpos = ts + math.random() * (span - len)
    r.SetMediaItemInfo_Value(it, "D_POSITION", newpos)
    n = n + 1
  end
end
r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: 随机摆位 %d 个 item", n), -1)
r.ShowConsoleMsg(string.format("bst Randomize Positions: %d 个 item 已在时选内随机摆位\n", n))
