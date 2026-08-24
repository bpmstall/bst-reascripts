-- bst: Variation generator
-- For each selected audio item, creates N duplicates placed sequentially
-- after it (item length + gap), each randomized in pitch / volume / pan.
-- Inspired by nvk_VARIATIONS: instant unique variations for game audio.
--
-- Ranges persist in ExtState (also editable in SD Toolbox → Variations):
--   var_count (default 1), var_pitch_st (2), var_vol_db (1.5),
--   var_pan (0 = off), var_gap_s (0.01), var_ppitch (1 = preserve pitch)
-- Note: duplicates may overlap later content on the same track — use empty
-- lanes below your source material.

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local items = lib.selected_items()
if #items == 0 then
  r.MB("Select at least one media item first.", "bst Variations", 0)
  return
end

math.randomseed(os.time())

r.Undo_BeginBlock()
r.PreventUIRefresh(1)

local created, skipped = lib.generate_variations(items, {
  count    = lib.ext_getnum("var_count", 1),
  pitch_st = lib.ext_getnum("var_pitch_st", 2.0),
  vol_db   = lib.ext_getnum("var_vol_db", 1.5),
  pan      = lib.ext_getnum("var_pan", 0.0),
  gap_s    = lib.ext_getnum("var_gap_s", 0.01),
  ppitch   = lib.ext_getnum("var_ppitch", 1) >= 1,
})

r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: Generate %d variation(s)", created), -1)
r.ShowConsoleMsg(string.format("bst Variations: %d created, %d skipped (%s)\n",
  created, #skipped, table.concat(skipped, ", ")))
