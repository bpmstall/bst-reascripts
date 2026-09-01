-- bst: Play Next Item (无 GUI 动作, 建议绑定快捷键)
-- 试听导航: 跳到下一个 item 开头并播放 (保持播放状态)。
-- 对标 nvk_ITEMS 的逐条试听; 用于快速过听素材库。
-- 依赖同目录 bst_lib.lua

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local STEP = 1

-- 收集全部 item 按时间排序
local items = {}
for i = 0, r.CountMediaItems(0) - 1 do items[#items + 1] = r.GetMediaItem(0, i) end
if #items == 0 then return end
table.sort(items, function(a, b)
  return r.GetMediaItemInfo_Value(a, "D_POSITION") < r.GetMediaItemInfo_Value(b, "D_POSITION")
end)

-- 参照 item = 第一个选中 item; 没有则取播放位置/光标所在 item
local ref, ref_i = nil, 1
local sel = lib.selected_items()
if #sel > 0 then ref = sel[1] end
if not ref then
  local pt = (r.GetPlayState() ~= 0) and r.GetPlayPosition() or r.GetCursorPosition()
  for i, it in ipairs(items) do
    local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
    local e = p + r.GetMediaItemInfo_Value(it, "D_LENGTH")
    if pt >= p and pt < e then ref = it ref_i = i break end
  end
  ref = ref or items[1]
end
for i, it in ipairs(items) do
  if it == ref then ref_i = i break end
end

local ni = ref_i + STEP
if ni < 1 then ni = #items elseif ni > #items then ni = 1 end
local nxt = items[ni]

r.Main_OnCommand(40289, 0) -- 取消全部 item 选择
r.SetMediaItemSelected(nxt, true)
local start = r.GetMediaItemInfo_Value(nxt, "D_POSITION")
r.SetEditCurPos(start, true, true)
if r.GetPlayState() == 0 then r.Main_OnCommand(1007, 0) end -- 播放
r.UpdateArrange()
