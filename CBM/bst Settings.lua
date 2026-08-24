--[[
  bst Settings — 剪贴板管理器设置面板 (Fluent 版, 独立脚本)
  =====================================================================
  由 CBM Settings.lua 重构: UI 迁移到 Fluent 2 (ox_fluent), 设置项与
  存储协议不变 —— 与主脚本 (bst Clipboard Manager.lua) 共享同一份
  ext state ("CBM" / "CBM_UI" 段), 两边实时互通:
    · 主脚本启动时读取 settings 覆盖默认值
    · 本面板改动立即写回, 主脚本下一次捕获/拖出即生效

  设置项:
    ffmpeg        可执行文件路径(或目录)     → "CBM" 段 settings
    cap           剪贴板历史上限
    slice_mode    默认切片模式 off/fixed/transients/beats
    slice_fixed   固定切片秒数
    slice_thresh  瞬态切片阈值
    visible       主面板显隐                  → "CBM" 段独立键
    win_w/win_h   主窗口宽/高                 → "CBM_UI" 段
    drop_mode     拖出落点 cursor=编辑光标 / mouse=鼠标位置

  依赖: ReaImGui (>=0.10) + Scripts/OxTools/ox_fluent.lua
--]]

local r = reaper

local DEBUG = false
local function log(...)
  if DEBUG then reaper.ShowConsoleMsg(...) end
end

-- ==================== 与主脚本一致的设置存取 ====================

local SET_KEY = 'CBM'
local UI_KEY  = 'CBM_UI'

local DEFAULTS = {
  ffmpeg       = '',
  cap          = 64,
  slice_mode   = 'off',
  slice_fixed  = 4,
  slice_thresh = 0.5,
}

local function load_settings()
  local s = r.GetExtState(SET_KEY, 'settings') or ''
  local set = {}
  for k in pairs(DEFAULTS) do set[k] = DEFAULTS[k] end
  for k, v in s:gmatch('(%w+)=([^;\n]*)') do
    if k == 'cap' or k == 'slice_fixed' then
      set[k] = tonumber(v) or DEFAULTS[k]
    elseif k == 'slice_thresh' then
      set[k] = tonumber(v) or DEFAULTS[k]
    elseif k == 'slice_mode' or k == 'ffmpeg' then
      set[k] = v
    end
  end
  return set
end

local function save_settings(set)
  local t = {}
  for k, v in pairs(set) do t[#t+1] = k .. '=' .. tostring(v) end
  r.SetExtState(SET_KEY, 'settings', table.concat(t, ';'), true)
end

local UI_DEFAULTS = { visible = '1', win_w = 440, win_h = 800, drop_mode = 'cursor' }
local function load_ui()
  local set = {}
  for k, v in pairs(UI_DEFAULTS) do set[k] = v end
  local s = r.GetExtState(UI_KEY, 'ui') or ''
  for k, v in s:gmatch('(%w+)=([^;\n]*)') do
    if k == 'win_w' or k == 'win_h' then
      set[k] = tonumber(v) or UI_DEFAULTS[k]
    else
      set[k] = v
    end
  end
  return set
end
local function save_ui(set)
  local t = {}
  for k, v in pairs(set) do t[#t+1] = k .. '=' .. tostring(v) end
  r.SetExtState(UI_KEY, 'ui', table.concat(t, ';'), true)
end

-- ==================== ffmpeg 探测 ====================

local function ffmpeg_candidates(manual)
  local cand = {}
  if manual and manual ~= '' then
    local m = manual:gsub('^%s+', ''):gsub('%s+$', '')
    if m:lower():match('%.exe$') then
      cand[#cand+1] = m
    else
      cand[#cand+1] = m:gsub('[\\/]$', '') .. '\\ffmpeg.exe'
      cand[#cand+1] = m
    end
  end
  cand[#cand+1] = 'ffmpeg'
  cand[#cand+1] = 'ffmpeg.exe'
  local lap = os.getenv('LOCALAPPDATA')
  if lap then cand[#cand+1] = lap .. '\\Microsoft\\WinGet\\Links\\ffmpeg.exe' end
  cand[#cand+1] = 'C:\\ffmpeg\\bin\\ffmpeg.exe'
  cand[#cand+1] = 'C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe'
  return cand
end

local function run_ffmpeg_version(c)
  if not c or c == '' then return false, '(空路径)' end
  local ok, out = pcall(r.ExecProcess, '"' .. c .. '" -version', 4000)
  if not ok then return false, 'ExecProcess 调用出错' end
  out = out or ''
  return (out:gsub('^%s+', ''):match('^0') ~= nil), out
end

-- ==================== ReaImGui + Fluent ====================



if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Settings', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'
if type(ImGui) ~= 'table' then ImGui = r.ImGui end
if type(ImGui) ~= 'table' then
  r.MB('需要 ReaImGui 扩展', 'bst Settings', 0)
  return
end

local RES = r.GetResourcePath()
-- 库定位: 优先本目录, 其次 Scripts/bst/, 兼容旧位置 Scripts/OxTools/
local OX_FLUENT
do
  local selfdir = ((debug.getinfo(1, 'S').source or ''):match('^@(.*)[/\\]')) or ''
  local cands = {
    selfdir .. '/bst_fluent.lua',
    RES .. '/Scripts/bst/bst_fluent.lua',
    RES .. '/Scripts/OxTools/bst_fluent.lua',
    RES .. '/Scripts/OxTools/ox_fluent.lua',
  }
  for _, cand in ipairs(cands) do
    local fh = io.open(cand, 'r')
    if fh then fh:close() OX_FLUENT = cand break end
  end
end
if not OX_FLUENT then
  r.MB('找不到 Fluent 库 (bst_fluent.lua):\n请确认 Scripts/bst/ 目录存在。', 'bst Settings', 0)
  return
end
local fl = dofile(OX_FLUENT)(ImGui)
fl.set_theme('dark')
local T = fl.dark

local ctx
if ImGui.CreateContext then
  local ok, c = pcall(ImGui.CreateContext, 'bst Settings')
  if ok then ctx = c end
end
if not ctx then
  r.MB('ReaImGui context 创建失败', 'bst Settings', 0)
  return
end

-- CJK 正文字体 + Fluent 图标字体
local FONT = nil
for _, fp in ipairs({ 'C:/Windows/Fonts/simhei.ttf', 'C:/Windows/Fonts/Deng.ttf',
                      'C:/Windows/Fonts/msyh.ttc', 'C:/Windows/Fonts/simsun.ttc' }) do
  local ok, fo = pcall(ImGui.CreateFontFromFile, fp)
  if ok and fo and ImGui.ValidatePtr(fo, 'ImGui_Font*') then
    if pcall(ImGui.Attach, ctx, fo) then FONT = fo break end
  end
end
fl.attach_fonts(ctx)
fl.set_ui_font(FONT)

-- ==================== 状态 ====================

local set = load_settings()
local ui  = load_ui()

-- ffmpeg 测试结果缓存 (供界面显示)
local ff_state = nil   -- { ok=bool, path=string, output=string }

local function test_ffmpeg()
  for _, c in ipairs(ffmpeg_candidates(set.ffmpeg)) do
    local ok, out = run_ffmpeg_version(c)
    if ok then
      ff_state = { ok = true, path = c, output = out }
      return
    end
  end
  -- 全失败: 记录第一个候选的原始输出便于诊断
  local first = ffmpeg_candidates(set.ffmpeg)[1]
  local _, out = run_ffmpeg_version(first)
  ff_state = { ok = false, path = first, output = out }
end

test_ffmpeg()

local quit = false
local err_shown = false
local show_ffout = false

-- utf8 安全的按像素宽度截断 (同主面板实现)
local function fit_text(text, maxw)
  text = tostring(text or '')
  maxw = maxw or math.huge
  if maxw <= 0 then return text end
  if ImGui.CalcTextSize(ctx, text) <= maxw then return text end
  local n, lo, hi, best = #text, 1, #text, 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if ImGui.CalcTextSize(ctx, text:sub(1, mid) .. '…') <= maxw then
      best = mid lo = mid + 1
    else
      hi = mid - 1
    end
  end
  while best > 1 do
    local b = text:byte(best)
    if not (b >= 0x80 and b < 0xC0) then break end
    best = best - 1
  end
  return text:sub(1, best) .. '…'
end

-- ==================== 分区卡片 ====================

local function begin_section(title)
  fl.begin_card(ctx, '##sec_' .. title)
  fl.body_large(ctx, title)
end

local function end_section()
  fl.end_card(ctx)
end

-- ==================== 主循环 ====================

local function frame()
  local font_pushed = false
  if FONT and ImGui.ValidatePtr(FONT, 'ImGui_Font*') then
    font_pushed = pcall(ImGui.PushFont, ctx, FONT, 15)
  end
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 500, 560, ImGui.Cond_FirstUseEver or 0)

  local visible, open = ImGui.Begin(ctx, 'Clipboard Manager 设置###bstCBMSettings', true)
  if open == false then quit = true end

  if visible then
    local ok_body, err_body = pcall(function()
      fl.subtitle(ctx, '剪贴板管理器')
      fl.caption(ctx, '与主面板实时共享设置, 改动立即生效。')

      ---------- 捕获 ----------
      begin_section('捕获')
      ImGui.SetNextItemWidth(ctx, 150)
      do
        local c1, v1 = ImGui.InputInt(ctx, '历史上限##cap', set.cap or 64)
        if c1 then set.cap = math.max(v1 or 64, 4) save_settings(set) end
      end
      fl.caption(ctx, '超出上限后自动淘汰最旧条目')
      end_section()

      ---------- 默认切片 ----------
      begin_section('默认切片')
      do
        local labels = { '关闭', '固定时长', '瞬态检测', '节拍网格' }
        local keys   = { 'off', 'fixed', 'transients', 'beats' }
        local cur = 1
        for i, k in ipairs(keys) do if k == set.slice_mode then cur = i end end
        if ImGui.BeginCombo(ctx, '模式##slicemode', labels[cur]) then
          for i, lab in ipairs(labels) do
            if ImGui.Selectable(ctx, lab, set.slice_mode == keys[i]) then
              set.slice_mode = keys[i]
              save_settings(set)
            end
            if set.slice_mode == keys[i] then ImGui.SetItemDefaultFocus(ctx) end
          end
          ImGui.EndCombo(ctx)
        end
        if set.slice_mode == 'fixed' then
          ImGui.SetNextItemWidth(ctx, 200)
          local c2, v2 = ImGui.InputDouble(ctx, '固定切片秒数##sf', set.slice_fixed or 4, 0.5, 1, '%.2f')
          if c2 then
            set.slice_fixed = math.max(v2 or 4, 0.05)
            save_settings(set)
          end
        elseif set.slice_mode == 'transients' then
          local c3, v3 = ImGui.SliderDouble(ctx, '瞬态阈值##st', set.slice_thresh or 0.5, 0.05, 0.95, '%.2f')
          if c3 then set.slice_thresh = v3 save_settings(set) end
        end
        fl.caption(ctx, '卡片上可对单条目临时切换; 此处为默认值')
      end
      end_section()

      ---------- ffmpeg ----------
      begin_section('ffmpeg 缩略图')
      do
        ImGui.SetNextItemWidth(ctx, -1)
        local cf_, vf_ = ImGui.InputTextWithHint(ctx, '##ffpath',
          '留空自动探测; 可填 exe 完整路径或目录', set.ffmpeg or '')
        if cf_ then set.ffmpeg = vf_ or '' save_settings(set) test_ffmpeg() end
        if ff_state and ff_state.ok then
          fl.infobar(ctx, 'ok', '已找到: ' .. fit_text(ff_state.path, 400))
        else
          fl.infobar(ctx, 'bad', '未找到 ffmpeg — 视频/GIF/图片缩略图不可用')
        end
        if fl.button(ctx, '重新测试', { subtle = true }) then test_ffmpeg() end
        ImGui.SameLine(ctx)
        if fl.button(ctx, '用 winget 默认路径', { subtle = true }) then
          local lap = os.getenv('LOCALAPPDATA')
          if lap then
            set.ffmpeg = lap .. '\\Microsoft\\WinGet\\Links\\ffmpeg.exe'
            save_settings(set)
            test_ffmpeg()
          end
        end
        ImGui.SameLine(ctx)
        show_ffout = fl.toggle(ctx, '', show_ffout)
        fl.caption(ctx, show_ffout and '隐藏探测输出' or '查看探测输出')

        if show_ffout and ff_state and ff_state.output and ff_state.output ~= '' then
          local lines = ff_state.output:gsub('\r\n', '\n'):gsub('\r', '\n')
          if ImGui.BeginChild(ctx, '##ffout', 0, 110) then
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, T.text_tri)
            for l in lines:gmatch('[^\n]*\n?') do
              if l:gsub('%s', '') ~= '' then
                ImGui.Text(ctx, l:gsub('\n$', ''))
              end
            end
            ImGui.PopStyleColor(ctx)
            ImGui.EndChild(ctx)
          end
        end
      end
      end_section()

      ---------- 操作习惯 ----------
      begin_section('操作习惯')
      do
        local dl_labels = { '编辑光标处', '鼠标位置' }
        local dkeys     = { 'cursor', 'mouse' }
        local dcur = (ui.drop_mode == 'mouse') and 2 or 1
        if ImGui.BeginCombo(ctx, '拖出落点##drop', dl_labels[dcur]) then
          for i, dd in ipairs(dl_labels) do
            if ImGui.Selectable(ctx, dd, ui.drop_mode == dkeys[i]) then
              ui.drop_mode = dkeys[i]
              save_ui(ui)
            end
            if ui.drop_mode == dkeys[i] then ImGui.SetItemDefaultFocus(ctx) end
          end
          ImGui.EndCombo(ctx)
        end
        fl.caption(ctx, '按住卡片「拖到编曲区」松开时的插入位置')

        ImGui.SetNextItemWidth(ctx, 150)
        do
          local cw_, w_ = ImGui.InputInt(ctx, '主窗口宽##ww', ui.win_w or 440)
          if cw_ then ui.win_w = math.max(w_ or 440, 300) save_ui(ui) end
          ImGui.SameLine(ctx)
          local ch_, h_ = ImGui.InputInt(ctx, '高##wh', ui.win_h or 800)
          if ch_ then ui.win_h = math.max(h_ or 800, 400) save_ui(ui) end
        end
        fl.caption(ctx, '尺寸下次打开主面板时生效')

        do
          local cur_vis = (r.GetExtState(SET_KEY, 'visible') or '1') == '1'
          local cv, nv_ = ImGui.Checkbox(ctx, '显示主面板##vis', cur_vis)
          if cv then
            r.SetExtState(SET_KEY, 'visible', nv_ and '1' or '0', false)
          end
        end
      end
      end_section()

      ---------- 使用说明 ----------
      begin_section('使用说明')
      do
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, T.text_sec)
        for _, line in ipairs({
          '· 捕获: 选中对象后点主面板「捕获」, 或绑定 bst Capture 系列到快捷键',
          '· 复制: Ctrl+C 已绑定 bst Copy (Smart), 复制 item/轨道同时入板',
          '· 拖出: 按住卡片「拖到编曲区」松开即插入; Shift = 强制瞬态切片',
          '· 预览: 波形上滚轮缩放、拖拽选选区; 视频底部时间线拖动看帧',
        }) do
          ImGui.Text(ctx, line)
        end
        ImGui.PopStyleColor(ctx)
      end
      end_section()
    end)  -- pcall body 结束

    ImGui.End(ctx)  -- 始终与 Begin 配对

    if not ok_body then
      if not err_shown then
        err_shown = true
        log('[bst Settings ERROR] ' .. tostring(err_body) .. '\n')
      end
    end
  end

  fl.pop_theme(ctx, nc, nv)
  if font_pushed then pcall(ImGui.PopFont, ctx) end
end

local function loop()
  if quit then return end
  local ok, err = pcall(frame)
  if not ok then
    if not err_shown then
      err_shown = true
      log('[bst Settings ERROR] ' .. tostring(err) .. '\n')
    end
  end
  r.defer(loop)
end

r.defer(loop)
