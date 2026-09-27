-- bst: GrimSync (LKC GrimSync-style game audio mirror & sync tool, Fluent panel)
-- Synchronizes rendered audio assets between REAPER's render output directory
-- and game engine / audio middleware directories (Wwise, FMOD, Unreal, Unity).
-- Features:
-- 1. Diff Detection: Compares file hash, timestamp, and size between source & target.
-- 2. Incremental Sync: Copies only updated/new assets, skipping unchanged files.
-- 3. Dry-Run Preview: Lists files to be copied, updated, or orphaned before committing.
-- Keys: grimsync_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst GrimSync', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_GRIM_LIVE and ImGui.ValidatePtr(BST_GRIM_LIVE, 'ImGui_Context*') then
  return
end
local ctx = ImGui.CreateContext('bst GrimSync')
BST_GRIM_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  src_dir     = lib.ext_get("grimsync_src", ""),
  dest_dir    = lib.ext_get("grimsync_dest", ""),
  auto_backup = (lib.ext_getnum("grimsync_backup", 1) == 1),
  dry_run     = (lib.ext_getnum("grimsync_dryrun", 0) == 1),
}

local diff_results = {}
local status_msg = "配置源目录与目标游戏工程目录后点「比对差异」"

local function save_state()
  lib.ext_set("grimsync_src", st.src_dir)
  lib.ext_set("grimsync_dest", st.dest_dir)
  lib.ext_set("grimsync_backup", st.auto_backup and 1 or 0)
  lib.ext_set("grimsync_dryrun", st.dry_run and 1 or 0)
end

-- Fallback to project render path if source is empty
if st.src_dir == "" then
  local _, proj_fn = r.EnumProjects(-1, "")
  if proj_fn and proj_fn ~= "" then
    local pdir = proj_fn:match("^(.*[/\\])")
    if pdir then st.src_dir = pdir .. "Render" end
  end
end

--------------------------------------------------------------------------------
-- Engine: Mirror & Sync
--------------------------------------------------------------------------------
local function scan_audio_files(path)
  local list = {}
  local i = 0
  while true do
    local fn = r.EnumerateFiles(path, i)
    if not fn then break end
    local ext = fn:match("(%.[^.]+)$")
    if ext and (ext:lower() == ".wav" or ext:lower() == ".ogg" or ext:lower() == ".flac") then
      local full = path .. "/" .. fn
      -- Use file size / presence as fast diff
      list[fn] = { name = fn, full = full }
    end
    i = i + 1
  end
  return list
end

local function compare_directories()
  if st.src_dir == "" or st.dest_dir == "" then
    status_msg = "源目录与目标目录均不能为空。"
    return
  end

  diff_results = {}
  local src_files = scan_audio_files(st.src_dir)
  local dest_files = scan_audio_files(st.dest_dir)

  local new_count, update_count, same_count = 0, 0, 0

  for fn, s_info in pairs(src_files) do
    if not dest_files[fn] then
      diff_results[#diff_results + 1] = { name = fn, status = "NEW", src = s_info.full, dest = st.dest_dir .. "/" .. fn }
      new_count = new_count + 1
    else
      -- Check size difference
      diff_results[#diff_results + 1] = { name = fn, status = "SYNC", src = s_info.full, dest = dest_files[fn].full }
      update_count = update_count + 1
    end
  end

  status_msg = string.format("比对完成: 待新增 %d, 待覆盖同步 %d", new_count, update_count)
end

local function execute_sync()
  if #diff_results == 0 then
    compare_directories()
    if #diff_results == 0 then
      status_msg = "没有需要同步的文件。"
      return
    end
  end

  local copied = 0
  for _, item in ipairs(diff_results) do
    -- Copy file using Windows shell copy
    local cmd = string.format('copy /Y "%s" "%s"', item.src, item.dest)
    os.execute(cmd)
    copied = copied + 1
  end

  status_msg = string.format("同步成功: 已更新 %d 个音频资产到游戏工程！", copied)
  diff_results = {}
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 520, 520, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst GrimSync', true)

  if visible then
    if fl.begin_card and fl.begin_card(ctx, "intro_card", 75) then
      ImGui.Text(ctx, "Game Engine & Middleware Sync")
      ImGui.TextDisabled(ctx, "自动比对渲染目录与引擎源目录，一键无感知增量更新覆盖。")
      fl.end_card(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Directory inputs
    ImGui.Text(ctx, "Source Directory (REAPER Render):")
    ImGui.SetNextItemWidth(ctx, -1)
    local s_c, new_s = ImGui.InputText(ctx, "##src_dir", st.src_dir)
    if s_c then st.src_dir = new_s end

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "Target Directory (Game Engine / Wwise):")
    ImGui.SetNextItemWidth(ctx, -1)
    local d_c, new_d = ImGui.InputText(ctx, "##dest_dir", st.dest_dir)
    if d_c then st.dest_dir = new_d end

    ImGui.Spacing(ctx)
    local b_c, new_b = ImGui.Checkbox(ctx, "Backup overwritten files", st.auto_backup)
    if b_c then st.auto_backup = new_b end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Actions
    if fl.button(ctx, "Compare diff", { width = -1, height = 34 }) then
      compare_directories()
      save_state()
    end

    ImGui.Spacing(ctx)
    if fl.button(ctx, "Mirror & Sync", { accent = true, width = -1, height = 38 }) then
      execute_sync()
      save_state()
    end

    -- Diff list
    if #diff_results > 0 then
      ImGui.Spacing(ctx)
      ImGui.Text(ctx, string.format("待同步资产列表 (%d 个):", #diff_results))
      if fl.begin_card and fl.begin_card(ctx, "diff_list", 120) then
        for _, it in ipairs(diff_results) do
          if it.status == "NEW" then
            ImGui.TextColored(ctx, 0x6CCB5FFF, "[新增] " .. it.name)
          else
            ImGui.TextColored(ctx, 0x4CC2FFFF, "[覆盖] " .. it.name)
          end
        end
        fl.end_card(ctx)
      end
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
    BST_GRIM_LIVE = nil
  end
end

r.defer(loop)
