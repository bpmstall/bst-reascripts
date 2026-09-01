-- bst_fluent.lua — Fluent 2 design system for ReaImGui
-- Tokens sourced from WinUI 3 Common_themeresources.any.xaml (Windows 11),
-- @fluentui/tokens (Fluent 2 web) and WinUI control theme resources.
-- Usage:
--   local fl = dofile(dir .. "bst_fluent.lua")(ImGui)   -- after requiring imgui
--   fl.attach_fonts(ctx)                               -- once after CreateContext
--   -- each frame, around your Begin/End:
--   local nc, nv = fl.push_theme(ctx)
--     ... ImGui.Begin / widgets / ImGui.End ...
--   fl.pop_theme(ctx, nc, nv)

return function(ImGui)

local M = {}

--------------------------------------------------------------------------------
-- palettes (0xRRGGBBAA)

local DARK = {
  -- text
  text_pri = 0xFFFFFFFF, text_sec = 0xFFFFFFC5, text_tri = 0xFFFFFF87, text_dis = 0xFFFFFF5D,
  -- control fills (rest / hover / pressed)
  ctrl = 0xFFFFFF0F, ctrl_hov = 0xFFFFFF15, ctrl_act = 0xFFFFFF08, ctrl_dis = 0xFFFFFF0B,
  -- subtle (ghost) fills
  sub_hov = 0xFFFFFF0F, sub_act = 0xFFFFFF0A,
  -- strokes
  stroke = 0xFFFFFF12, stroke_hov = 0xFFFFFF18, stroke_strong = 0xFFFFFF8B,
  divider = 0xFFFFFF15,
  -- backgrounds
  bg = 0x202020FF, bg_2 = 0x1C1C1CFF, bg_3 = 0x282828FF, popup = 0x2C2C2CFA,
  card = 0xFFFFFF0D, layer = 0x3A3A3A4C,
  -- accent (Windows 11 default accent, Light-2 tint used by dark-theme fills)
  accent = 0x4CC2FFFF, accent_hov = 0x4CC2FFE5, accent_act = 0x4CC2FFCC,
  accent_dis = 0xFFFFFF28, on_accent = 0x000000FF,
  -- status (icon/dot colors + InfoBar backgrounds)
  ok = 0x6CCB5FFF, warn = 0xFCE100FF, bad = 0xFF99A4FF,
  ok_bg = 0x393D1BFF, warn_bg = 0x433519FF, bad_bg = 0x442726FF, info_bg = 0x3A3A3A4C,
}

local LIGHT = {
  text_pri = 0x000000E4, text_sec = 0x0000009E, text_tri = 0x00000072, text_dis = 0x0000005C,
  ctrl = 0xFFFFFFB3, ctrl_hov = 0xF9F9F980, ctrl_act = 0xF9F9F94D, ctrl_dis = 0xF9F9F94D,
  sub_hov = 0x00000009, sub_act = 0x00000006,
  stroke = 0x0000000F, stroke_hov = 0x00000029, stroke_strong = 0x00000072,
  divider = 0x0000000F,
  bg = 0xF3F3F3FF, bg_2 = 0xEEEEEEFF, bg_3 = 0xF9F9F9FF, popup = 0xFAFAFAFA,
  card = 0xFFFFFFB3, layer = 0xFFFFFF80,
  accent = 0x0078D4FF, accent_hov = 0x0078D4E5, accent_act = 0x0078D4CC,
  accent_dis = 0x00000037, on_accent = 0xFFFFFFFF,
  ok = 0x0F7B0FFF, warn = 0x9D5D00FF, bad = 0xC42B1CFF,
  ok_bg = 0xDFF6DDFF, warn_bg = 0xFFF4CEFF, bad_bg = 0xFDE7E9FF, info_bg = 0xF5F5F5FF,
}

M.dark, M.light = DARK, LIGHT
local T = DARK

function M.set_theme(name) T = (name == "light") and LIGHT or DARK end

--------------------------------------------------------------------------------
-- typography ramp (Segoe UI Variable equivalents; weight approximated by size)

M.RAMP = { caption = 12, body = 14, body_large = 18, subtitle = 20, title = 28 }

--------------------------------------------------------------------------------
-- theme application (per-frame push/pop, CBM-style counted pairing)

local cols, vars = {}, {}

-- Resolve an enum by trying candidate names. Accessing an unknown field on the
-- ImGui table THROWS (custom __index), so probe through pcall. First numeric
-- hit wins; none -> nil (push_theme skips it). Needed because newer ReaImGui
-- builds track upstream renames (e.g. Col_TabActive -> Col_TabSelected).
local function E(...)
  local n = select('#', ...)
  for i = 1, n do
    local name = select(i, ...)   -- capture before the closure: '...' can't cross into it
    local ok, v = pcall(function() return ImGui[name] end)
    if ok and type(v) == 'number' then return v end
  end
end

local function build()
  cols = {
    { E("Col_Text"),            T.text_pri },
    { E("Col_TextDisabled"),    T.text_dis },
    { E("Col_WindowBg"),        T.bg },
    { E("Col_ChildBg"),         T.bg },
    { E("Col_PopupBg"),         T.popup },
    { E("Col_Border"),          T.stroke },
    { E("Col_TitleBg"),         T.bg },
    { E("Col_TitleBgActive"),   T.bg },
    { E("Col_TitleBgCollapsed"),T.bg },
    { E("Col_MenuBarBg"),       T.bg_2 },
    { E("Col_ScrollbarBg"),     T.bg },
    { E("Col_ScrollbarGrab"),   T.ctrl },
    { E("Col_ScrollbarGrabHovered"), T.ctrl_hov },
    { E("Col_ScrollbarGrabActive"),  T.ctrl_act },
    { E("Col_FrameBg"),         T.ctrl },
    { E("Col_FrameBgHovered"),  T.ctrl_hov },
    { E("Col_FrameBgActive"),   T.ctrl_act },
    { E("Col_Button"),          T.ctrl },
    { E("Col_ButtonHovered"),   T.ctrl_hov },
    { E("Col_ButtonActive"),    T.ctrl_act },
    { E("Col_Header"),          T.sub_hov },
    { E("Col_HeaderHovered"),   T.sub_hov },
    { E("Col_HeaderActive"),    T.sub_act },
    { E("Col_CheckMark"),       T.accent },
    { E("Col_SliderGrab"),      T.accent },
    { E("Col_SliderGrabActive"),T.accent_act },
    { E("Col_Separator"),       T.divider },
    { E("Col_SeparatorHovered"),T.divider },
    { E("Col_SeparatorActive"), T.divider },
    -- tabs: >=1.92 uses Selected/Dimmed names, older builds Active/Unfocused
    { E("Col_Tab", "Col_TabDimmed"),                 T.bg },
    { E("Col_TabHovered"),                           T.ctrl_hov },
    { E("Col_TabSelected", "Col_TabActive"),         T.bg_3 },
    { E("Col_TabDimmedSelected", "Col_TabUnfocusedActive"), T.bg_3 },
    { E("Col_TabSelectedOverline"),                  T.accent },
    { E("Col_ResizeGrip"),      0 },
    { E("Col_ResizeGripHovered"), T.ctrl_hov },
    { E("Col_ResizeGripActive"),  T.ctrl_act },
    { E("Col_TableHeaderBg"),   T.bg_2 },
    { E("Col_TableRowBgAlt"),   T.card },
  }
  vars = {
    { E("StyleVar_WindowPadding"),   12, 12 },
    { E("StyleVar_FramePadding"),     9,  5 },
    { E("StyleVar_CellPadding"),      8,  4 },
    { E("StyleVar_ItemSpacing"),     10,  8 },
    { E("StyleVar_ItemInnerSpacing"), 6,  4 },
    { E("StyleVar_WindowRounding"),   8 },
    { E("StyleVar_ChildRounding"),    8 },
    { E("StyleVar_PopupRounding"),    8 },
    { E("StyleVar_FrameRounding"),    4 },
    { E("StyleVar_TabRounding"),      4 },
    { E("StyleVar_ScrollbarRounding"),4 },
    { E("StyleVar_GrabRounding"),     4 },
    { E("StyleVar_WindowBorderSize"), 1 },
    { E("StyleVar_ChildBorderSize"),  1 },
    { E("StyleVar_FrameBorderSize"),  1 },
  }
end
build()

-- Skips any enum this build lacks; returns (n_colors_pushed, n_vars_pushed).
function M.push_theme(ctx)
  local nc, nv = 0, 0
  for _, e in ipairs(cols) do
    if e[1] then ImGui.PushStyleColor(ctx, e[1], e[2]); nc = nc + 1 end
  end
  for _, e in ipairs(vars) do
    if e[1] then
      if e[3] then ImGui.PushStyleVar(ctx, e[1], e[2], e[3])
      else ImGui.PushStyleVar(ctx, e[1], e[2]) end
      nv = nv + 1
    end
  end
  return nc, nv
end

function M.pop_theme(ctx, nc, nv)
  if nv and nv > 0 then ImGui.PopStyleVar(ctx, nv) end
  if nc and nc > 0 then ImGui.PopStyleColor(ctx, nc) end
end

--------------------------------------------------------------------------------
-- fonts (Segoe Fluent Icons with MDL2 fallback; missing-file safe)

M.icon_font = nil

function M.attach_fonts(ctx)
  -- segmdl2 (Segoe MDL2 Assets) first: a static TTF that stb_truetype parses
  -- cleanly on Win10+11. Win11's SegoeFluent.ttf is a VARIABLE font —
  -- CreateFontFromFile "succeeds" but the broken glyphs poison the ImGui
  -- context on first render (observed: any widget using the font kills the
  -- context mid-frame), so it is fallback-only.
  for _, path in ipairs({ "C:/Windows/Fonts/segmdl2.ttf", "C:/Windows/Fonts/SegoeFluent.ttf" }) do
    local ok, f = pcall(ImGui.CreateFontFromFile, path)
    if ok and f and ImGui.ValidatePtr(f, "ImGui_Font*") then
      if pcall(ImGui.Attach, ctx, f) then M.icon_font = f; return true end
    end
  end
  return false
end

M.ICONS = {
  settings = 0xE713, search = 0xE721, play = 0xE768, pause = 0xE769,
  save = 0xE74E, add = 0xE710, remove = 0xE738, delete = 0xE74D,
  refresh = 0xE72C, sync = 0xE895, music = 0xEC4F, folder = 0xE8B7,
  folder_open = 0xE838, chevron_right = 0xE76C, chevron_down = 0xE70D,
  close = 0xE711, check = 0xE73E, edit = 0xE70F, copy = 0xE8C8,
  download = 0xE896, info = 0xE946, warning = 0xE7BA, error = 0xE783,
}

function M.icon(ctx, name, size)
  if not M.icon_font then return end
  local cp = type(name) == "number" and name or M.ICONS[name]
  if not cp then return end
  local ok = pcall(ImGui.PushFont, ctx, M.icon_font, size or 16)
  if ok then
    ImGui.Text(ctx, utf8.char(cp))
    ImGui.PopFont(ctx)
  end
end

-- text roles --------------------------------------------------------------
-- Optional UI font (e.g. a CJK face) used by text roles instead of the
-- built-in default, whose glyph set may not cover the user's language.
M.ui_font = nil
function M.set_ui_font(f) M.ui_font = f end

local function role_text(ctx, size, text, col)
  if col then ImGui.PushStyleColor(ctx, ImGui.Col_Text, col) end
  local ok = pcall(ImGui.PushFont, ctx, M.ui_font, size)
  ImGui.Text(ctx, text)
  if ok then ImGui.PopFont(ctx) end
  if col then ImGui.PopStyleColor(ctx) end
end

function M.caption(ctx, text, col)  role_text(ctx, M.RAMP.caption, text, col or T.text_sec) end
function M.body(ctx, text)          role_text(ctx, M.RAMP.body, text, nil) end
function M.body_large(ctx, text)    role_text(ctx, M.RAMP.body_large, text, nil) end
function M.subtitle(ctx, text)      role_text(ctx, M.RAMP.subtitle, text, nil) end
function M.title(ctx, text)         role_text(ctx, M.RAMP.title, text, nil) end

--------------------------------------------------------------------------------
-- controls

-- o: { accent=true } filled accent button | { subtle=true } ghost |
--    { danger=true } destructive | { width=, height= }
function M.button(ctx, label, o)
  o = o or {}
  local pushed = 0
  local function pc(col, c) ImGui.PushStyleColor(ctx, col, c); pushed = pushed + 1 end
  if o.accent then
    pc(ImGui.Col_Button, T.accent)
    pc(ImGui.Col_ButtonHovered, T.accent_hov)
    pc(ImGui.Col_ButtonActive, T.accent_act)
    pc(ImGui.Col_Text, T.on_accent)
  elseif o.subtle then
    pc(ImGui.Col_Button, 0)
    pc(ImGui.Col_ButtonHovered, T.sub_hov)
    pc(ImGui.Col_ButtonActive, T.sub_act)
  elseif o.danger then
    pc(ImGui.Col_Button, T.bad_bg)
    pc(ImGui.Col_ButtonHovered, T.bad)
    pc(ImGui.Col_ButtonActive, T.bad)
    pc(ImGui.Col_Text, T.bad)
  end
  local clicked = ImGui.Button(ctx, label, o.width or 0, o.height or 0)
  if pushed > 0 then ImGui.PopStyleColor(ctx, pushed) end
  return clicked
end

-- WinUI ToggleSwitch: 40x20 pill track, diameter-12 thumb, 4px insets.
-- Returns the new boolean value.
function M.toggle(ctx, label, value)
  if label and label ~= "" then
    ImGui.Text(ctx, label)
    ImGui.SameLine(ctx)
  end
  local w, h = 40, 20
  -- id 必须每个开关唯一: 同窗口同 id 的 InvisibleButton 是同一个控件
  -- (点击会命中第一个开关)。用标签派生 id, 无标签用自增计数兜底。
  M._tgl_n = (M._tgl_n or 0) + 1
  local bid = (label and label ~= "") and (label .. "##fl_tgl_" .. label)
              or ("##fl_tgl_" .. M._tgl_n)
  local clicked = ImGui.InvisibleButton(ctx, bid, w, h)
  local hovered = ImGui.IsItemHovered(ctx)
  local active = ImGui.IsItemActive(ctx)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local x2, y2 = ImGui.GetItemRectMax(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local r, cy = h * 0.5, (y1 + y2) * 0.5
  if value then
    local fill = active and T.accent_act or (hovered and T.accent_hov or T.accent)
    ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, fill, r)
    ImGui.DrawList_AddCircleFilled(dl, x2 - 10, cy, 6, T.on_accent)
  else
    local fill = active and 0xFFFFFF0A or (hovered and 0xFFFFFF18 or 0x00000000)
    ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, fill, r)
    ImGui.DrawList_AddRect(dl, x1, y1, x2, y2, T.stroke_strong, r, 0, 1)
    ImGui.DrawList_AddCircleFilled(dl, x1 + 10, cy, 6, T.text_sec)
  end
  if clicked then value = not value end
  return value
end

-- Rounded card container. height nil -> auto-size to content.
-- Clip-safe: when a card lands fully outside the scrolled viewport,
-- BeginChild returns WITHOUT pushing it and a paired EndChild asserts —
-- poisoning the whole context (observed on this build: every further call
-- hard-crashes REAPER). We track push results on a stack; end_card only
-- ends children that actually began, and skipped cards unwind their style
-- pushes immediately. Content between begin/end of a skipped card flows
-- into the parent at an already-clipped position, so nothing becomes
-- visible that shouldn't be.
local card_stack = {}

function M.begin_card(ctx, id, height)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, T.card)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, T.stroke)
  local flags = 0
  if height == nil then
    -- Dear ImGui >=1.91 ASSERTS unless AlwaysAutoResize is paired with
    -- AutoResizeX/Y (and the failed assertion poisons the whole context).
    -- AutoResizeY = fill width, hug content height. Older builds that lack
    -- the flag still accept standalone AlwaysAutoResize.
    flags = E("ChildFlags_AutoResizeY") or E("ChildFlags_AlwaysAutoResize") or 0
  end
  local pushed = ImGui.BeginChild(ctx, id, 0, height or 0, flags)
  card_stack[#card_stack + 1] = pushed and true or false
  if not pushed then
    ImGui.PopStyleColor(ctx, 2)
  end
  return pushed
end

function M.end_card(ctx)
  if table.remove(card_stack) then
    ImGui.EndChild(ctx)
    ImGui.PopStyleColor(ctx, 2)
  end
end

-- InfoBar: severity "info"|"ok"|"warn"|"bad"
-- Drawn directly on the window drawlist (a Dummy just reserves the strip).
-- The old BeginChild version broke on newer Dear ImGui: when a child ends up
-- clipped/skipped, BeginChild returns WITHOUT pushing it and the paired
-- EndChild asserts — poisoning the whole context.
function M.infobar(ctx, sev, text)
  local bg, dot
  if sev == "ok" then bg, dot = T.ok_bg, T.ok
  elseif sev == "warn" then bg, dot = T.warn_bg, T.warn
  elseif sev == "bad" then bg, dot = T.bad_bg, T.bad
  else bg, dot = T.info_bg, T.accent end
  local dl = ImGui.GetWindowDrawList(ctx)
  local x1, y1 = ImGui.GetCursorScreenPos(ctx)
  local w = select(1, ImGui.GetContentRegionAvail(ctx))
  ImGui.Dummy(ctx, math.max(w, 0), 30)
  ImGui.DrawList_AddRectFilled(dl, x1, y1, x1 + w, y1 + 30, bg, 6)
  ImGui.DrawList_AddCircleFilled(dl, x1 + 15, y1 + 15, 5, dot)
  ImGui.DrawList_AddText(dl, x1 + 28, y1 + 7, T.text_pri, text or "")
end

return M
end
