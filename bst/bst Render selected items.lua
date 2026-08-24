-- bst: Render selected items to WAV (silent batch export for game audio)
-- Renders every selected media item as an individual WAV file named
-- "TrackName_ItemName.wav" into the configured folder, without opening
-- the render dialog. Previous render settings are saved and restored.
--
-- First run asks for the output folder once; afterwards it reuses the
-- last folder (also configurable in the SD Toolbox → Render tab).

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local items = lib.selected_items()
if #items == 0 then
  r.MB("Select at least one media item first.", "bst Render", 0)
  return
end

local out_dir = lib.ext_get("render_dir", "")
if out_dir == "" then
  local ok, d = r.GetUserFileName(3, "bst Render: choose output folder", "", "")
  if not ok or d == nil or d == "" then return end
  out_dir = d
end
out_dir = out_dir:gsub("[%/\\]+$", "") .. "/"

lib.render_items(items, out_dir, {
  pattern = lib.ext_get("render_pattern", "$track_$item"),
  format  = lib.ext_get("render_format", "evaw"),
  srate   = lib.ext_getnum("render_srate", 0),
  mono    = lib.ext_getnum("render_mono", 0) >= 1,
})

r.ShowConsoleMsg(string.format("bst Render: %d item(s) -> %s\n", #items, out_dir))
