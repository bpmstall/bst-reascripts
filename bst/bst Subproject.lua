-- bst: Subproject (nvk_SUBPROJECT-style workflow helper, Fluent panel)
-- Streamlines the professional game audio subproject workflow in REAPER:
-- 1. Pack: Converts selected items/tracks into a self-contained subproject (.rpp).
-- 2. Marker Sync: Auto-calculates accurate =START and =END render markers based
--    on unmuted items (+ customizable tail padding) inside subprojects.
-- 3. Batch Update: Renders proxy (.rpp-prox) and re-syncs markers seamlessly.
-- Keys: subproj_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Subproject', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_SUBPROJ_LIVE and ImGui.ValidatePtr(BST_SUBPROJ_LIVE, 'ImGui_Context*') then
  return -- singleton panel already open
end
local ctx = ImGui.CreateContext('bst Subproject')
BST_SUBPROJ_LIVE = ctx

--------------------------------------------------------------------------------
-- State & Preferences
--------------------------------------------------------------------------------
local st = {
  sub_name   = lib.ext_get("subproj_name", "SFX_NewSubproject"),
  tail_s     = lib.ext_getnum("subproj_tail_s", 0.5),
  head_s     = lib.ext_getnum("subproj_head_s", 0.0),
  save_prox  = (lib.ext_getnum("subproj_save_prox", 1) == 1),
}

local status_msg = "就绪"

local function save_state()
  lib.ext_set("subproj_name", st.sub_name)
  lib.ext_set("subproj_tail_s", st.tail_s)
  lib.ext_set("subproj_head_s", st.head_s)
  lib.ext_set("subproj_save_prox", st.save_prox and 1 or 0)
end

--------------------------------------------------------------------------------
-- Subproject Helpers
--------------------------------------------------------------------------------

-- Checks if current active project is a subproject
local function is_current_subproject()
  local _, proj_fn = r.EnumProjects(-1, "")
  if not proj_fn or proj_fn == "" then return false end
  if proj_fn:lower():match("%.rpp$") then
    -- Check if project has a parent
    if r.GetSubProject_Parent and r.GetSubProject_Parent(0) then
      return true
    end
  end
  return false
end

-- Scan unmuted items in current project to find precise bounds
local function get_unmuted_bounds()
  local min_t = math.huge
  local max_t = -math.huge
  local count = 0

  local num_tracks = r.CountTracks(0)
  for t = 0, num_tracks - 1 do
    local tr = r.GetTrack(0, t)
    local tr_muted = (r.GetMediaTrackInfo_Value(tr, "B_MUTE") == 1)
    if not tr_muted then
      local num_items = r.CountTrackMediaItems(tr)
      for i = 0, num_items - 1 do
        local it = r.GetTrackMediaItem(tr, i)
        local it_muted = (r.GetMediaItemInfo_Value(it, "B_MUTE") == 1)
        if not it_muted then
          local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
          local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
          if pos < min_t then min_t = pos end
          if pos + len > max_t then max_t = pos + len end
          count = count + 1
        end
      end
    end
  end

  if count == 0 then return nil, nil, 0 end
  return min_t, max_t, count
end

-- Fix/Set =START and =END render markers
local function fix_subproject_markers(head_pad, tail_pad)
  head_pad = head_pad or st.head_s
  tail_pad = tail_pad or st.tail_s

  local min_t, max_t, count = get_unmuted_bounds()
  if count == 0 then
    status_msg = "工程内无未静音的音频 Item，未修改标记。"
    return false
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- Remove existing =START and =END markers
  local idx = 0
  while true do
    local ret, isrgn, pos, rgnend, name, markidx = r.EnumProjectMarkers(idx)
    if ret == 0 then break end
    if not isrgn and (name == "=START" or name == "=END") then
      r.DeleteProjectMarker(0, markidx, false)
    else
      idx = idx + 1
    end
  end

  -- Calculate positions
  local start_t = math.max(0, min_t - head_pad)
  local end_t = max_t + tail_pad

  -- Add =START and =END markers
  r.AddProjectMarker(0, false, start_t, 0, "=START", -1)
  r.AddProjectMarker(0, false, end_t, 0, "=END", -1)

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("bst Subproject: 设置 =START/=END 标记", -1)

  if st.save_prox then
    -- Save project and render proxy (Action 41998)
    r.Main_OnCommand(41998, 0)
  end

  status_msg = string.format("已同步标记: START @ %.2fs, END @ %.2fs (覆盖 %d 个 Item)", start_t, end_t, count)
  return true
end

-- Intelligent auto-naming from selection
local function guess_subproject_name()
  local items = lib.selected_items()
  if #items > 0 then
    local take = r.GetActiveTake(items[1])
    local name = lib.take_name(take)
    if name and name ~= "" then
      -- Strip file extension if any
      name = name:gsub("%..+$", "")
      return "SUB_" .. name
    end
  end

  local num_tr = r.CountSelectedTracks(0)
  if num_tr > 0 then
    local tr = r.GetSelectedTrack(0, 0)
    local _, tr_name = r.GetTrackName(tr)
    if tr_name and tr_name ~= "" then
      return "SUB_" .. tr_name
    end
  end

  return "SUB_SFX_Design"
end

-- Pack selected tracks to subproject
local function pack_selected_tracks_to_subproject()
  local num_tr = r.CountSelectedTracks(0)
  if num_tr == 0 then
    status_msg = "请先选中要打包的轨道（或分层 Folder 轨）。"
    return
  end

  r.Undo_BeginBlock()

  -- REAPER Native: Track: Move tracks to subproject (ID 41997)
  -- This creates a subproject file and replaces selected tracks with a proxy item
  r.Main_OnCommand(41997, 0)

  -- The active project tab is now the newly created subproject
  -- Auto-set =START and =END in the subproject tab
  fix_subproject_markers(st.head_s, st.tail_s)

  -- Switch back to parent tab if available
  r.Main_OnCommand(40861, 0) -- Next project tab or previous

  r.Undo_EndBlock("bst Subproject: 打包选中国道为子工程", -1)
  status_msg = "已成功打包为子工程并自动写入渲染边界标记！"
end

-- Pack selected items into subproject
local function pack_selected_items_to_subproject()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请先选中要打包的分层音频 Items。"
    return
  end

  r.Undo_BeginBlock()
  -- Select tracks of selected items
  r.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
  local touched_tracks = {}
  for _, it in ipairs(items) do
    local tr = r.GetMediaItem_Track(it)
    if tr and not touched_tracks[tr] then
      touched_tracks[tr] = true
      r.SetTrackSelected(tr, true)
    end
  end

  -- Move tracks to subproject
  pack_selected_tracks_to_subproject()
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 480, 420, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Subproject (nvk_SUBPROJECT 式工作流)', true)

  if visible then
    local in_sub = is_current_subproject()

    -- Status card
    if fl.card then fl.card(ctx, function()
      if in_sub then
        ImGui.TextColored(ctx, 0x6CCB5FFF, "当前正处于子工程 (Subproject) 标签页内")
        ImGui.TextDisabled(ctx, "可直接点下方按钮一键对齐渲染标记并更新代理音频。")
      else
        ImGui.Text(ctx, "当前处于主工程 (Main Project)")
        ImGui.TextDisabled(ctx, "选中要分层的 Items 或轨道，一键收纳进子工程。")
      end
    end) end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Subproject Bounds & Padding settings
    ImGui.Text(ctx, "渲染边界标记 (=START / =END) 参数:")
    ImGui.SetNextItemWidth(ctx, 130)
    local hp_c, new_hp = ImGui.SliderDouble(ctx, "前置余量 (Head s)", st.head_s, 0.0, 2.0, "%.2fs")
    if hp_c then st.head_s = new_hp end

    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 130)
    local tp_c, new_tp = ImGui.SliderDouble(ctx, "尾音余量 (Tail s)", st.tail_s, 0.0, 5.0, "%.2fs")
    if tp_c then st.tail_s = new_tp end

    local sp_c, new_sp = ImGui.Checkbox(ctx, "对齐标记后自动保存并渲染代理 (.rpp-prox)", st.save_prox)
    if sp_c then st.save_prox = new_sp end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Action 1: Marker alignment (Core nvk_SUBPROJECT feature)
    if fl.button_accent then
      if fl.button_accent(ctx, "🎯 一键校准 =START / =END 标记 (根据未静音 Item)", -1, 36) then
        fix_subproject_markers(st.head_s, st.tail_s)
        save_state()
      end
    else
      if ImGui.Button(ctx, "一键校准 =START / =END 标记", -1, 36) then
        fix_subproject_markers(st.head_s, st.tail_s)
        save_state()
      end
    end

    ImGui.Spacing(ctx)

    -- Action 2 & 3: Packaging
    if not in_sub then
      ImGui.Text(ctx, "打包进子工程 (Pack to Subproject):")
      if ImGui.Button(ctx, "📦 将选中轨道打包为子工程", -1, 32) then
        pack_selected_tracks_to_subproject()
        save_state()
      end

      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, "📦 将选中 Items 所在轨道打包为子工程", -1, 32) then
        pack_selected_items_to_subproject()
        save_state()
      end
    end

    -- Status bar
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    ImGui.TextDisabled(ctx, "提示: " .. status_msg)

    ImGui.End(ctx)
  end

  fl.pop_theme(ctx, nc, nv)

  if p_open then
    r.defer(loop)
  else
    save_state()
    BST_SUBPROJ_LIVE = nil
  end
end

-- Auto-guess subproject name on launch
st.sub_name = guess_subproject_name()
r.defer(loop)
