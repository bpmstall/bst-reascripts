-- bst: Batch rename takes
-- Renames the active take of every selected item with prefix / suffix /
-- search-replace, plus two schemes:
--   "t" in scheme -> TrackName_ItemName   (Wwise-friendly, sanitized)
--   "n" in scheme -> append _001.. numbering (per track)
-- Settings persist in ExtState (also editable in SD Toolbox → Naming).

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local items = lib.selected_items()
if #items == 0 then
  r.MB("Select at least one media item first.", "Ox Rename", 0)
  return
end

local ok, vals = r.GetUserInputs(
  "bst Rename takes (per selected item)",
  5,
  "prefix,find (Lua pattern),replace with,suffix,scheme: t=track_item n=number",
  table.concat({
    lib.ext_get("rn_prefix", ""),
    lib.ext_get("rn_search", ""),
    lib.ext_get("rn_replace", ""),
    lib.ext_get("rn_suffix", ""),
    lib.ext_get("rn_scheme", "t"),
  }, ",")
)
if not ok then return end

local prefix, search, replace, suffix, scheme = vals:match("^([^,]*),([^,]*),([^,]*),([^,]*),(.*)$")
prefix, search, replace = prefix or "", search or "", replace or ""
suffix, scheme = suffix or "", scheme or ""

lib.ext_set("rn_prefix", prefix)
lib.ext_set("rn_search", search)
lib.ext_set("rn_replace", replace)
lib.ext_set("rn_suffix", suffix)
lib.ext_set("rn_scheme", scheme)

r.Undo_BeginBlock()
r.PreventUIRefresh(1)

local renamed = lib.rename_items(items, {
  prefix        = prefix,
  suffix        = suffix,
  search        = search,
  replace       = replace,
  scheme_track  = scheme:find("t") ~= nil,
  scheme_number = scheme:find("n") ~= nil,
})

r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: Rename %d take(s)", renamed), -1)
if lib.last_error then
  r.ShowConsoleMsg(string.format(
    "Ox Rename: stopped early - invalid find pattern (%s)\nApplied to the takes before it anyway.\n",
    lib.last_error))
end
