-- bst: Normalize selected items to target peak (dBFS)
-- Scans each selected item's actual playback audio (pre-track-FX, includes
-- fades/pitch/playrate) and adjusts item volume so its peak hits the target.
-- One undo step. Target persists in ExtState (default -1.0 dBFS).

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local TARGET_DB = lib.ext_getnum("norm_target_db", -1.0)

local items = lib.selected_items()
if #items == 0 then
  r.MB("请先选中至少一个 item。", "bst 归一化", 0)
  return
end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)

local done, skipped = 0, 0
for i = 1, #items do
  local item = items[i]
  local peak = lib.item_peak(item)
  if peak and peak > 0.000001 then
    local scale = lib.db2lin(TARGET_DB) / peak
    local cur = r.GetMediaItemInfo_Value(item, "D_VOL")
    r.SetMediaItemInfo_Value(item, "D_VOL", cur * scale)
    done = done + 1
  else
    skipped = skipped + 1
  end
end

r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: 归一化 %d 个 item 到 %.1f dBFS 峰值", done, TARGET_DB), -1)
r.ShowConsoleMsg(
  string.format("bst 归一化: %d 个已到 %.1f dBFS，跳过 %d 个（MIDI/空/静音）\n",
    done, TARGET_DB, skipped))
