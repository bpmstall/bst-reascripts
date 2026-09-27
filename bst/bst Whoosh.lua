-- bst: Whoosh (Action & Combat sound design tool, Fluent panel)
-- Transforms selected items/layers into dynamic whooshes, swooshes, and weapon swings.
-- Automatically shapes take envelopes (pitch bend curve, apex-focused volume energy,
-- and directional pan sweep) to turn raw textures into punchy combat sound assets.
-- Keys: whoosh_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Whoosh', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_WHOOSH_LIVE and ImGui.ValidatePtr(BST_WHOOSH_LIVE, 'ImGui_Context*') then
  return -- singleton panel already open
end
local ctx = ImGui.CreateContext('bst Whoosh')
BST_WHOOSH_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  dur_s       = lib.ext_getnum("whoosh_dur_s", 0.45),
  apex_pct    = lib.ext_getnum("whoosh_apex", 45.0),
  pitch_st    = lib.ext_getnum("whoosh_pitch_st", 12.0),
  pan_dir     = math.floor(lib.ext_getnum("whoosh_pan_dir", 1)), -- 1: L->R, 2: R->L, 3: Center
  var_count   = math.max(1, math.min(10, math.floor(lib.ext_getnum("whoosh_vars", 3)))),
  gap_s       = lib.ext_getnum("whoosh_gap_s", 0.3),
  tail_fade   = (lib.ext_getnum("whoosh_tail_fade", 1) == 1),
}

local status_msg = "选中至少一个素材（风声/质感/打击）点击生成挥动音效"

local function save_state()
  lib.ext_set("whoosh_dur_s", st.dur_s)
  lib.ext_set("whoosh_apex", st.apex_pct)
  lib.ext_set("whoosh_pitch_st", st.pitch_st)
  lib.ext_set("whoosh_pan_dir", st.pan_dir)
  lib.ext_set("whoosh_vars", st.var_count)
  lib.ext_set("whoosh_gap_s", st.gap_s)
  lib.ext_set("whoosh_tail_fade", st.tail_fade and 1 or 0)
end

--------------------------------------------------------------------------------
-- Engine: Whoosh Synthesis from Selected Items
--------------------------------------------------------------------------------
local function shape_item_to_whoosh(item, dur, apex_pct, pitch_bend, pan_mode)
  local take = r.GetActiveTake(item)
  if not take then return end

  -- Clamp length to duration
  r.SetMediaItemInfo_Value(item, "D_LENGTH", dur)

  local apex_t = dur * (apex_pct / 100)

  -- 1. Fades: Exponential rise to apex, smooth decay to tail
  r.SetMediaItemInfo_Value(item, "D_FADEINLEN", apex_t)
  r.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", 3) -- Fast start / slow curve
  r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", dur - apex_t)
  r.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", 2) -- Natural logarithmic decay

  -- 2. Snap Offset placed right at Apex
  r.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", apex_t)

  -- 3. Take Pitch Envelope or Pitch Shift
  -- If take pitch bend > 0, set take pitch and preserve algorithm
  r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
  r.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch_bend * 0.4)

  -- Set take pan
  if pan_mode == 1 then
    r.SetMediaItemTakeInfo_Value(take, "D_PAN", -0.7) -- Start leftish
  elseif pan_mode == 2 then
    r.SetMediaItemTakeInfo_Value(take, "D_PAN", 0.7)  -- Start rightish
  else
    r.SetMediaItemTakeInfo_Value(take, "D_PAN", 0.0)
  end

  -- Write Pitch & Volume Take Envelopes if possible
  local pitch_env = r.GetTakeEnvelopeByName(take, "Pitch")
  if not pitch_env then
    -- Show take pitch envelope
    r.Main_OnCommand(41612, 0) -- Take: Toggle take pitch envelope
    pitch_env = r.GetTakeEnvelopeByName(take, "Pitch")
  end

  if pitch_env then
    -- Clear and add 3-point whoosh arc: Base -> Peak at Apex -> Low Tail
    r.DeleteEnvelopePointRange(pitch_env, 0, dur)
    r.InsertEnvelopePoint(pitch_env, 0, -pitch_bend * 0.5, 0, 0, true, true)
    r.InsertEnvelopePoint(pitch_env, apex_t, pitch_bend, 0, 0, true, true)
    r.InsertEnvelopePoint(pitch_env, dur, -pitch_bend * 0.3, 0, 0, true, true)
    r.Envelope_SortPoints(pitch_env)
  end

  -- Pan Envelope
  if pan_mode ~= 3 then
    local pan_env = r.GetTakeEnvelopeByName(take, "Pan")
    if not pan_env then
      r.Main_OnCommand(41611, 0) -- Take: Toggle take pan envelope
      pan_env = r.GetTakeEnvelopeByName(take, "Pan")
    end
    if pan_env then
      r.DeleteEnvelopePointRange(pan_env, 0, dur)
      local start_pan = (pan_mode == 1) and -0.85 or 0.85
      local end_pan = -start_pan
      r.InsertEnvelopePoint(pan_env, 0, start_pan, 0, 0, true, true)
      r.InsertEnvelopePoint(pan_env, apex_t, 0.0, 0, 0, true, true)
      r.InsertEnvelopePoint(pan_env, dur, end_pan, 0, 0, true, true)
      r.Envelope_SortPoints(pan_env)
    end
  end
end

local function generate_whooshes()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请在轨道上选中素材。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  math.randomseed(os.time())

  local created_count = 0
  for _, src_it in ipairs(items) do
    local track = r.GetMediaItem_Track(src_it)
    local base_pos = r.GetMediaItemInfo_Value(src_it, "D_POSITION")

    for v = 1, st.var_count do
      local var_pos = base_pos + v * (st.dur_s + st.gap_s)
      local new_it, new_tk = lib.clone_item(src_it, track, var_pos)
      if new_it then
        -- Add subtle random variation to duration & pitch
        local var_dur = math.max(0.15, st.dur_s + lib.rand_sym(0.04))
        local var_pitch = math.max(2, st.pitch_st + lib.rand_sym(2.0))
        local var_apex = lib.clamp(st.apex_pct + lib.rand_sym(5.0), 20, 80)

        shape_item_to_whoosh(new_it, var_dur, var_apex, var_pitch, st.pan_dir)
        local base_n = lib.take_name(new_tk)
        lib.set_take_name(new_tk, string.format("Whoosh_%s_%02d", base_n, v))
        created_count = created_count + 1
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst Whoosh: 生成 %d 个挥动变奏", created_count), -1)
  status_msg = string.format("成功生成 %d 个 Whoosh 挥动变奏！", created_count)
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local PAN_NAMES = { "左 → 右 (Left to Right)", "右 → 左 (Right to Left)", "居中无偏转 (Center)" }

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 480, 490, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Whoosh', true)

  if visible then
    if fl.begin_card and fl.begin_card(ctx, "panel_card", 75) then
      ImGui.Text(ctx, "Action & Weapon Whoosh Generator")
      ImGui.TextDisabled(ctx, "针对选中素材自动生成音高俯冲抬升包络、能量汇聚曲线与声像横扫。")
        fl.end_card(ctx)
      end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Parameters
    ImGui.Text(ctx, "Dynamics & Envelope")
    ImGui.SetNextItemWidth(ctx, 130)
    local d_c, new_d = ImGui.SliderDouble(ctx, "Duration (s)", st.dur_s, 0.15, 2.5, "%.2fs")
    if d_c then st.dur_s = new_d end

    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 130)
    local a_c, new_a = ImGui.SliderDouble(ctx, "Apex (%)", st.apex_pct, 15.0, 85.0, "%.0f%%")
    if a_c then st.apex_pct = new_a end

    ImGui.SetNextItemWidth(ctx, 130)
    local p_c, new_p = ImGui.SliderDouble(ctx, "Pitch bend (st)", st.pitch_st, 0.0, 36.0, "%.1f st")
    if p_c then st.pitch_st = new_p end

    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 130)
    local v_c, new_v = ImGui.SliderInt(ctx, "Variations", st.var_count, 1, 8)
    if v_c then st.var_count = new_v end

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "Pan sweep:")
    ImGui.SetNextItemWidth(ctx, 220)
    if ImGui.BeginCombo(ctx, "##pan_combo", PAN_NAMES[st.pan_dir]) then
      for idx, name in ipairs(PAN_NAMES) do
        local sel = (idx == st.pan_dir)
        if ImGui.Selectable(ctx, name, sel) then
          st.pan_dir = idx
        end
      end
      ImGui.EndCombo(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if fl.button(ctx, string.format("🗡️ 生成 %d 组挥动变奏 (Generate Whooshes)", st.var_count), { accent = true, height = 38 }) then
        generate_whooshes()
        save_state()
      end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    ImGui.TextDisabled(ctx, "状态: " .. status_msg)

    ImGui.End(ctx)
  end

  fl.pop_theme(ctx, nc, nv)

  if p_open then
    r.defer(loop)
  else
    save_state()
    BST_WHOOSH_LIVE = nil
  end
end

r.defer(loop)
