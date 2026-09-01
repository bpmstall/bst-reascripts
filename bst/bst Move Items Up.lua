-- bst: Move Items Up (无 GUI 动作, 建议绑定快捷键)
-- 选中 item 整体移到上一条轨道 (保持时间位置)。对标 nvk_ITEMS 移轨。
-- 依赖同目录 bst_lib.lua

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local TITLE = "Move Items Up"
local DELTA = -1

local items = lib.selected_items()
if #items == 0 then
  r.MB("请先选中至少一个 item。", TITLE, 0)
  return
end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)
local n = 0
for _, it in ipairs(items) do
  local tr = lib.item_track(it)
  local id = r.CSurf_TrackToID(tr, false) or 0
  local nid = id + DELTA
  if nid >= 1 and nid <= r.CountTracks(0) then
    local ntr = r.CSurf_TrackFromID(nid, false)
    if ntr and r.MoveMediaItemToTrack(it, ntr) then n = n + 1 end
  end
end
r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: 移动 %d 个 item (%s)", n, TITLE), -1)
if n == 0 then r.ShowConsoleMsg("bst Move: 没有可移动的 item (已到边界?)\n") end
