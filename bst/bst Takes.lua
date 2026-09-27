-- bst: Takes (nvk_TAKES-style multi-take workflow, Fluent panel)
-- Streamlines game audio asset variation management inside takes:
-- 1. Implode / Explode: Merge selected items into takes or explode takes to tracks.
-- 2. Align Transients: Automatically aligns all take start offsets to their RMS attack peak.
-- 3. Take Shaping: Pitch / Volume randomization across takes for natural variations.
-- Keys: takes_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Takes', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_TAKES_LIVE and ImGui.ValidatePtr(BST_TAKES_LIVE, 'ImGui_Context*') then
  return -- singleton panel already open
end
local ctx = ImGui.CreateContext('bst Takes')
BST_TAKES_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  pitch_st    = lib.ext_getnum("takes_pitch_st", 2.0),
  vol_db      = lib.ext_getnum("takes_vol_db", 1.5),
  pan         = lib.ext_getnum("takes_pan", 0.0),
}

local status_msg = "就绪"

local function save_state()
  lib.ext_set("takes_pitch_st", st.pitch_st)
  lib.ext_set("takes_vol_db", st.vol_db)
  lib.ext_set("takes_pan", st.pan)
end

--------------------------------------------------------------------------------
-- Engine: Take Alignment & Management
--------------------------------------------------------------------------------

-- Align all takes within selected items to their RMS transient peak
local function align_all_takes_transients()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请先选中至少一个包含多 Take 的 Item。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local total_takes_aligned = 0

  for _, it in ipairs(items) do
    local num_takes = r.CountTakes(it)
    if num_takes > 1 then
      local ref_snap = nil

      -- 1. Scan RMS peak time for each take
      local take_peaks = {}
      for k = 0, num_takes - 1 do
        local tk = r.GetTake(it, k)
        -- Temporarily set as active take to analyze
        r.SetActiveTake(tk)
        local pt = lib.item_rms_peak_time(it, "rms")
        take_peaks[k] = pt
        if k == 0 and pt then ref_snap = pt end
      end

      -- 2. Adjust D_STARTOFFS so all takes' peaks match ref_snap
      if ref_snap then
        for k = 1, num_takes - 1 do
          local tk = r.GetTake(it, k)
          local pt = take_peaks[k]
          if pt then
            local cur_offs = r.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")
            local diff = pt - ref_snap
            local new_offs = math.max(0, cur_offs + diff)
            r.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", new_offs)
            total_takes_aligned = total_takes_aligned + 1
          end
        end
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst Takes: 对齐 %d 个 Take 瞬态", total_takes_aligned), -1)
  status_msg = string.format("成功将 %d 个 Take 瞬态吸附对齐！", total_takes_aligned)
end

-- Randomize Pitch/Vol across all takes in selected items
local function randomize_takes()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请选中包含 Takes 的 Item。"
    return
  end

  math.randomseed(os.time())
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local count = 0

  for _, it in ipairs(items) do
    local num_takes = r.CountTakes(it)
    for k = 0, num_takes - 1 do
      local tk = r.GetTake(it, k)
      if st.pitch_st > 0 then
        local p = lib.rand_sym(st.pitch_st)
        r.SetMediaItemTakeInfo_Value(tk, "D_PITCH", p)
        r.SetMediaItemTakeInfo_Value(tk, "B_PPITCH", 1)
      end
      if st.vol_db > 0 then
        local v = lib.rand_sym(st.vol_db)
        r.SetMediaItemTakeInfo_Value(tk, "D_VOL", lib.db2lin(v))
      end
      if st.pan > 0 then
        local pn = lib.rand_sym(st.pan)
        r.SetMediaItemTakeInfo_Value(tk, "D_PAN", lib.clamp(pn, -1, 1))
      end
      count = count + 1
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("bst Takes: 随机化 Take 变奏", -1)
  status_msg = string.format("已随机化 %d 个 Take 的音高/音量/声像！", count)
end

-- Implode selected items across tracks into takes (REAPER Action 40543)
local function implode_to_takes()
  local items = lib.selected_items()
  if #items < 2 then
    status_msg = "请至少选中 2 个要合并为 Takes 的 Item。"
    return
  end
  r.Undo_BeginBlock()
  r.Main_OnCommand(40543, 0) -- Take: Implode items on same or different tracks into takes
  r.Undo_EndBlock("bst Takes: 合并为多 Take", -1)
  status_msg = "已合并为多 Take 条目！"
end

-- Explode takes to tracks (REAPER Action 40224)
local function explode_takes_to_tracks()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请选中包含 Takes 的 Item。"
    return
  end
  r.Undo_BeginBlock()
  r.Main_OnCommand(40224, 0) -- Take: Explode takes on selected tracks into separate tracks
  r.Undo_EndBlock("bst Takes: 拆解 Takes 到独立轨道", -1)
  status_msg = "已拆解 Takes 到独立轨道！"
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 480, 410, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Takes (nvk_TAKES 式多变奏管理)', true)

  if visible then
    if fl.card then fl.card(ctx, function()
      ImGui.Text(ctx, "多 Take 变奏工作流")
      ImGui.TextDisabled(ctx, "游戏脚步/枪击/受击音效变奏管理，一键瞬态重合与快速试听。")
    end) end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Transient alignment
    ImGui.Text(ctx, "瞬态吸附 (Transient Alignment):")
    if fl.button_accent then
      if fl.button_accent(ctx, "🎯 一键对齐所有 Take 起音瞬态 (RMS Peak)", -1, 34) then
        align_all_takes_transients()
      end
    else
      if ImGui.Button(ctx, "一键对齐所有 Take 起音瞬态", -1, 34) then
        align_all_takes_transients()
      end
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Randomization
    ImGui.Text(ctx, "多 Take 变奏微调 (Take Shaping):")
    ImGui.SetNextItemWidth(ctx, 120)
    local pst_c, new_pst = ImGui.DragDouble(ctx, "音高随机 (±st)", st.pitch_st, 0.1, 0, 12, "%.1f")
    if pst_c then st.pitch_st = new_pst end

    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 120)
    local vdb_c, new_vdb = ImGui.DragDouble(ctx, "音量随机 (±dB)", st.vol_db, 0.1, 0, 6, "%.1f")
    if vdb_c then st.vol_db = new_vdb end

    if ImGui.Button(ctx, "🎲 为选中 Item 的所有 Take 施加随机变奏", -1, 30) then
      randomize_takes()
      save_state()
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Implode / Explode
    ImGui.Text(ctx, "结构转换 (Implode / Explode):")
    if ImGui.Button(ctx, "📥 将选中的多个 Items 合并为一个 Item 的多 Takes", -1, 28) then
      implode_to_takes()
    end

    ImGui.Spacing(ctx)
    if ImGui.Button(ctx, "📤 将选中的 Takes 展开拆分到独立平行轨道", -1, 28) then
      explode_takes_to_tracks()
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
    BST_TAKES_LIVE = nil
  end
end

r.defer(loop)
