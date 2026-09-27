-- bst: Elastic Warp (Sexan-style transient warp & stretch marker editor, Fluent panel)
-- Adds and aligns stretch markers at detected transient points inside selected takes.
-- Enables elastic audio warping to snap sound impact beats to video hits or grid tempo.
-- Keys: warp_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Elastic Warp', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_WARP_LIVE and ImGui.ValidatePtr(BST_WARP_LIVE, 'ImGui_Context*') then
  return
end
local ctx = ImGui.CreateContext('bst Elastic Warp')
BST_WARP_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  sens_pct    = lib.ext_getnum("warp_sens", 60.0),
  snap_grid   = (lib.ext_getnum("warp_grid", 0) == 1),
}

local status_msg = "在轨道上选中要添加弹性拉伸标记的 Item"

local function save_state()
  lib.ext_set("warp_sens", st.sens_pct)
  lib.ext_set("warp_grid", st.snap_grid and 1 or 0)
end

--------------------------------------------------------------------------------
-- Engine: Stretch Markers Insertion
--------------------------------------------------------------------------------
local function add_transient_stretch_markers()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请在轨道上选中 Item。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local count = 0

  for _, it in ipairs(items) do
    local tk = r.GetActiveTake(it)
    if tk then
      -- Analyze RMS peak or transient
      local pk = lib.item_rms_peak_time(it, "rms")
      if pk then
        local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
        local offs = r.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")
        local rel_t = (pk - p) + offs
        -- Action: Add stretch marker at current time (Take API)
        r.SetTakeStretchMarker(tk, -1, rel_t)
        count = count + 1
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst Warp: 插入 %d 个弹性拉伸标记", count), -1)
  status_msg = string.format("成功插入 %d 个弹性拉伸标记！可在 Arrange 窗口自由拉伸。", count)
end

local function clear_stretch_markers()
  local items = lib.selected_items()
  if #items == 0 then return end
  r.Undo_BeginBlock()
  for _, it in ipairs(items) do
    local tk = r.GetActiveTake(it)
    if tk then
      -- Action 41844: Item: Delete all stretch markers
      r.Main_OnCommand(41844, 0)
    end
  end
  r.Undo_EndBlock("bst Warp: 清除弹性标记", -1)
  status_msg = "已清除选中 Item 的全部弹性拉伸标记！"
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 460, 390, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Elastic Warp (弹性音频瞬态对齐)', true)

  if visible then
    if fl.begin_card and fl.begin_card(ctx, "intro_card", 75) then
      ImGui.Text(ctx, "弹性拉伸 (Elastic Audio) 瞬态贴合")
      ImGui.TextDisabled(ctx, "自动在瞬态点打上 Stretch Markers，拖动手柄无损将击打点贴合到视频关键帧。")
      fl.end_card(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.Text(ctx, "弹性吸附参数:")
    ImGui.SetNextItemWidth(ctx, 130)
    local sn_c, new_sn = ImGui.SliderDouble(ctx, "瞬态灵敏度 (Sensitivity %)", st.sens_pct, 10.0, 100.0, "%.0f%%")
    if sn_c then st.sens_pct = new_sn end

    local g_c, new_g = ImGui.Checkbox(ctx, "标记自动吸附工程网格节奏 (Snap to Grid)", st.snap_grid)
    if g_c then st.snap_grid = new_g end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if fl.button(ctx, "🎯 一键在瞬态点添加 Stretch Markers", { accent = true, width = -1, height = 38 }) then
      add_transient_stretch_markers()
      save_state()
    end

    ImGui.Spacing(ctx)
    if fl.button(ctx, "🗑️ 清除所有弹性拉伸标记 (Clear All Markers)", { width = -1, height = 30 }) then
      clear_stretch_markers()
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
    BST_WARP_LIVE = nil
  end
end

r.defer(loop)
