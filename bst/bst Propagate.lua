-- bst: Propagate (nvk_PROPAGATE-style property propagation, Fluent panel)
-- Propagates properties (fades, envelopes, volume, pan, pitch, length) from a
-- reference "master" item to all selected items or across target tracks.
-- Invaluable for keeping sound design variations consistent across batches.
-- Keys: prop_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Propagate', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_PROP_LIVE and ImGui.ValidatePtr(BST_PROP_LIVE, 'ImGui_Context*') then
  return -- singleton panel already open
end
local ctx = ImGui.CreateContext('bst Propagate')
BST_PROP_LIVE = ctx

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local st = {
  sync_fades    = (lib.ext_getnum("prop_fades", 1) == 1),
  sync_vol      = (lib.ext_getnum("prop_vol", 1) == 1),
  sync_pan      = (lib.ext_getnum("prop_pan", 0) == 1),
  sync_pitch    = (lib.ext_getnum("prop_pitch", 0) == 1),
  sync_len      = (lib.ext_getnum("prop_len", 0) == 1),
  sync_color    = (lib.ext_getnum("prop_color", 1) == 1),
}

local status_msg = "请先选中一个基准 Item（第一个选中的 Item 即为主模版）"

local function save_state()
  lib.ext_set("prop_fades", st.sync_fades and 1 or 0)
  lib.ext_set("prop_vol", st.sync_vol and 1 or 0)
  lib.ext_set("prop_pan", st.sync_pan and 1 or 0)
  lib.ext_set("prop_pitch", st.sync_pitch and 1 or 0)
  lib.ext_set("prop_len", st.sync_len and 1 or 0)
  lib.ext_set("prop_color", st.sync_color and 1 or 0)
end

--------------------------------------------------------------------------------
-- Engine: Property Propagation
--------------------------------------------------------------------------------
local function propagate_properties()
  local items = lib.selected_items()
  if #items < 2 then
    status_msg = "请至少选中 2 个 Item（第 1 个作为母版，其余作为目标）。"
    return
  end

  local master = items[1]
  local master_take = r.GetActiveTake(master)
  if not master_take then
    status_msg = "母版 Item 缺少有效 Take。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- Read master properties
  local m_fadein = r.GetMediaItemInfo_Value(master, "D_FADEINLEN")
  local m_fadeout = r.GetMediaItemInfo_Value(master, "D_FADEOUTLEN")
  local m_finshape = r.GetMediaItemInfo_Value(master, "C_FADEINSHAPE")
  local m_foutshape = r.GetMediaItemInfo_Value(master, "C_FADEOUTSHAPE")
  local m_vol = r.GetMediaItemInfo_Value(master, "D_VOL")
  local m_len = r.GetMediaItemInfo_Value(master, "D_LENGTH")
  local m_color = r.GetMediaItemInfo_Value(master, "I_CUSTOMCOLOR")

  local m_take_vol = r.GetMediaItemTakeInfo_Value(master_take, "D_VOL")
  local m_take_pan = r.GetMediaItemTakeInfo_Value(master_take, "D_PAN")
  local m_take_pitch = r.GetMediaItemTakeInfo_Value(master_take, "D_PITCH")
  local m_take_ppitch = r.GetMediaItemTakeInfo_Value(master_take, "B_PPITCH")

  local updated_count = 0

  for i = 2, #items do
    local it = items[i]
    local tk = r.GetActiveTake(it)

    if st.sync_fades then
      r.SetMediaItemInfo_Value(it, "D_FADEINLEN", m_fadein)
      r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", m_fadeout)
      r.SetMediaItemInfo_Value(it, "C_FADEINSHAPE", m_finshape)
      r.SetMediaItemInfo_Value(it, "C_FADEOUTSHAPE", m_foutshape)
    end

    if st.sync_vol then
      r.SetMediaItemInfo_Value(it, "D_VOL", m_vol)
      if tk then r.SetMediaItemTakeInfo_Value(tk, "D_VOL", m_take_vol) end
    end

    if st.sync_pan and tk then
      r.SetMediaItemTakeInfo_Value(tk, "D_PAN", m_take_pan)
    end

    if st.sync_pitch and tk then
      r.SetMediaItemTakeInfo_Value(tk, "D_PITCH", m_take_pitch)
      r.SetMediaItemTakeInfo_Value(tk, "B_PPITCH", m_take_ppitch)
    end

    if st.sync_len then
      r.SetMediaItemInfo_Value(it, "D_LENGTH", m_len)
    end

    if st.sync_color then
      r.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", m_color)
    end

    updated_count = updated_count + 1
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: 属性传播至 %d 个 Item", updated_count), -1)
  status_msg = string.format("成功将母版属性同步到 %d 个目标 Item！", updated_count)
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 450, 380, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Propagate (nvk_PROPAGATE 式属性同步)', true)

  if visible then
    if fl.card then fl.card(ctx, function()
      ImGui.Text(ctx, "音效变奏属性一键传播同步")
      ImGui.TextDisabled(ctx, "按选中顺序：第 1 个为母版，后续选中的 Items 继承指定属性。")
    end) end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    ImGui.Text(ctx, "选择要传播同步的属性项:")

    local sf_c, new_sf = ImGui.Checkbox(ctx, "淡入淡出时长与曲线形状 (Fades & Curves)", st.sync_fades)
    if sf_c then st.sync_fades = new_sf end

    local sv_c, new_sv = ImGui.Checkbox(ctx, "条目与 Take 音量增益 (Volume dB)", st.sync_vol)
    if sv_c then st.sync_vol = new_sv end

    local sp_c, new_sp = ImGui.Checkbox(ctx, "声像分布 (Pan)", st.sync_pan)
    if sp_c then st.sync_pan = new_sp end

    local spi_c, new_spi = ImGui.Checkbox(ctx, "音高与保持算法 (Pitch & Preserve)", st.sync_pitch)
    if spi_c then st.sync_pitch = new_spi end

    local sl_c, new_sl = ImGui.Checkbox(ctx, "裁剪音效长度 (Item Length)", st.sync_len)
    if sl_c then st.sync_len = new_sl end

    local sc_c, new_sc = ImGui.Checkbox(ctx, "自定义色彩标记 (Item Color)", st.sync_color)
    if sc_c then st.sync_color = new_sc end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if fl.button_accent then
      if fl.button_accent(ctx, "🚀 立即传播同步到其余选中 Item", -1, 36) then
        propagate_properties()
        save_state()
      end
    else
      if ImGui.Button(ctx, "立即传播同步到其余选中 Item", -1, 36) then
        propagate_properties()
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
    BST_PROP_LIVE = nil
  end
end

r.defer(loop)
