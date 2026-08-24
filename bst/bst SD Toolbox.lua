-- bst: Sound Design Toolbox (Fluent 2 styled ReaImGui panel)
-- Tabs: Variations | Fades | Normalize | Naming | Render | Session
-- UI built on bst_fluent.lua (WinUI tokens). Logic on lib.lua.
-- Settings persist globally (ExtState "OxTools") shared with bst *.lua scripts.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展才能运行。

安装方法:
1. 菜单 Extensions → ReaPack → Browse packages
2. 搜索 "reaimgui" (作者 cfillion), 点 Install
3. 重启 REAPER 后再次运行本脚本

若尚未安装 ReaPack, 请先到 https://www.reapack.com 下载', 'bst Sound Design Toolbox', 0)
  return
end

package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'   -- top level, never inside pcall

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)
-- All ReaScripts share one global Lua environment: this plain global is a
-- singleton lock, so launching the action twice doesn't spawn twin instances
-- (twins closing free each other's context and crash the surviving panel).
if BST_SDT_LIVE and ImGui.ValidatePtr(BST_SDT_LIVE, 'ImGui_Context*') then
  return -- panel already open
end
local ctx = ImGui.CreateContext('bst SD Toolbox')
BST_SDT_LIVE = ctx

--------------------------------------------------------------------------------
-- persistent state (loaded once, written through on every change)

local st = {
  var_count    = math.floor(lib.ext_getnum("var_count", 1)),
  var_pitch_st = lib.ext_getnum("var_pitch_st", 2.0),
  var_vol_db   = lib.ext_getnum("var_vol_db", 1.5),
  var_pan      = lib.ext_getnum("var_pan", 0.0),
  var_gap_ms   = lib.ext_getnum("var_gap_s", 0.01) * 1000,
  var_ppitch   = lib.ext_getnum("var_ppitch", 1),

  fade_in_ms   = lib.ext_getnum("fade_in_ms", 10),
  fade_out_ms  = lib.ext_getnum("fade_out_ms", 30),
  fade_shape   = math.floor(lib.ext_getnum("fade_shape", 0)),

  norm_target  = lib.ext_getnum("norm_target_db", -1.0),

  rn_prefix    = lib.ext_get("rn_prefix", ""),
  rn_search    = lib.ext_get("rn_search", ""),
  rn_replace   = lib.ext_get("rn_replace", ""),
  rn_suffix    = lib.ext_get("rn_suffix", ""),
  rn_track     = lib.ext_getnum("rn_track", 1),
  rn_number    = lib.ext_getnum("rn_number", 0),

  render_dir   = lib.ext_get("render_dir", ""),
  render_pat   = lib.ext_get("render_pattern", "$track_$item"),
  render_fmt_i = math.floor(lib.ext_getnum("render_fmt_i", 1)),
  render_sr_i  = math.floor(lib.ext_getnum("render_sr_i", 1)),
  render_mono  = lib.ext_getnum("render_mono", 0),

  bus_DES = 1, bus_AMB = 1, bus_FOL = 1, bus_INT = 1, bus_MX = 1, bus_DLG = 0,
}

local FMTS = { "WAV 24-bit", "WAV 16-bit", "REAPER WAV defaults" }
local FMT_CODES = { "ZXZhdxgB", "ZXZhdxAB", "evaw" }
local SRATES = { "Project rate", "48000 Hz", "44100 Hz" }
local RATE_VALUES = { 0, 48000, 44100 }

local msg = "Select items in the arrange view, then run an action."
local sev = nil -- "ok" | "warn" | "bad" | nil(info)
local err = nil

local BUSES = {
  { key = "bus_DES", name = "DES", desc = "Designed",     rgb = { 232, 116,  33 } },
  { key = "bus_AMB", name = "AMB", desc = "Ambience",     rgb = {  76, 175,  80 } },
  { key = "bus_FOL", name = "FOL", desc = "Foley",        rgb = { 161, 106,  61 } },
  { key = "bus_INT", name = "INT", desc = "Interface/UI", rgb = {   0, 188, 212 } },
  { key = "bus_MX",  name = "MX",  desc = "Music",        rgb = { 156,  89, 182 } },
  { key = "bus_DLG", name = "DLG", desc = "Dialogue",     rgb = {  63,  81, 181 } },
}

--------------------------------------------------------------------------------
-- widget helpers (bind state keys + persist)


local function set_num(key, v) st[key] = v; lib.ext_set(key, v) end

local function input_int(label, key, min)
  local ch, v = ImGui.InputInt(ctx, label, st[key])
  if ch then
    v = math.floor(v)
    if min and v < min then v = min end
    set_num(key, v)
  end
end

local function slider_d(label, key, mn, mx, fmt)
  local ch, v = ImGui.SliderDouble(ctx, label, st[key], mn, mx, fmt or '%.2f')
  if ch then set_num(key, v) end
end

local function slider_int(label, key, mn, mx)
  local ch, v = ImGui.SliderInt(ctx, label, st[key], mn, mx, '%d')
  if ch then set_num(key, v) end
end

local function toggle_key(label, key)
  local nv = fl.toggle(ctx, label, st[key] >= 1)
  if (nv and 1 or 0) ~= st[key] then set_num(key, nv and 1 or 0) end
end

local function combo(label, key, items)
  -- ReaImGui Combo takes a NUL-terminated item string and a 0-BASED index;
  -- stored values stay 1-based Lua indices
  local ch, v = ImGui.Combo(ctx, label, (st[key] or 1) - 1,
    table.concat(items, "\0") .. "\0")
  if ch then st[key] = math.floor(v) + 1; lib.ext_set(key, st[key]) end
end

local function input_text(label, key)
  local ch, v = ImGui.InputText(ctx, label, st[key] or "")
  if ch and v ~= nil then st[key] = v; lib.ext_set(key, v) end
end

--------------------------------------------------------------------------------
-- actions (each = one undo point)

local function need_items()
  if r.CountSelectedMediaItems(0) == 0 then
    msg, sev = "No items selected.", "warn"
    return true
  end
  return false
end

local function act_generate()
  if need_items() then return end
  math.randomseed(os.time())
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local created = lib.generate_variations(lib.selected_items(), {
    count    = st.var_count,
    pitch_st = st.var_pitch_st,
    vol_db   = st.var_vol_db,
    pan      = st.var_pan,
    gap_s    = st.var_gap_ms / 1000,
    ppitch   = st.var_ppitch >= 1,
  })
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Generate %d variation(s)", created), -1)
  msg, sev = string.format("Created %d variation(s).", created), "ok"
end

local function apply_fades(len_in, len_out)
  if need_items() then return end
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local n = 0
  for _, item in ipairs(lib.selected_items()) do
    r.SetMediaItemInfo_Value(item, "D_FADEINLEN", len_in)
    r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", len_out)
    r.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", st.fade_shape)
    r.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", st.fade_shape)
    n = n + 1
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Fades on %d item(s)", n), -1)
  msg, sev = string.format("Applied fades to %d item(s).", n), "ok"
end

local function act_normalize()
  if need_items() then return end
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local done, skipped = 0, 0
  for _, item in ipairs(lib.selected_items()) do
    local peak = lib.item_peak(item)
    if peak and peak > 0.000001 then
      r.SetMediaItemInfo_Value(item, "D_VOL",
        r.GetMediaItemInfo_Value(item, "D_VOL") * lib.db2lin(st.norm_target) / peak)
      done = done + 1
    else
      skipped = skipped + 1
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Normalize %d item(s) to %.1f dBFS", done, st.norm_target), -1)
  msg, sev = string.format("Normalized %d item(s) (%d skipped: MIDI/silent).",
    done, skipped), done > 0 and "ok" or "warn"
end

local function act_rename()
  if need_items() then return end
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local renamed = lib.rename_items(lib.selected_items(), {
    prefix        = st.rn_prefix,
    suffix        = st.rn_suffix,
    search        = st.rn_search,
    replace       = st.rn_replace,
    scheme_track  = st.rn_track >= 1,
    scheme_number = st.rn_number >= 1,
  })
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Rename %d take(s)", renamed), -1)
  if lib.last_error then
    msg, sev = "Rename: invalid find pattern (" .. lib.last_error .. ")", "bad"
  else
    msg, sev = string.format("Renamed %d take(s).", renamed), "ok"
  end
end

local function choose_folder()
  local ok, d = r.GetUserFileName(3, "Choose render output folder", st.render_dir, "")
  if ok and d and d ~= "" then
    st.render_dir = d:gsub("[%/\\]+$", "")
    lib.ext_set("render_dir", st.render_dir)
    msg, sev = "Output folder: " .. st.render_dir, nil
  end
end

local function act_render()
  if need_items() then return end
  if st.render_dir == "" then
    msg, sev = "Choose an output folder first.", "warn"
    return
  end
  local items = lib.selected_items()
  local out_dir = st.render_dir:gsub("[%/\\]+$", "") .. "/"
  lib.render_items(items, out_dir, {
    pattern = st.render_pat ~= "" and st.render_pat or "$track_$item",
    format  = FMT_CODES[st.render_fmt_i] or "evaw",
    srate   = RATE_VALUES[st.render_sr_i] or 0,
    mono    = st.render_mono >= 1,
  })
  msg, sev = string.format("Rendered %d item(s) to %s", #items, out_dir), "ok"
end

local function act_session()
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local made = 0
  for _, bus in ipairs(BUSES) do
    if st[bus.key] >= 1 then
      local idx = r.CountTracks(0)
      r.InsertTrackAtIndex(idx, false)
      local tr = r.GetTrack(0, idx)
      r.GetSetMediaTrackInfo_String(tr, "P_NAME", bus.name, true)
      r.SetTrackColor(tr, r.ColorToNative(bus.rgb[1], bus.rgb[2], bus.rgb[3]) | 0x1000000)
      made = made + 1
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Create %d bus track(s)", made), -1)
  msg, sev = string.format("Created %d bus track(s) at project end.", made), "ok"
end

--------------------------------------------------------------------------------
-- tabs (Fluent widgets)

local function draw_tab_variations()
  input_int("Count##var", "var_count", 1)
  slider_d("Pitch range +- (st)", "var_pitch_st", 0, 12, '%.1f')
  slider_d("Volume range +- (dB)", "var_vol_db", 0, 6, '%.1f')
  slider_d("Pan spread", "var_pan", 0, 1, '%.2f')
  input_int("Gap (ms)##var", "var_gap_ms", 0)
  toggle_key("Preserve pitch (vs varispeed)", "var_ppitch")
  if fl.button(ctx, "Generate variations", { accent = true, width = 170 }) then
    act_generate()
  end
end

local function draw_tab_fades()
  slider_int("Fade shape (0=linear..6)", "fade_shape", 0, 6)
  local ch, v = ImGui.InputDouble(ctx, "Fade in (ms)", st.fade_in_ms, 5, 50, '%.1f')
  if ch then set_num("fade_in_ms", math.max(0, v)) end
  ch, v = ImGui.InputDouble(ctx, "Fade out (ms)", st.fade_out_ms, 5, 50, '%.1f')
  if ch then set_num("fade_out_ms", math.max(0, v)) end
  if fl.button(ctx, "Apply fades", { accent = true, width = 120 }) then
    apply_fades(st.fade_in_ms / 1000, st.fade_out_ms / 1000)
  end
  ImGui.SameLine(ctx)
  if fl.button(ctx, "Zero fades", { width = 100 }) then apply_fades(0, 0) end
end

local function draw_tab_normalize()
  slider_d("Target peak (dBFS)", "norm_target", -12, 0, '%.1f')
  if fl.button(ctx, "Normalize selected", { accent = true, width = 170 }) then
    act_normalize()
  end
  ImGui.SameLine(ctx)
  fl.caption(ctx, "Scans real playback audio (incl. fades/pitch)")
end

local function draw_tab_naming()
  input_text("Prefix##rn", "rn_prefix")
  input_text("Find (Lua pattern)", "rn_search")
  input_text("Replace with", "rn_replace")
  input_text("Suffix##rn", "rn_suffix")
  toggle_key("Scheme: TrackName_ItemName", "rn_track")
  toggle_key("Numbering _001 per track", "rn_number")
  if fl.button(ctx, "Rename selected takes", { accent = true, width = 180 }) then
    act_rename()
  end
end

local function draw_tab_render()
  fl.begin_card(ctx, "##card_render")
    fl.caption(ctx, "EXPORT")
    input_text("Filename pattern ($track $item...)", "render_pat")
    combo("Format##rdr", "render_fmt_i", FMTS)
    combo("Sample rate", "render_sr_i", SRATES)
    toggle_key("Force mono", "render_mono")
    fl.caption(ctx, "Folder: " .. (st.render_dir ~= "" and st.render_dir or "(not set)"))
    if fl.button(ctx, "Choose folder...", { width = 130 }) then choose_folder() end
    ImGui.SameLine(ctx)
    if fl.button(ctx, "Render selected", { accent = true, width = 140 }) then act_render() end
  fl.end_card(ctx)
  fl.caption(ctx, "Silent export, one WAV per item, project settings restored after.")
end

local function draw_tab_session()
  ImGui.TextWrapped(ctx,
    "Create a standard sound-design bus structure at project end (UCS-style prefixes).")
  fl.begin_card(ctx, "##card_buses")
    fl.caption(ctx, "BUSES")
    for _, bus in ipairs(BUSES) do
      toggle_key(bus.name .. "  (" .. bus.desc .. ")", bus.key)
    end
    if fl.button(ctx, "Create buses", { accent = true, width = 140 }) then act_session() end
  fl.end_card(ctx)
end

--------------------------------------------------------------------------------
-- frame / loop

local TABS = {
  { "Variations", draw_tab_variations },
  { "Fades",      draw_tab_fades },
  { "Normalize",  draw_tab_normalize },
  { "Naming",     draw_tab_naming },
  { "Render",     draw_tab_render },
  { "Session",    draw_tab_session },
}

local function draw_body()
  fl.subtitle(ctx, "Sound Design Toolbox")
  ImGui.Spacing(ctx)
  if ImGui.BeginTabBar(ctx, 'ox_tabs') then
    for _, tab in ipairs(TABS) do
      if ImGui.BeginTabItem(ctx, tab[1]) then
        ImGui.Spacing(ctx)
        tab[2]()
        ImGui.EndTabItem(ctx)
      end
    end
    ImGui.EndTabBar(ctx)
  end
  ImGui.Dummy(ctx, 0, 4)
  ImGui.Separator(ctx)
  ImGui.TextDisabled(ctx, string.format("%d item(s) selected", r.CountSelectedMediaItems(0)))
  if err then
    fl.infobar(ctx, "bad", "Error: " .. tostring(err))
  else
    fl.infobar(ctx, sev, msg)
  end
end

fl.attach_fonts(ctx)

local function loop()
  if not ctx or not ImGui.ValidatePtr(ctx, 'ImGui_Context*') then
    return -- stale instance from an older run; its context is gone
  end
  -- Whole frame protected: if the context dies mid-frame (a duplicate or
  -- stale instance was torn down), stop quietly instead of erroring forever.
  local okf, open = pcall(function()
    ImGui.SetNextWindowSize(ctx, 540, 560, ImGui.Cond_FirstUseEver)
    local nc, nv = fl.push_theme(ctx)
    local visible, op = ImGui.Begin(ctx, 'bst SD Toolbox', true)
    if visible then
      local ok, e = pcall(draw_body)
      err = ok and nil or tostring(e)
      if not ok then
        r.ShowConsoleMsg("bst SD Toolbox: " .. tostring(e) .. "\n")
        for _ = 1, 8 do if not pcall(ImGui.EndChild, ctx) then break end end
      end
      ImGui.End(ctx)
    end
    fl.pop_theme(ctx, nc, nv)
    return op
  end)
  if not okf or not open then
    if not okf then -- one-line diagnosis instead of a silent close
      r.ShowConsoleMsg("bst SD Toolbox: frame aborted, closing (" .. tostring(open) .. ")\n")
    end
    if BST_SDT_LIVE == ctx then BST_SDT_LIVE = nil end
    -- no explicit DestroyContext: ReaImGui frees contexts when the script
    -- stops deferring; explicit destruction yanks the pointer from under any
    -- sibling instance on builds that still export it
    return
  end
  r.defer(loop)
end

r.defer(loop)
