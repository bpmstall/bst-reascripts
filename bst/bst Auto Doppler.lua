-- bst: Auto Doppler (nvk_AUTODOPPLER-style, Fluent panel + bst_Doppler.jsfx)
-- Analyzes the items on the selected track, finds each item's RMS-peak time,
-- marks item snap offsets at the peaks, then writes path-position automation
-- for the bundled "JS: bst Doppler" effect (or any custom FX parameter) so the
-- sound crosses the listener at the MEAN peak time.
-- Time selection limits which items are analyzed and doubles as the path
-- duration. Keys: ad_* in ExtState "OxTools". Requires Effects/bst/bst_Doppler.jsfx.

local r = reaper




if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Auto Doppler', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)
if BST_AD_LIVE and ImGui.ValidatePtr(BST_AD_LIVE, 'ImGui_Context*') then
  return -- panel already open
end
local ctx = ImGui.CreateContext('bst Auto Doppler')
BST_AD_LIVE = ctx

local MODES = { "bst Doppler (bundled JSFX)", "Custom FX param" }
local PEAKS = { "RMS peak", "Item center (no analysis)" }
local DIRS  = { "Left → Right", "Right → Left" }

local st = {
  mode_i    = math.floor(lib.ext_getnum("ad_mode", 1)),
  peak_i    = math.floor(lib.ext_getnum("ad_peak", 1)),
  dir_i     = math.floor(lib.ext_getnum("ad_dir", 1)),
  param     = lib.ext_get("ad_param", "路径位置"),
  snap      = math.floor(lib.ext_getnum("ad_snap", 1)),
}

local msg, sev = "选中轨道（可框选时选限制范围），然后「写入自动化」。", nil
local err = nil

local function set_num(key, v) st[key] = v; lib.ext_set(key, v) end

--------------------------------------------------------------------------------
-- helpers

local function ts_range()
  local a, b = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  a, b = a or 0, b or 0
  if b - a > 1e-6 then return a, b end
end

local function find_fx(tr, names)
  local n = r.TrackFX_GetCount(tr)
  for i = 0, n - 1 do
    local _, nm = r.TrackFX_GetFXName(tr, i, '')
    nm = nm or ''
    for _, want in ipairs(names) do
      if nm:lower():find(want:lower(), 1, true) then return i end
    end
  end
  return nil
end

local JSFX_NAMES = { "bst doppler" }

local function ensure_fx(tr)
  local fx = find_fx(tr, JSFX_NAMES)
  if fx then return fx end
  for _, cand in ipairs({ "JS:bst Doppler", "JS: bst Doppler", "bst Doppler" }) do
    local pos = r.TrackFX_AddByName(tr, cand, false, -1)
    if pos and pos >= 0 then return pos end
  end
  return nil
end

local function find_param(tr, fx, want)
  local _, pn = r.TrackFX_GetParamName(tr, fx, 0, '')
  local n = r.TrackFX_GetNumParams(tr, fx)
  for i = 0, n - 1 do
    local _, nm = r.TrackFX_GetParamName(tr, fx, i, '')
    if nm and nm:lower():find(want:lower(), 1, true) then return i, nm end
  end
  return nil
end

-- items on track, optionally clipped to time selection, muted skipped
local function analyze_items(tr)
  local a, b = ts_range()
  local peaks, used = {}, {}
  for i = 0, r.CountTrackMediaItems(tr) - 1 do
    local it = r.GetTrackMediaItem(tr, i)
    if r.GetMediaItemInfo_Value(it, "B_MUTE") == 0 then
      local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
      local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
      local take_it = a and not (pos + len > a and pos < b)
      if not take_it then
        local t = lib.item_rms_peak_time(it, st.peak_i == 2 and "none" or "rms")
        if t then
          peaks[#peaks + 1] = t
          used[#used + 1] = { item = it, t = t }
        end
      end
    end
  end
  return peaks, used
end

local function param_env(tr, fx, pidx, create)
  return r.GetFXEnvelope(tr, fx, pidx, create and true or false)
end

local function clear_env(env)
  if not env then return end
  r.DeleteEnvelopePointRange(env, -1e12, 1e12)
  r.Envelope_SortPoints(env)
end

--------------------------------------------------------------------------------
-- actions

local function act_write()
  local tr = r.GetSelectedTrack(0, 0)
  if not tr then msg, sev = "请先选中一条轨道。", "warn"; return end

  local fx, pidx
  if st.mode_i == 1 then
    fx = ensure_fx(tr)
    if not fx then
      msg, sev = "找不到 JSFX「bst Doppler」——请确认 Effects/bst/bst_Doppler.jsfx 已安装（必要时重启 REAPER 扫描）。", "bad"
      return
    end
    pidx = 0
  else
    fx = r.TrackFX_GetCount(tr) - 1
    if fx < 0 then msg, sev = "轨道上没有 FX。", "warn"; return end
    pidx = find_param(tr, fx, st.param)
    if not pidx then msg, sev = "FX 上找不到参数「" .. st.param .. "」。", "warn"; return end
  end

  local peaks, used = analyze_items(tr)
  if #peaks == 0 then
    msg, sev = "轨道上没有可分析的 item（注意静音 item 会被跳过）。", "warn"
    return
  end

  -- 均值经过时刻（含简单去离群: 偏离中位数 2 倍以上的点不计）
  table.sort(peaks)
  local med = peaks[math.ceil(#peaks / 2)]
  local sum, cnt = 0, 0
  for _, t in ipairs(peaks) do
    if math.abs(t - med) <= (peaks[#peaks] - peaks[1]) * 0.75 + 0.25 then
      sum, cnt = sum + t, cnt + 1
    end
  end
  local cross = cnt > 0 and sum / cnt or med

  -- 路径时长: 时选长度, 否则 item 跨度
  local a, b = ts_range()
  local D = a and (b - a) or (peaks[#peaks] - peaks[1])
  D = math.max(D, 0.5)
  local t0, t1 = cross - D / 2, cross + D / 2

  local env = param_env(tr, fx, pidx, true)
  if not env then msg, sev = "无法创建 FX 参数包络。", "bad"; return end
  clear_env(env)

  local _, _, vmin, vmax = r.TrackFX_GetParam(tr, fx, pidx)
  vmin, vmax = vmin or 0, vmax or 1
  local v0, v1 = vmin, vmax
  if st.dir_i == 2 then v0, v1 = vmax, vmin end
  r.InsertEnvelopePoint(env, t0, v0, 0, 0, false, true)
  r.InsertEnvelopePoint(env, t1, v1, 0, 0, false, true)
  r.Envelope_SortPoints(env)

  local nmark = 0
  if st.snap >= 1 then
    for _, u in ipairs(used) do
      local it = u.item
      local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
      r.SetMediaItemInfo_Value(it, "D_SNAPOFFSET", u.t - pos)
      nmark = nmark + 1
    end
  end

  local _, fxname = r.TrackFX_GetFXName(tr, fx, '')
  msg, sev = string.format("已写入包络：经过听者时刻 %.2fs（%d 个 item 峰值），范围 %.2fs–%.2fs，FX=%s%s",
    cross, #peaks, t0, t1, tostring(fxname),
    nmark > 0 and string.format("，%d 个 item 已设峰值吸附偏移", nmark) or ""),
    "ok"
end

local function act_clear()
  local tr = r.GetSelectedTrack(0, 0)
  if not tr then msg, sev = "请先选中一条轨道。", "warn"; return end
  local fx, pidx
  if st.mode_i == 1 then
    fx = find_fx(tr, JSFX_NAMES)
    if not fx then msg, sev = "轨道上没有 bst Doppler。", "warn"; return end
    pidx = 0
  else
    fx = r.TrackFX_GetCount(tr) - 1
    if fx < 0 then msg, sev = "轨道上没有 FX。", "warn"; return end
    pidx = find_param(tr, fx, st.param)
    if not pidx then msg, sev = "FX 上找不到参数「" .. st.param .. "」。", "warn"; return end
  end
  local env = param_env(tr, fx, pidx, false)
  if env then clear_env(env) end
  msg, sev = "已清除该参数包络。", "ok"
end

local function act_addfx()
  local tr = r.GetSelectedTrack(0, 0)
  if not tr then msg, sev = "请先选中一条轨道。", "warn"; return end
  local fx = ensure_fx(tr)
  if fx then
    msg, sev = "bst Doppler 已就绪。", "ok"
  else
    msg, sev = "添加失败——请确认 Effects/bst/bst_Doppler.jsfx 已安装（必要时重启 REAPER 扫描）。", "bad"
  end
end

--------------------------------------------------------------------------------
-- UI

local function toggle_key(label, key)
  local nv = fl.toggle(ctx, label, st[key] >= 1)
  if (nv and 1 or 0) ~= st[key] then set_num(key, nv and 1 or 0) end
end

local function draw_body()
  fl.subtitle(ctx, "Auto Doppler")
  ImGui.Spacing(ctx)

  fl.begin_card(ctx, "##card_ad")
    fl.caption(ctx, "目标 FX")
    local ch, v = ImGui.Combo(ctx, "Mode##adm", st.mode_i - 1,
      table.concat(MODES, "\0") .. "\0")
    if ch then set_num("mode_i", math.floor(v) + 1) end
    if st.mode_i == 2 then
      ch, v = ImGui.InputTextWithHint(ctx, "##adparam", "FX parameter name (e.g. Path Pos)", st.param)
      if ch and v ~= nil then st.param = v; lib.ext_set("ad_param", v) end
      fl.caption(ctx, "对最后一个 FX 的指定参数写 0→100% 包络")
    else
      if fl.button(ctx, "Add bst Doppler FX", { width = 180 }) then act_addfx() end
      fl.caption(ctx, "对「路径位置」参数写包络；JSFX 内部完成声像/距离/音高联动")
    end
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 2)
  fl.begin_card(ctx, "##card_an")
    fl.caption(ctx, "分析")
    ch, v = ImGui.Combo(ctx, "Peak detection##adp", st.peak_i - 1,
      table.concat(PEAKS, "\0") .. "\0")
    if ch then set_num("peak_i", math.floor(v) + 1) end
    ch, v = ImGui.Combo(ctx, "Direction##add", st.dir_i - 1,
      table.concat(DIRS, "\0") .. "\0")
    if ch then set_num("dir_i", math.floor(v) + 1) end
    toggle_key("Set item snap offsets to peaks (alignment aid)", "snap")
    fl.caption(ctx, "静音 item 跳过；时选限制分析范围并决定路径时长")
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 6)
  if fl.button(ctx, "Write automation", { accent = true, width = 200, height = 32 }) then
    act_write()
  end
  ImGui.SameLine(ctx)
  if fl.button(ctx, "Clear envelope", { width = 100, height = 32 }) then act_clear() end

  if err then
    fl.infobar(ctx, "bad", "错误：" .. tostring(err))
  else
    fl.infobar(ctx, sev, msg)
  end
end

fl.attach_fonts(ctx)

local function loop()
  if not ctx or not ImGui.ValidatePtr(ctx, 'ImGui_Context*') then
    return
  end
  local okf, open = pcall(function()
    ImGui.SetNextWindowSize(ctx, 480, 560, ImGui.Cond_FirstUseEver)
    local nc, nv = fl.push_theme(ctx)
    local visible, op = ImGui.Begin(ctx, 'bst Auto Doppler', true)
    if visible then
      local ok, e = pcall(draw_body)
      if ok then err = nil else err = tostring(e) end
      if not ok then
        r.ShowConsoleMsg("bst Auto Doppler: " .. tostring(e) .. "\n")
        for _ = 1, 8 do if not pcall(ImGui.EndChild, ctx) then break end end
      end
      ImGui.End(ctx)
    end
    fl.pop_theme(ctx, nc, nv)
    return op
  end)
  if not okf or not open then
    if not okf then
      r.ShowConsoleMsg("bst Auto Doppler: frame aborted, closing (" .. tostring(open) .. ")\n")
    end
    if BST_AD_LIVE == ctx then BST_AD_LIVE = nil end
    return
  end
  r.defer(loop)
end

r.defer(loop)
