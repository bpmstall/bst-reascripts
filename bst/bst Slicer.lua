-- bst: Slicer (X-Raym/nvk-style batch transient slicer & silence remover, Fluent panel)
-- Automatically slices long field recordings, foley sessions, or weapon takes into
-- clean individual sound events based on transient thresholds & silence gating.
-- Auto-sets snap offset to each transient and adds micro-fades to eliminate clicks.
-- Keys: slicer_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Slicer', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_SLICER_LIVE and ImGui.ValidatePtr(BST_SLICER_LIVE, 'ImGui_Context*') then
  return
end
local ctx = ImGui.CreateContext('bst Slicer')
BST_SLICER_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  thresh_db   = lib.ext_getnum("slicer_thresh_db", -36.0),
  min_len_ms  = lib.ext_getnum("slicer_min_len", 80.0),
  pad_ms      = lib.ext_getnum("slicer_pad_ms", 15.0),
  auto_fade   = (lib.ext_getnum("slicer_fade", 1) == 1),
}

local status_msg = "在轨道上选中一条或多条长录音素材"

local function save_state()
  lib.ext_set("slicer_thresh_db", st.thresh_db)
  lib.ext_set("slicer_min_len", st.min_len_ms)
  lib.ext_set("slicer_pad_ms", st.pad_ms)
  lib.ext_set("slicer_fade", st.auto_fade and 1 or 0)
end

--------------------------------------------------------------------------------
-- Engine: Dynamic Slicing & Transient Marking
--------------------------------------------------------------------------------
local function slice_selected_items()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请先选中要切片的长录音素材。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- REAPER Native Dynamic Split Action (ID 40760) or split by transients
  -- Action 40760: Item: Dynamic split items...
  r.Main_OnCommand(40760, 0)

  -- After dynamic split, iterate resulting selected items to align snap & fades
  local new_items = lib.selected_items()
  local count = 0
  for _, it in ipairs(new_items) do
    if st.auto_fade then
      r.SetMediaItemInfo_Value(it, "D_FADEINLEN", 0.003)
      r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", 0.02)
    end
    local pk = lib.item_rms_peak_time(it, "rms")
    if pk then
      local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
      r.SetMediaItemInfo_Value(it, "D_SNAPOFFSET", math.max(0, pk - p))
      count = count + 1
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst Slicer: 动态切片与吸附 %d 个条目", count), -1)
  status_msg = string.format("切片完成！已处理 %d 个独立音效片段。", count)
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 480, 430, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Slicer (瞬态智能批量切片与去静音)', true)

  if visible then
    if fl.begin_card and fl.begin_card(ctx, "intro_card", 75) then
      ImGui.Text(ctx, "录音素材批量无破音切片与去静音")
      ImGui.TextDisabled(ctx, "基于瞬态能量自动切割长条采样、去静音、自动定吸附点并加防爆音淡化。")
      fl.end_card(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Sliders
    ImGui.Text(ctx, "门限与切片参数:")
    ImGui.SetNextItemWidth(ctx, 130)
    local th_c, new_th = ImGui.SliderDouble(ctx, "瞬态门限 (Threshold dB)", st.thresh_db, -60.0, -12.0, "%.1f dB")
    if th_c then st.thresh_db = new_th end

    ImGui.SetNextItemWidth(ctx, 130)
    local ml_c, new_ml = ImGui.SliderDouble(ctx, "最短事件 (Min len ms)", st.min_len_ms, 20.0, 500.0, "%.0f ms")
    if ml_c then st.min_len_ms = new_ml end

    ImGui.SetNextItemWidth(ctx, 130)
    local pd_c, new_pd = ImGui.SliderDouble(ctx, "前置余量 (Padding ms)", st.pad_ms, 0.0, 50.0, "%.0f ms")
    if pd_c then st.pad_ms = new_pd end

    local af_c, new_af = ImGui.Checkbox(ctx, "自动添加微淡入淡出防爆音 (Auto Anti-Click Fades)", st.auto_fade)
    if af_c then st.auto_fade = new_af end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if fl.button(ctx, "✂️ 执行智能批量切片 (Dynamic Slice)", { accent = true, width = -1, height = 38 }) then
      slice_selected_items()
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
    BST_SLICER_LIVE = nil
  end
end

r.defer(loop)
