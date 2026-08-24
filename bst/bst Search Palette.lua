-- bst: Search Palette (nvk_SEARCH-style, Fluent panel)
-- One input searches: tracks (t), items (i), markers/regions (m),
-- custom scripts (s), plugins (f). Type a prefix + space to force a scope,
-- or search everything at once.
-- Keys: Up/Down move selection - Enter runs - Esc closes.
-- Examples:  "t drum" tracks named drum | "f pro-q" insert plugin on selected track

local r = reaper




if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Search Palette', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)
local ctx = nil

local query = ""
local last_query = nil
local results = {}
local sel = 1
local first_frame = true
local open = true
local status = ""

local SCOPE_OF_PREFIX = { t = "tracks", i = "items", m = "marks", s = "scripts", f = "fx" }
local TAG = { track = "TRK", item = "ITM", mark = "MRK", script = "SCR", fx = "FX " }
local ORDER = { "tracks", "items", "marks", "scripts", "fx" }

--------------------------------------------------------------------------------
-- index

local idx = { tracks = {}, items = {}, marks = {}, scripts = {}, fx = {} }

local function build_index()
  idx.tracks, idx.items, idx.marks, idx.scripts, idx.fx = {}, {}, {}, {}, {}

  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local _, name = r.GetTrackName(tr)
    idx.tracks[#idx.tracks + 1] =
      { name = (name ~= "" and name or ("Track " .. (i + 1))), tr = tr, kind = "track" }
  end

  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    local nm = ""
    local take = r.GetActiveTake(it)
    if take then nm = select(2, r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)) or "" end
    idx.items[#idx.items + 1] = { name = (nm ~= "" and nm or "(untitled)"), item = it, kind = "item" }
  end

  local i = 0
  while true do
    local rv, isrgn, pos, rgnend, name, num = r.EnumProjectMarkers(i)
    if not rv or rv == 0 then break end
    local label = name ~= "" and name or ((isrgn and "Region " or "Marker ") .. tostring(num))
    idx.marks[#idx.marks + 1] = { name = label, pos = pos, isrgn = isrgn, kind = "mark" }
    i = i + 1
  end

  local cfg = r.GetResourcePath()
  local f = io.open(cfg .. "/reaper-kb.ini", "r")
  if f then
    for line in f:lines() do
      local cmdid, desc = line:match('^SCR%s+%d+%s+%d+%s+(%S+)%s+"([^"]*)"')
      if not cmdid then cmdid, desc = line:match('^SCR%s+%d+%s+(%S+)%s+"([^"]*)"') end
      if cmdid and desc and desc ~= "" and desc ~= "--" then
        idx.scripts[#idx.scripts + 1] = { name = desc, cmdid = cmdid, kind = "script" }
      end
    end
    f:close()
  end

  local seen = {}
  for _, ini in ipairs({ "reaper-vstplugins64.ini", "reaper-clap-win64.ini" }) do
    local fh = io.open(cfg .. "/" .. ini, "r")
    if fh then
      for line in fh:lines() do
        local key = line:match("^([^=]+)=")
        if key and #key > 0 and #key < 160 then
          local nm = key:match("([^/\\]+)$") or key
          nm = nm:gsub("%.%w+$", "")
          if #nm > 0 and not seen[nm:lower()] then
            seen[nm:lower()] = true
            idx.fx[#idx.fx + 1] = { name = nm, kind = "fx" }
          end
        end
      end
      fh:close()
    end
  end
end

--------------------------------------------------------------------------------
-- filtering

local function collect(q_raw)
  local q = q_raw:lower()
  local forced = nil
  local pfx = q:match("^([timscf])%s")
  if pfx then
    forced = SCOPE_OF_PREFIX[pfx]
    q = q:sub(3)
  end
  results = {}
  if q == "" then return end
  for _, scope in ipairs(ORDER) do
    if not forced or forced == scope then
      for _, e in ipairs(idx[scope]) do
        local nm = e.name:lower()
        local at = nm:find(q, 1, true)
        if at then
          e.score = (at == 1) and 0 or 1
          results[#results + 1] = e
        end
      end
    end
  end
  table.sort(results, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return a.name:lower() < b.name:lower()
  end)
  if #results > 60 then
    for i = 61, #results do results[i] = nil end
  end
end

--------------------------------------------------------------------------------
-- execution

local function execute(res)
  if res.kind == "track" then
    r.SetOnlyTrackSelected(res.tr)
    status = "Selected track: " .. res.name
  elseif res.kind == "item" then
    r.Main_OnCommand(40289, 0) -- deselect all items
    r.SetMediaItemSelected(res.item, true)
    r.SetEditCurPos(r.GetMediaItemInfo_Value(res.item, "D_POSITION"), true, true)
    r.UpdateArrange()
    status = "Selected item: " .. res.name
  elseif res.kind == "mark" then
    r.SetEditCurPos(res.pos, true, false)
    status = "Cursor to " .. (res.isrgn and "region " or "marker ") .. res.name
  elseif res.kind == "script" then
    -- kb.ini stores bare RS ids; the runtime command name needs the "_"
    local id = r.NamedCommandLookup("_" .. res.cmdid)
    if not id or id == 0 then id = r.NamedCommandLookup(res.cmdid) end
    if id and id ~= 0 then
      open = false
      r.Main_OnCommand(id, 0)
    else
      status = "Cannot resolve: " .. res.cmdid
    end
  elseif res.kind == "fx" then
    local tr = r.GetSelectedTrack(0, 0)
    if not tr and r.CountTracks(0) > 0 then tr = r.GetTrack(0, r.CountTracks(0) - 1) end
    if not tr then status = "Create/select a track first."; return end
    local pos = r.TrackFX_AddByName(tr, res.name, false, -1)
    if pos >= 0 then
      status = string.format("Added %s to '%s'", res.name, (select(2, r.GetTrackName(tr))))
    else
      status = "Plugin not found: " .. res.name
    end
  end
end

--------------------------------------------------------------------------------
-- UI

local function draw_body()
  if first_frame then ImGui.SetKeyboardFocusHere(ctx); first_frame = false end
  local ch, q = ImGui.InputTextWithHint(ctx, "##palette_q",
    "Search... (prefix: t/i/m/s/f + space)", query)
  if ch then query = q end

  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then open = false end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_F5) or ImGui.SmallButton(ctx, "Refresh index") then
    build_index(); last_query = nil
  end
  ImGui.SameLine(ctx)
  fl.caption(ctx, tostring(#results) .. " result(s)")

  if query ~= last_query then
    collect(query)
    last_query = query
    sel = 1
  end

  if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) and sel < #results then sel = sel + 1 end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) and sel > 1 then sel = sel - 1 end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter) then
    if results[sel] then execute(results[sel]); query = ""; last_query = nil end
  end

  local w, h = ImGui.GetContentRegionAvail(ctx)
  if ImGui.BeginChild(ctx, "##results", w, h - 30) then
    for i, res in ipairs(results) do
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x4CC2FFFF)
      ImGui.Text(ctx, TAG[res.kind])
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)
      if ImGui.Selectable(ctx, res.name .. "##r" .. i, i == sel) then
        sel = i
        execute(res)
        query = ""; last_query = nil
      end
    end
  end
  ImGui.EndChild(ctx)

  if status ~= "" then fl.infobar(ctx, nil, status) end
end

-- All ReaScripts share one global Lua environment: this plain global is a
-- singleton lock, so launching the action twice doesn't spawn twin instances
-- (twins closing free each other's context and crash the surviving panel).
if BST_SP_LIVE and ImGui.ValidatePtr(BST_SP_LIVE, 'ImGui_Context*') then
  return -- panel already open
end
ctx = ImGui.CreateContext('bst Search')
BST_SP_LIVE = ctx
fl.attach_fonts(ctx)
build_index()

local function loop()
  if not ctx or not ImGui.ValidatePtr(ctx, 'ImGui_Context*') then
    return -- stale instance from an older run; its context is gone
  end
  -- Whole frame protected: if the context dies mid-frame (a duplicate or
  -- stale instance was torn down), stop quietly instead of erroring forever.
  local okf, xopen = pcall(function()
    ImGui.SetNextWindowSize(ctx, 520, 430, ImGui.Cond_Appearing)
    local nc, nv = fl.push_theme(ctx)
    -- second Begin return is the title-bar X button state; ignoring it made
    -- the close click look dead (window just redrawn next frame)
    local visible, topen = ImGui.Begin(ctx, 'bst Search', true,
      ImGui.WindowFlags_NoCollapse)
    if visible then
      local ok, e = pcall(draw_body)
      if not ok then
        status = "error: " .. tostring(e)
        r.ShowConsoleMsg("bst Search Palette: " .. tostring(e) .. "\n")
        for _ = 1, 8 do if not pcall(ImGui.EndChild, ctx) then break end end
      end
      ImGui.End(ctx)
    end
    fl.pop_theme(ctx, nc, nv)
    return topen
  end)
  if not okf or not open or xopen == false then
    if not okf then -- one-line diagnosis instead of a silent close
      r.ShowConsoleMsg("bst Search Palette: frame aborted, closing (" .. tostring(xopen) .. ")\n")
    end
    if BST_SP_LIVE == ctx then BST_SP_LIVE = nil end
    -- no explicit DestroyContext: ReaImGui frees contexts when the script
    -- stops deferring; explicit destruction yanks the pointer from under any
    -- sibling instance on builds that still export it
    return
  end
  r.defer(loop)
end

r.defer(loop)
