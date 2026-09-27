-- bst: Align (Sound design alignment and distribution workbench, Fluent panel)
-- Aligns and distributes media items on the timeline with precision:
-- 1. Distribute Horizontally: Packs selected items with exact uniform gap (e.g. 0.2s).
-- 2. Align Transients: Analyzes RMS peaks across tracks and aligns them vertically.
-- 3. Snap Align: Aligns items to first item start / end or edit cursor.
-- Keys: align_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Align', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_ALIGN_LIVE and ImGui.ValidatePtr(BST_ALIGN_LIVE, 'ImGui_Context*') then
  return -- singleton panel already open
end
local ctx = ImGui.CreateContext('bst Align')
BST_ALIGN_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  gap_s       = lib.ext_getnum("align_gap_s", 0.2),
  order_mode  = math.floor(lib.ext_getnum("align_order", 1)), -- 1: Timeline position, 2: Track order
}

local status_msg = "请在时间线上选中要排列对齐的 Items"

local function save_state()
  lib.ext_set("align_gap_s", st.gap_s)
  lib.ext_set("align_order", st.order_mode)
end

--------------------------------------------------------------------------------
-- Engine: Alignment & Distribution
--------------------------------------------------------------------------------

-- Distribute selected items with uniform spacing
local function distribute_items_horizontally()
  local items = lib.selected_items()
  if #items < 2 then
    status_msg = "请至少选中 2 个 Items 进行等间距排布。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- Sort by position
  table.sort(items, function(a, b)
    return r.GetMediaItemInfo_Value(a, "D_POSITION") < r.GetMediaItemInfo_Value(b, "D_POSITION")
  end)

  local cur_pos = r.GetMediaItemInfo_Value(items[1], "D_POSITION") + r.GetMediaItemInfo_Value(items[1], "D_LENGTH") + st.gap_s

  for i = 2, #items do
    local it = items[i]
    r.SetMediaItemInfo_Value(it, "D_POSITION", cur_pos)
    cur_pos = cur_pos + r.GetMediaItemInfo_Value(it, "D_LENGTH") + st.gap_s
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: 等间距排布 %d 个 Items", #items), -1)
  status_msg = string.format("已按 %.2fs 间距整齐排布 %d 个 Items！", st.gap_s, #items)
end

-- Align all selected items by their RMS transient / snap offsets to the first item
local function align_by_transient_peaks()
  local items = lib.selected_items()
  if #items < 2 then
    status_msg = "请至少选中 2 个跨轨或同轨 Items 进行瞬态对齐。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- 1. Ensure first item has valid snap offset
  local ref_it = items[1]
  local ref_snap = r.GetMediaItemInfo_Value(ref_it, "D_SNAPOFFSET")
  if ref_snap <= 0.001 then
    local pk = lib.item_rms_peak_time(ref_it, "rms")
    if pk then
      ref_snap = pk - r.GetMediaItemInfo_Value(ref_it, "D_POSITION")
      r.SetMediaItemInfo_Value(ref_it, "D_SNAPOFFSET", ref_snap)
    end
  end

  local ref_target_time = r.GetMediaItemInfo_Value(ref_it, "D_POSITION") + ref_snap

  local count = 0
  for i = 2, #items do
    local it = items[i]
    local pk = lib.item_rms_peak_time(it, "rms")
    if pk then
      local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
      local snap = pk - pos
      r.SetMediaItemInfo_Value(it, "D_SNAPOFFSET", snap)
      -- Shift so that (pos + snap) == ref_target_time
      local new_pos = math.max(0, ref_target_time - snap)
      r.SetMediaItemInfo_Value(it, "D_POSITION", new_pos)
      count = count + 1
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: 瞬态对齐 %d 个 Items", count), -1)
  status_msg = string.format("已将 %d 个 Items 瞬态精确吸附对齐到基准线！", count)
end

-- Align all selected items to cursor or first item start
local function align_to_start()
  local items = lib.selected_items()
  if #items == 0 then return end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local target_pos = r.GetCursorPosition()
  if target_pos <= 0 then
    target_pos = r.GetMediaItemInfo_Value(items[1], "D_POSITION")
  end

  for _, it in ipairs(items) do
    r.SetMediaItemInfo_Value(it, "D_POSITION", target_pos)
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("bst: 起点左对齐", -1)
  status_msg = string.format("已将 %d 个 Items 左端对齐！", #items)
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 460, 430, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Align (音效对齐与等间距排版)', true)

  if visible then
    if fl.begin_card and fl.begin_card(ctx, "panel_card", 75) then
      ImGui.Text(ctx, "音效设计排版与瞬态对齐工作台")
      ImGui.TextDisabled(ctx, "等间距水平分布、多轨瞬态垂直精准吸附、左端/光标对齐。")
        fl.end_card(ctx)
      end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Distribution
    ImGui.Text(ctx, "水平等间距分布 (Distribute Horizontally):")
    ImGui.SetNextItemWidth(ctx, 130)
    local g_c, new_g = ImGui.SliderDouble(ctx, "间隔时长 (Gap s)", st.gap_s, 0.0, 2.0, "%.2fs")
    if g_c then st.gap_s = new_g end

    ImGui.SameLine(ctx)
    if fl.button(ctx, "↔️ 水平等间距排布", { accent = true, width = -1, height = 30 }) then
        distribute_items_horizontally()
        save_state()
      end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Transient alignment
    ImGui.Text(ctx, "瞬态与起音垂直对齐 (Vertical Transient Alignment):")
    if fl.button(ctx, "🎯 以第 1 个条目为准，其余条目瞬态垂直对齐", { width = -1, height = 34 }) then
      align_by_transient_peaks()
    end

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "基准线对齐 (Baseline Alignment):")
    if fl.button(ctx, "⬅️ 全部左对齐 (对齐到光标或首条目起点)", { width = -1, height = 30 }) then
      align_to_start()
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
    BST_ALIGN_LIVE = nil
  end
end

r.defer(loop)
