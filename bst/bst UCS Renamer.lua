-- bst: UCS Renamer (Universal Category System 8.2 audio naming tool, Fluent panel)
-- Standardizes sound effect names according to the Universal Category System (UCS).
-- Provides fast categorized presets (SWSH, IMPT, EXPL, MGIC, FOOT, UI, CREA, MECH)
-- with auto-incrementing serial numbers and customizable project prefixes.
-- Keys: ucs_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst UCS Renamer', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_UCS_LIVE and ImGui.ValidatePtr(BST_UCS_LIVE, 'ImGui_Context*') then
  return -- singleton panel already open
end
local ctx = ImGui.CreateContext('bst UCS Renamer')
BST_UCS_LIVE = ctx

--------------------------------------------------------------------------------
-- Categories (UCS standard)
--------------------------------------------------------------------------------
local UCS_CATEGORIES = {
  { id = "SWSH", name = "SWSH (挥砍/呼啸 Whoosh & Swish)" },
  { id = "IMPT", name = "IMPT (撞击/受击 Impacts & Hits)" },
  { id = "EXPL", name = "EXPL (爆炸/崩塌 Explosions)" },
  { id = "MGIC", name = "MGIC (魔法/能量 Magic & Spells)" },
  { id = "FOOT", name = "FOOT (脚步/移动 Footsteps)" },
  { id = "CREA", name = "CREA (怪物/生物 Creatures)" },
  { id = "MECH", name = "MECH (机械/机关 Mechanical)" },
  { id = "WEAP", name = "WEAP (武器/枪械 Weapons & Guns)" },
  { id = "UI",   name = "UI   (界面/系统 User Interface)" },
  { id = "SCIF", name = "SCIF (科幻/异界 Sci-Fi)" },
  { id = "WATR", name = "WATR (水流/液体 Water)" },
  { id = "VOIS", name = "VOIS (人声/发声 Voices)" },
}

local st = {
  cat_idx     = math.floor(lib.ext_getnum("ucs_cat_idx", 1)),
  sub_name    = lib.ext_get("ucs_sub", "Sword_Slash"),
  creator_tag = lib.ext_get("ucs_creator", "SFX"),
  start_num   = math.floor(lib.ext_getnum("ucs_start_num", 1)),
  digits      = math.floor(lib.ext_getnum("ucs_digits", 2)),
}

local status_msg = "在时间线上选中要命名的 Items"

local function save_state()
  lib.ext_set("ucs_cat_idx", st.cat_idx)
  lib.ext_set("ucs_sub", st.sub_name)
  lib.ext_set("ucs_creator", st.creator_tag)
  lib.ext_set("ucs_start_num", st.start_num)
  lib.ext_set("ucs_digits", st.digits)
end

--------------------------------------------------------------------------------
-- Engine: UCS Renaming
--------------------------------------------------------------------------------
local function apply_ucs_rename()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请在时间线上选中要重命名的 Items。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local cat = UCS_CATEGORIES[st.cat_idx] and UCS_CATEGORIES[st.cat_idx].id or "SFX"
  local clean_sub = st.sub_name:gsub("%s+", "_"):gsub("[^%w_%-]", "")
  if clean_sub == "" then clean_sub = "Sound" end

  local fmt = string.format("%%0%dd", math.max(1, st.digits))

  local count = 0
  for i, it in ipairs(items) do
    local take = r.GetActiveTake(it)
    if take then
      local num_str = string.format(fmt, st.start_num + i - 1)
      local full_name = string.format("%s_%s_%s", cat, clean_sub, num_str)
      if st.creator_tag and st.creator_tag ~= "" then
        full_name = full_name .. "_" .. st.creator_tag
      end
      lib.set_take_name(take, full_name)
      count = count + 1
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst UCS: 重命名 %d 个 Items", count), -1)
  status_msg = string.format("已按 UCS 标准规范重命名 %d 个 Items！", count)
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 480, 420, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst UCS Renamer (工业级音效分类命名)', true)

  if visible then
    if fl.card then fl.card(ctx, function()
      ImGui.Text(ctx, "Universal Category System (UCS 8.2) 行业标准命名")
      ImGui.TextDisabled(ctx, "按全球游戏与影视音效规范自动组装 CatID_Description_Index 命名。")
    end) end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Category selector
    ImGui.Text(ctx, "音效主大类 (UCS Category ID):")
    ImGui.SetNextItemWidth(ctx, -1)
    local cur_name = UCS_CATEGORIES[st.cat_idx] and UCS_CATEGORIES[st.cat_idx].name or "选择类别"
    if ImGui.BeginCombo(ctx, "##cat_combo", cur_name) then
      for idx, cat in ipairs(UCS_CATEGORIES) do
        local sel = (idx == st.cat_idx)
        if ImGui.Selectable(ctx, cat.name, sel) then
          st.cat_idx = idx
        end
      end
      ImGui.EndCombo(ctx)
    end

    ImGui.Spacing(ctx)

    -- Description & Creator
    ImGui.Text(ctx, "子类与描述 (SubCategory / Sound Name):")
    ImGui.SetNextItemWidth(ctx, -1)
    local sn_c, new_sn = ImGui.InputText(ctx, "##sub_input", st.sub_name)
    if sn_c then st.sub_name = new_sn end

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "创作者/项目标签 (Creator / Vendor Tag):")
    ImGui.SetNextItemWidth(ctx, 160)
    local ct_c, new_ct = ImGui.InputText(ctx, "##creator_input", st.creator_tag)
    if ct_c then st.creator_tag = new_ct end

    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 100)
    local sn_num, new_num = ImGui.DragInt(ctx, "起始号##snum", st.start_num, 0.2, 0, 999)
    if sn_num then st.start_num = new_num end

    -- Preview naming template
    local cat_id = UCS_CATEGORIES[st.cat_idx] and UCS_CATEGORIES[st.cat_idx].id or "SFX"
    local sample_preview = string.format("%s_%s_%02d%s.wav", cat_id, st.sub_name, st.start_num, (st.creator_tag ~= "" and ("_" .. st.creator_tag) or ""))
    ImGui.Spacing(ctx)
    ImGui.TextColored(ctx, 0x4CC2FFFF, "命名示例预览: " .. sample_preview)

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if fl.button_accent then
      if fl.button_accent(ctx, "🏷️ 批量应用 UCS 标准重命名 (Apply Rename)", -1, 38) then
        apply_ucs_rename()
        save_state()
      end
    else
      if ImGui.Button(ctx, "批量应用 UCS 标准重命名", -1, 38) then
        apply_ucs_rename()
        save_state()
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
    BST_UCS_LIVE = nil
  end
end

r.defer(loop)
