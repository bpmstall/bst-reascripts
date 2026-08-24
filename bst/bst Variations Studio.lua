-- bst: Variations Studio (nvk_VARIATIONS-style, Fluent panel)
-- Full variation generator: ranges, placement modes, random fades, presets.
-- Sequential = copies placed one after another on the source track (export batch).
-- Stacked    = all variations layered at identical positions on a new "<track> VAR"
--              track (audition/layering). Presets persist in ExtState "OxTools".

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展才能运行。

安装方法:
1. 菜单 Extensions → ReaPack → Browse packages
2. 搜索 "reaimgui" (作者 cfillion), 点 Install
3. 重启 REAPER 后再次运行本脚本

若尚未安装 ReaPack, 请先到 https://www.reapack.com 下载', 'bst Variations Studio', 0)
  return
end

package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)
-- All ReaScripts share one global Lua environment: this plain global is a
-- singleton lock, so launching the action twice doesn't spawn twin instances
-- (twins closing free each other's context and crash the surviving panel).
if BST_VS_LIVE and ImGui.ValidatePtr(BST_VS_LIVE, 'ImGui_Context*') then
  return -- panel already open
end
local ctx = ImGui.CreateContext('bst Variations Studio')
BST_VS_LIVE = ctx

local PLACES = { "Sequential after source", "Stacked on VAR track" }
local PLACE_KEYS = { "seq", "stack" }

local st = {
  count      = math.floor(lib.ext_getnum("vs_count", 4)),
  pitch_st   = lib.ext_getnum("var_pitch_st", 2.0),
  vol_db     = lib.ext_getnum("var_vol_db", 1.5),
  pan        = lib.ext_getnum("var_pan", 0.25),
  gap_ms     = lib.ext_getnum("var_gap_s", 0.01) * 1000,
  ppitch     = lib.ext_getnum("var_ppitch", 1),
  place_i    = math.floor(lib.ext_getnum("vs_place", 1)),
  fades      = lib.ext_getnum("vs_fades", 1),
  fade_max   = lib.ext_getnum("vs_fade_max", 40),
}

local msg, sev = "Select audio items and generate.", nil
local err = nil

local function set_num(key, v) st[key] = v; lib.ext_set(key, v) end

local PRESET_KEYS =
  { "vs_count","var_pitch_st","var_vol_db","var_pan","var_gap_s","var_ppitch",
    "vs_place","vs_fades","vs_fade_max" }

local function save_preset(slot)
  local vals = {}
  vals[#vals+1] = tostring(st.count)
  vals[#vals+1] = tostring(st.pitch_st)
  vals[#vals+1] = tostring(st.vol_db)
  vals[#vals+1] = tostring(st.pan)
  vals[#vals+1] = tostring(st.gap_ms / 1000)
  vals[#vals+1] = tostring(st.ppitch)
  vals[#vals+1] = tostring(st.place_i)
  vals[#vals+1] = tostring(st.fades)
  vals[#vals+1] = tostring(st.fade_max)
  for i, key in ipairs(PRESET_KEYS) do
    lib.ext_set(key .. "_p" .. slot, vals[i])
  end
  msg, sev = "Saved preset " .. slot, "ok"
end

local function load_preset(slot)
  local first = lib.ext_get("vs_count_p" .. slot, "")
  if first == "" then msg, sev = "Preset " .. slot .. " is empty.", "warn"; return end
  st.count    = math.floor(tonumber(lib.ext_get("vs_count_p" .. slot)) or st.count)
  st.pitch_st = tonumber(lib.ext_get("var_pitch_st_p" .. slot)) or st.pitch_st
  st.vol_db   = tonumber(lib.ext_get("var_vol_db_p" .. slot)) or st.vol_db
  st.pan      = tonumber(lib.ext_get("var_pan_p" .. slot)) or st.pan
  st.gap_ms   = (tonumber(lib.ext_get("var_gap_s_p" .. slot)) or 0.01) * 1000
  st.ppitch   = tonumber(lib.ext_get("var_ppitch_p" .. slot)) or 1
  st.place_i  = math.floor(tonumber(lib.ext_get("vs_place_p" .. slot)) or 1)
  st.fades    = tonumber(lib.ext_get("vs_fades_p" .. slot)) or 1
  st.fade_max = tonumber(lib.ext_get("vs_fade_max_p" .. slot)) or 40
  msg, sev = "Loaded preset " .. slot, nil
end

local function act_generate()
  if r.CountSelectedMediaItems(0) == 0 then
    msg, sev = "No items selected.", "warn"
    return
  end
  math.randomseed(os.time())
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local created, skipped = lib.generate_variations(lib.selected_items(), {
    count       = st.count,
    pitch_st    = st.pitch_st,
    vol_db      = st.vol_db,
    pan         = st.pan,
    gap_s       = st.gap_ms / 1000,
    ppitch      = st.ppitch >= 1,
    place       = PLACE_KEYS[st.place_i] or "seq",
    fade_max_ms = st.fades >= 1 and st.fade_max or 0,
  })
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Generate %d variation(s)", created), -1)
  msg, sev = string.format("Created %d variation(s) (%d skipped: MIDI/empty).",
    created, #skipped), created > 0 and "ok" or "warn"
end

--------------------------------------------------------------------------------
local function draw_body()
  fl.subtitle(ctx, "Variations Studio")
  ImGui.Spacing(ctx)

  fl.begin_card(ctx, "##card_gen")
    fl.caption(ctx, "RANDOMIZATION")
    local ch, v = ImGui.InputInt(ctx, "Count per item", st.count)
    if ch then set_num("vs_count", math.max(1, math.floor(v))) end
    ch, v = ImGui.SliderDouble(ctx, "Pitch +- (st)", st.pitch_st, 0, 12, '%.1f')
    if ch then set_num("var_pitch_st", v) end
    ch, v = ImGui.SliderDouble(ctx, "Volume +- (dB)", st.vol_db, 0, 6, '%.1f')
    if ch then set_num("var_vol_db", v) end
    ch, v = ImGui.SliderDouble(ctx, "Pan spread", st.pan, 0, 1, '%.2f')
    if ch then set_num("var_pan", v) end
    ch, v = ImGui.InputDouble(ctx, "Gap (ms)", st.gap_ms, 5, 50, '%.0f')
    if ch then set_num("var_gap_s", math.max(0, v) / 1000) end
    local nv = fl.toggle(ctx, "Preserve pitch (off = varispeed)", st.ppitch >= 1)
    if (nv and 1 or 0) ~= st.ppitch then set_num("var_ppitch", nv and 1 or 0) end
    nv = fl.toggle(ctx, "Randomize fades per variation", st.fades >= 1)
    if (nv and 1 or 0) ~= st.fades then set_num("vs_fades", nv and 1 or 0) end
    if st.fades >= 1 then
      ch, v = ImGui.InputDouble(ctx, "Max fade (ms)", st.fade_max, 10, 100, '%.0f')
      if ch then set_num("vs_fade_max", math.max(1, v)) end
    end
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 2)
  fl.begin_card(ctx, "##card_place")
    fl.caption(ctx, "PLACEMENT")
    -- ReaImGui Combo takes a NUL-terminated item string and a 0-BASED index
    ch, v = ImGui.Combo(ctx, "Mode##place", st.place_i - 1,
      table.concat(PLACES, "\0") .. "\0")
    if ch then set_num("vs_place", math.floor(v) + 1) end
    if PLACE_KEYS[st.place_i] == "seq" then
      fl.caption(ctx, "Copies placed sequentially - good before rendering")
    else
      fl.caption(ctx, "Layered at identical positions on a new VAR track")
    end
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 2)
  fl.begin_card(ctx, "##card_preset")
    fl.caption(ctx, "PRESETS")
    for slot = 1, 3 do
      if fl.button(ctx, "Save " .. slot, { width = 70 }) then save_preset(slot) end
      ImGui.SameLine(ctx)
      if fl.button(ctx, "Load " .. slot, { subtle = true, width = 70 }) then load_preset(slot) end
      ImGui.Dummy(ctx, 0, 2)
    end
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 6)
  if fl.button(ctx, "GENERATE VARIATIONS", { accent = true, width = 220, height = 32 }) then
    act_generate()
  end

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
    ImGui.SetNextWindowSize(ctx, 480, 620, ImGui.Cond_FirstUseEver)
    local nc, nv = fl.push_theme(ctx)
    local visible, op = ImGui.Begin(ctx, 'bst Variations Studio', true)
    if visible then
      local ok, e = pcall(draw_body)
      err = ok and nil or tostring(e)
      if not ok then
        r.ShowConsoleMsg("bst Variations Studio: " .. tostring(e) .. "\n")
        -- a widget threw mid-card: close any child it left dangling so the
        -- frame can still reach End() instead of aborting the panel
        for _ = 1, 8 do if not pcall(ImGui.EndChild, ctx) then break end end
      end
      ImGui.End(ctx)
    end
    fl.pop_theme(ctx, nc, nv)
    return op
  end)
  if not okf or not open then
    if not okf then -- one-line diagnosis instead of a silent close
      r.ShowConsoleMsg("bst Variations Studio: frame aborted, closing (" .. tostring(open) .. ")\n")
    end
    if BST_VS_LIVE == ctx then BST_VS_LIVE = nil end
    -- no explicit DestroyContext: ReaImGui frees contexts when the script
    -- stops deferring; explicit destruction yanks the pointer from under any
    -- sibling instance on builds that still export it
    return
  end
  r.defer(loop)
end

r.defer(loop)
