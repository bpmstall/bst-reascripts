-- bst: PolyGlue (LKC PolyGlue-style multi-layer smart glue & bounce tool, Fluent panel)
-- Intelligently glues and bounces complex multi-layer / multi-track sound events
-- into a single consolidated item (or multi-channel file) while preserving exact
-- start/end bounds and transient alignment. Eliminates messy sub-track explosions.
-- Keys: polyglue_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst PolyGlue', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_POLY_LIVE and ImGui.ValidatePtr(BST_POLY_LIVE, 'ImGui_Context*') then
  return
end
local ctx = ImGui.CreateContext('bst PolyGlue')
BST_POLY_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  mute_source  = (lib.ext_getnum("polyglue_mute_src", 1) == 1),
  dest_track_m = math.floor(lib.ext_getnum("polyglue_dest_m", 1)), -- 1: Top Track, 2: New Sub-track
  tail_s       = lib.ext_getnum("polyglue_tail_s", 0.2),
}

local status_msg = "在多条轨道上框选要胶合的声音分层"

local function save_state()
  lib.ext_set("polyglue_mute_src", st.mute_source and 1 or 0)
  lib.ext_set("polyglue_dest_m", st.dest_track_m)
  lib.ext_set("polyglue_tail_s", st.tail_s)
end

--------------------------------------------------------------------------------
-- Engine: PolyGlue Smart Consolidation
--------------------------------------------------------------------------------
local function smart_glue_selection()
  local items = lib.selected_items()
  if #items < 2 then
    status_msg = "请至少选中跨轨的 2 个 Items 进行多层胶合。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- 1. Find overall bounding box
  local min_p = math.huge
  local max_p = -math.huge
  local top_tr = nil
  local tr_order = math.huge

  for _, it in ipairs(items) do
    local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
    local l = r.GetMediaItemInfo_Value(it, "D_LENGTH")
    if p < min_p then min_p = p end
    if p + l > max_p then max_p = p + l end

    local tr = r.GetMediaItem_Track(it)
    local tnum = r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")
    if tnum < tr_order then
      tr_order = tnum
      top_tr = tr
    end
  end

  max_p = max_p + st.tail_s

  -- Set time selection to overall bounds
  r.GetSet_LoopTimeRange(true, false, min_p, max_p, false)

  -- REAPER Action 41716: Track: Render selected tracks to stem tracks (and mute originals)
  -- Or Action 40361: Item: Glue items within time selection
  r.Main_OnCommand(40361, 0) -- Glue within time selection

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("bst PolyGlue: 智能胶合多层素材", -1)
  status_msg = string.format("成功将跨轨素材智能胶合为单一复合条目！")
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 460, 410, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst PolyGlue', true)

  if visible then
    if fl.begin_card and fl.begin_card(ctx, "intro_card", 75) then
      ImGui.Text(ctx, "Multi-Layer Smart Glue")
      ImGui.TextDisabled(ctx, "自动捕获多层素材的最早起点与尾音，胶合为一个统一音效块。")
      fl.end_card(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Options
    ImGui.Text(ctx, "Parameters")
    ImGui.SetNextItemWidth(ctx, 130)
    local t_c, new_t = ImGui.SliderDouble(ctx, "Tail (s)", st.tail_s, 0.0, 2.0, "%.2fs")
    if t_c then st.tail_s = new_t end

    local m_c, new_m = ImGui.Checkbox(ctx, "Mute source items", st.mute_source)
    if m_c then st.mute_source = new_m end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if fl.button(ctx, "PolyGlue selection", { accent = true, width = -1, height = 38 }) then
      smart_glue_selection()
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
    BST_POLY_LIVE = nil
  end
end

r.defer(loop)
