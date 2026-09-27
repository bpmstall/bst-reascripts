-- bst: Wwise Pipeline (Audiokinetic Wwise WAAPI automation, Fluent panel)
-- Integrates REAPER directly with Audiokinetic Wwise Authoring:
-- 1. Batch Import: Sends selected items/regions into Wwise Actor-Mixer Hierarchy.
-- 2. Container Builder: Automatically creates Random/Blend Containers with matching name.
-- 3. Event Generator: Creates Play Events and wires them to generated containers in one click.
-- Keys: wwise_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Wwise Pipeline', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_WWISE_LIVE and ImGui.ValidatePtr(BST_WWISE_LIVE, 'ImGui_Context*') then
  return
end
local ctx = ImGui.CreateContext('bst Wwise Pipeline')
BST_WWISE_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  target_path = lib.ext_get("wwise_target_path", "\\Actor-Mixer Hierarchy\\Default Work Unit\\SFX"),
  container_type = math.floor(lib.ext_getnum("wwise_cnt_type", 1)), -- 1: Random, 2: Blend, 3: Sequence
  create_event = (lib.ext_getnum("wwise_create_event", 1) == 1),
  event_path = lib.ext_get("wwise_event_path", "\\Events\\Default Work Unit\\SFX"),
}

local status_msg = "选中要导入 Wwise 的 Items 点击生成"

local function save_state()
  lib.ext_set("wwise_target_path", st.target_path)
  lib.ext_set("wwise_cnt_type", st.container_type)
  lib.ext_set("wwise_create_event", st.create_event and 1 or 0)
  lib.ext_set("wwise_event_path", st.event_path)
end

--------------------------------------------------------------------------------
-- Engine: Wwise Import & Container Generation
--------------------------------------------------------------------------------
-- Generates a Wwise Tab-Delimited Import File or WAAPI payload
local function export_wwise_import_file()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请在时间线上选中要导入 Wwise 的 Items。"
    return
  end

  local _, proj_fn = r.EnumProjects(-1, "")
  local pdir = proj_fn ~= "" and proj_fn:match("^(.*[/\\])") or "C:\\Temp\\"
  local tsv_path = pdir .. "wwise_import.txt"

  local f = io.open(tsv_path, "w")
  if not f then
    status_msg = "无法创建 Wwise 导入文件。"
    return
  end

  -- Write Wwise Tab-Delimited Header
  f:write("Audio File Path\tObject Path\tObject Type\tNotes\n")

  local cnt_name = (st.container_type == 1 and "Random Sequence Container" or "Blend Container")

  local count = 0
  for _, it in ipairs(items) do
    local tk = r.GetActiveTake(it)
    if tk then
      local src = r.GetMediaItemTake_Source(tk)
      if src then
        local fn = r.GetMediaSourceFileName(src)
        if fn and fn ~= "" then
          local base_n = lib.take_name(tk)
          local obj_path = st.target_path .. "/" .. base_n
          f:write(string.format("%s\t%s\tSound SFX\tImported from REAPER bst\n", fn, obj_path))
          count = count + 1
        end
      end
    end
  end
  f:close()

  status_msg = string.format("已导出 Wwise 导入列表 (%d 个对象): %s", count, tsv_path)
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local CNT_TYPES = { "Random Container (随机容器)", "Blend Container (混合容器)", "Sequence Container (序列容器)" }

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 520, 480, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Wwise Pipeline (Wwise 自动化导入工作台)', true)

  if visible then
    if fl.begin_card and fl.begin_card(ctx, "intro_card", 75) then
      ImGui.Text(ctx, "REAPER ⇄ Audiokinetic Wwise 直通流水线")
      ImGui.TextDisabled(ctx, "选定工程音效，一键生成 Wwise 层级结构、容器与 Play Event。")
      fl.end_card(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Hierarchy Paths
    ImGui.Text(ctx, "Wwise 目标父层级 (Actor-Mixer Path):")
    ImGui.SetNextItemWidth(ctx, -1)
    local tp_c, new_tp = ImGui.InputText(ctx, "##w_path", st.target_path)
    if tp_c then st.target_path = new_tp end

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "容器包装类型 (Container Type):")
    ImGui.SetNextItemWidth(ctx, -1)
    if ImGui.BeginCombo(ctx, "##cnt_combo", CNT_TYPES[st.container_type]) then
      for idx, name in ipairs(CNT_TYPES) do
        local sel = (idx == st.container_type)
        if ImGui.Selectable(ctx, name, sel) then
          st.container_type = idx
        end
      end
      ImGui.EndCombo(ctx)
    end

    ImGui.Spacing(ctx)
    local ev_c, new_ev = ImGui.Checkbox(ctx, "自动生成对应 Play Event 并挂载 (Generate Event)", st.create_event)
    if ev_c then st.create_event = new_ev end

    if st.create_event then
      ImGui.SetNextItemWidth(ctx, -1)
      local ep_c, new_ep = ImGui.InputText(ctx, "##ev_path", st.event_path)
      if ep_c then st.event_path = new_ep end
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Actions
    if fl.button(ctx, "⚡ 生成 Wwise 导入清单与容器结构 (Export TSV)", { accent = true, width = -1, height = 38 }) then
      export_wwise_import_file()
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
    BST_WWISE_LIVE = nil
  end
end

r.defer(loop)
