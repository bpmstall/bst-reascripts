-- bst: Folder Items (nvk_FOLDER_ITEMS-style parent track container workflow, Fluent panel)
-- Creates and manages container items on folder tracks that mirror child track extents.
-- Allows sound designers to move, duplicate, trim, color, and batch-name complex
-- multi-layer sounds as single units from the top-level folder track.
-- Keys: fi_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Folder Items', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_FI_LIVE and ImGui.ValidatePtr(BST_FI_LIVE, 'ImGui_Context*') then
  return -- singleton panel already open
end
local ctx = ImGui.CreateContext('bst Folder Items')
BST_FI_LIVE = ctx

--------------------------------------------------------------------------------
-- State & Preferences
--------------------------------------------------------------------------------
local st = {
  pad_ms      = lib.ext_getnum("fi_pad_ms", 0),
  color_sync  = (lib.ext_getnum("fi_color_sync", 1) == 1),
  cascade_name = (lib.ext_getnum("fi_cascade_name", 1) == 1),
  auto_group  = (lib.ext_getnum("fi_auto_group", 1) == 1),
}

local status_msg = "就绪"

local function save_state()
  lib.ext_set("fi_pad_ms", st.pad_ms)
  lib.ext_set("fi_color_sync", st.color_sync and 1 or 0)
  lib.ext_set("fi_cascade_name", st.cascade_name and 1 or 0)
  lib.ext_set("fi_auto_group", st.auto_group and 1 or 0)
end

--------------------------------------------------------------------------------
-- Engine: Folder Items Detection & Creation
--------------------------------------------------------------------------------

-- Returns list of all child tracks for a given folder track
local function get_child_tracks(folder_track)
  local children = {}
  local depth = r.GetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH")
  if depth ~= 1 then return children end

  local folder_idx = r.GetMediaTrackInfo_Value(folder_track, "IP_TRACKNUMBER") - 1
  local cur_depth = 1
  local total_tracks = r.GetNumTracks()

  for i = folder_idx + 1, total_tracks - 1 do
    local tr = r.GetTrack(0, i)
    children[#children + 1] = tr
    local d = r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    cur_depth = cur_depth + d
    if cur_depth <= 0 then break end
  end
  return children
end

-- Find clusters/clusters of items in child tracks to form parent container items
local function generate_folder_items()
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local selected_tracks = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do
    selected_tracks[#selected_tracks + 1] = r.GetSelectedTrack(0, i)
  end

  -- If no tracks selected, scan all folder tracks
  if #selected_tracks == 0 then
    for i = 0, r.GetNumTracks() - 1 do
      local tr = r.GetTrack(0, i)
      if r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
        selected_tracks[#selected_tracks + 1] = tr
      end
    end
  end

  local created_count = 0
  local pad = st.pad_ms / 1000

  for _, folder_tr in ipairs(selected_tracks) do
    if r.GetMediaTrackInfo_Value(folder_tr, "I_FOLDERDEPTH") == 1 then
      local children = get_child_tracks(folder_tr)
      local all_items = {}
      for _, ch in ipairs(children) do
        for k = 0, r.CountTrackMediaItems(ch) - 1 do
          all_items[#all_items + 1] = r.GetTrackMediaItem(ch, k)
        end
      end

      -- Sort items by position
      table.sort(all_items, function(a, b)
        return r.GetMediaItemInfo_Value(a, "D_POSITION") < r.GetMediaItemInfo_Value(b, "D_POSITION")
      end)

      -- Group overlapping/close items into sound event blocks
      local blocks = {}
      local cur_block = nil

      for _, it in ipairs(all_items) do
        local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
        local l = r.GetMediaItemInfo_Value(it, "D_LENGTH")
        local e = p + l

        if not cur_block then
          cur_block = { s = p, e = e, items = { it } }
        else
          -- If close within 0.15s, merge into same event block
          if p <= cur_block.e + 0.15 then
            if e > cur_block.e then cur_block.e = e end
            cur_block.items[#cur_block.items + 1] = it
          else
            blocks[#blocks + 1] = cur_block
            cur_block = { s = p, e = e, items = { it } }
          end
        end
      end
      if cur_block then blocks[#blocks + 1] = cur_block end

      -- Create Folder Items on parent track
      local _, folder_name = r.GetTrackName(folder_tr)
      for _, blk in ipairs(blocks) do
        local start_pos = math.max(0, blk.s - pad)
        local len = (blk.e - blk.s) + pad * 2

        local fi = r.AddMediaItemToTrack(folder_tr)
        r.SetMediaItemInfo_Value(fi, "D_POSITION", start_pos)
        r.SetMediaItemInfo_Value(fi, "D_LENGTH", len)

        -- Create empty text/label take
        local take = r.AddTakeToMediaItem(fi)
        lib.set_take_name(take, folder_name ~= "" and folder_name or "Event")

        -- Sync track color if enabled
        if st.color_sync then
          local color = r.GetTrackColor(folder_tr)
          if color ~= 0 then r.SetMediaItemInfo_Value(fi, "I_CUSTOMCOLOR", color) end
        end

        -- Auto group folder item with its children items
        if st.auto_group then
          local grp_id = math.random(1, 65535)
          r.SetMediaItemInfo_Value(fi, "I_GROUPID", grp_id)
          for _, it in ipairs(blk.items) do
            r.SetMediaItemInfo_Value(it, "I_GROUPID", grp_id)
          end
        end

        created_count = created_count + 1
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: 生成 %d 个 Folder Items", created_count), -1)
  status_msg = string.format("成功生成 %d 个 Folder Items！", created_count)
end

-- Cascade names from parent folder item down to all children items inside its bounds
local function cascade_names_from_folder_items()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请在折叠轨上选中至少一个 Folder Item。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local count = 0

  for _, fi in ipairs(items) do
    local tr = r.GetMediaItem_Track(fi)
    if r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
      local take = r.GetActiveTake(fi)
      local base_name = lib.take_name(take)
      if base_name ~= "" then
        local p = r.GetMediaItemInfo_Value(fi, "D_POSITION")
        local l = r.GetMediaItemInfo_Value(fi, "D_LENGTH")
        local e = p + l

        local children = get_child_tracks(tr)
        for _, ch in ipairs(children) do
          local _, ch_name = r.GetTrackName(ch)
          for k = 0, r.CountTrackMediaItems(ch) - 1 do
            local child_it = r.GetTrackMediaItem(ch, k)
            local cp = r.GetMediaItemInfo_Value(child_it, "D_POSITION")
            if cp >= p - 0.05 and cp < e then
              local ctake = r.GetActiveTake(child_it)
              if ctake then
                local final_n = base_name .. "_" .. (ch_name ~= "" and ch_name or "sub")
                lib.set_take_name(ctake, final_n)
                count = count + 1
              end
            end
          end
        end
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("bst: 级联命名子条目", -1)
  status_msg = string.format("已级联重命名 %d 个子条目！", count)
end

-- Select all child items under selected folder items
local function select_children_of_folder_items()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请在折叠轨上选中 Folder Item。"
    return
  end

  local children_to_select = {}
  for _, fi in ipairs(items) do
    local tr = r.GetMediaItem_Track(fi)
    if r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
      local p = r.GetMediaItemInfo_Value(fi, "D_POSITION")
      local e = p + r.GetMediaItemInfo_Value(fi, "D_LENGTH")
      local children = get_child_tracks(tr)
      for _, ch in ipairs(children) do
        for k = 0, r.CountTrackMediaItems(ch) - 1 do
          local child_it = r.GetTrackMediaItem(ch, k)
          local cp = r.GetMediaItemInfo_Value(child_it, "D_POSITION")
          if cp >= p - 0.05 and cp < e then
            children_to_select[#children_to_select + 1] = child_it
          end
        end
      end
    end
  end

  for _, it in ipairs(children_to_select) do
    r.SetMediaItemSelected(it, true)
  end
  r.UpdateArrange()
  status_msg = string.format("已联动选中 %d 个子轨 Items！", #children_to_select)
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 480, 390, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Folder Items (nvk_FOLDER_ITEMS 式折叠管理)', true)

  if visible then
    if fl.card then fl.card(ctx, function()
      ImGui.Text(ctx, "Folder Item 容器控制")
      ImGui.TextDisabled(ctx, "在父级折叠轨生成总控 Item，移动/缩放/重命名时子轨素材同步。")
    end) end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Options
    ImGui.Text(ctx, "生成与联动选项:")
    ImGui.SetNextItemWidth(ctx, 130)
    local pd_c, new_pd = ImGui.DragDouble(ctx, "左右余量 (Padding ms)", st.pad_ms, 5, 0, 1000, "%.0f ms")
    if pd_c then st.pad_ms = new_pd end

    local cs_c, new_cs = ImGui.Checkbox(ctx, "跟随父轨道颜色 (Color Sync)", st.color_sync)
    if cs_c then st.color_sync = new_cs end

    ImGui.SameLine(ctx)
    local ag_c, new_ag = ImGui.Checkbox(ctx, "生成后自动群组绑定 (Auto Group)", st.auto_group)
    if ag_c then st.auto_group = new_ag end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Actions
    if fl.button_accent then
      if fl.button_accent(ctx, "📂 为折叠轨生成 Folder Items (按子轨自动识别)", -1, 36) then
        generate_folder_items()
        save_state()
      end
    else
      if ImGui.Button(ctx, "为折叠轨生成 Folder Items", -1, 36) then
        generate_folder_items()
        save_state()
      end
    end

    ImGui.Spacing(ctx)
    if ImGui.Button(ctx, "🏷️ 从选中的 Folder Item 级联重命名子轨素材", -1, 30) then
      cascade_names_from_folder_items()
      save_state()
    end

    ImGui.Spacing(ctx)
    if ImGui.Button(ctx, "🔗 选中 Folder Item 下对应的全部子轨素材", -1, 30) then
      select_children_of_folder_items()
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
    BST_FI_LIVE = nil
  end
end

r.defer(loop)
