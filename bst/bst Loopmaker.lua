-- bst: Loopmaker (nvk_LOOPMAKER-style seamless loop generator, Fluent panel)
-- For each selected item builds N seamless loops:
--   content window -> zero-cross snapped -> tail/head crossfade construction
--   rendered to a WAV on a temp track -> reimported with B_LOOPSRC on.
-- Time selection (clamped to the item) defines the loop length; the whole
-- item is used otherwise. "Shuffle" picks a random content window per loop so
-- each variation's crossfade content differs. Rendered WAVs land in
-- <project media dir>/bst_loops/. Keys: lm_* in ExtState "OxTools".

local r = reaper




if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Loopmaker', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)
if BST_LM_LIVE and ImGui.ValidatePtr(BST_LM_LIVE, 'ImGui_Context*') then
  return -- panel already open
end
local ctx = ImGui.CreateContext('bst Loopmaker')
BST_LM_LIVE = ctx

local st = {
  count    = math.floor(lib.ext_getnum("lm_count", 3)),
  gap_s    = lib.ext_getnum("lm_gap_s", 0.5),
  xf_ms    = lib.ext_getnum("lm_xf_ms", 120),
  shape    = math.floor(lib.ext_getnum("lm_shape", 1)),
  zc_ms    = lib.ext_getnum("lm_zc_ms", 5),
  shuffle  = math.floor(lib.ext_getnum("lm_shuffle", 1)),
  snapsec  = math.floor(lib.ext_getnum("lm_snapsec", 0)),
  prefix   = lib.ext_get("lm_prefix", ""),
  suffix   = lib.ext_get("lm_suffix", "_loop"),
  start_n  = math.floor(lib.ext_getnum("lm_start", 1)),
  color    = math.floor(lib.ext_getnum("lm_color", 1)),
}
local FORMAT = "ZXZhdxgB" -- WAV 24-bit
local LOOP_COLOR = r.ColorToNative(76, 194, 255) | 0x1000000

local msg, sev = "选中音频 item，框选时选可指定循环长度。", nil
local err = nil
math.randomseed(os.time())

local function set_num(key, v) st[key] = v; lib.ext_set(key, v) end

--------------------------------------------------------------------------------
-- helpers

local function ts_range()
  local a, b = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  a, b = a or 0, b or 0
  if b - a > 1e-6 then return a, b end
end

local function base_content(item)
  local P0 = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local L0 = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local a, b = ts_range()
  if a and b then
    a, b = math.max(a, P0), math.min(b, P0 + L0)
    if b - a > 1e-6 then return a, b end
  end
  return P0, P0 + L0
end

-- content window of length L inside the item; random when shuffle
local function pick_window(item, L)
  local P0 = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local L0 = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local lo = P0
  local hi = P0 + L0 - L
  if hi <= lo then return lo, lo + L0 end
  if st.shuffle >= 1 then
    local w1 = lo + math.random() * (hi - lo)
    return w1, w1 + L
  end
  return lo, lo + L
end

local function snap_zero(item, t_project, is_end)
  local P0 = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local t_item = t_project - P0
  local win = st.zc_ms / 1000
  local zt = lib.find_zero_cross(item, t_item, win)
  if zt then return P0 + zt end
  return t_project
end

local function whole_second(t, is_end)
  if st.snapsec < 1 then return t end
  return is_end and math.ceil(t) or math.floor(t)
end

local function ensure_tmp_track()
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local _, nm = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if nm == "bst LM temp" then return tr end
  end
  local n = r.CountTracks(0)
  r.InsertTrackAtIndex(n, false)
  local tr = r.GetTrack(0, n)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", "bst LM temp", true)
  return tr
end

-- build the crossfade construction for one loop on tmp track; returns items
local function build_construction(item, tmp, w1, w2, xf, P)
  local itA = lib.window_item(item, tmp, P, w2 - xf, w2)   -- 尾段: 淡出层
  if not itA then return nil, tostring(itA) end
  local itB = lib.window_item(item, tmp, P, w1, w2 - xf)   -- 头段+主体: 淡入层
  if not itB then return nil, tostring(itB) end
  r.SetMediaItemInfo_Value(itA, "D_FADEOUTLEN", xf)
  r.SetMediaItemInfo_Value(itA, "C_FADEOUTSHAPE", st.shape)
  r.SetMediaItemInfo_Value(itB, "D_FADEINLEN", xf)
  r.SetMediaItemInfo_Value(itB, "C_FADEINSHAPE", st.shape)
  return { itA, itB }
end

local function out_dir()
  local base = r.GetProjectPath("")
  if base == "" then base = r.GetResourcePath() end
  return base:gsub("[%/\\]+$", "") .. "/bst_loops/"
end

local preview_item = nil
local preview_solo_saved = nil

--------------------------------------------------------------------------------
-- actions

local function act_generate()
  local items = lib.selected_items()
  if #items == 0 then msg, sev = "没有选中的 item。", "warn"; return end
  local xf = math.max(st.xf_ms / 1000, 0.001)
  local made, skipped = 0, {}
  local first_loop = nil
  local odir = out_dir()
  r.RecursiveCreateDirectory(odir, 0)

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local tmp = ensure_tmp_track()

  for _, item in ipairs(items) do
    local take = r.GetActiveTake(item)
    if not take or r.TakeIsMIDI(take) then
      skipped[#skipped + 1] = "MIDI/空 item"
    else
      local c1, c2 = base_content(item)
      local L = c2 - c1
      local xf_use = math.min(xf, L * 0.45)
      local T = L - xf_use
      if T < 0.02 then
        skipped[#skipped + 1] = "内容太短"
      else
        local P0 = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local L0 = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local src_end = P0 + L0
        local base_name = lib.take_name(take)
        if base_name == "" then base_name = "loop" end
        local track = lib.item_track(item)

        for k = 1, math.max(1, st.count) do
          local w1, w2 = pick_window(item, L)
          w1 = whole_second(w1, false)
          w2 = whole_second(w2, true)
          if w2 - w1 < T * 0.5 then w2 = w1 + L end
          w1 = snap_zero(item, w1, false)
          w2 = snap_zero(item, w2, true)
          if w2 - w1 > 0.05 then
            local xf_k = math.min(xf_use, (w2 - w1) * 0.45)
            local parts = build_construction(item, tmp, w1, w2, xf_k, P0)
            if parts then
              local num = st.start_n + k - 1
              local fname = lib.sanitize(st.prefix .. base_name .. st.suffix)
                .. string.format("_%02d", num)
              lib.render_block_mixdown(parts, odir, {
                pattern = fname, format = FORMAT, srate = 0, mono = false,
                tail_ms = 0,
              })
              local wav = odir .. fname .. ".wav"
              local src = r.PCM_Source_CreateFromFile(wav)
              if src then
                local new_item = r.AddMediaItemToTrack(track)
                local new_take = r.AddTakeToMediaItem(new_item)
                r.SetMediaItemTake_Source(new_take, src)
                local vpos = src_end + st.gap_s + (k - 1) * (T + st.gap_s)
                r.SetMediaItemInfo_Value(new_item, "D_POSITION", vpos)
                r.SetMediaItemInfo_Value(new_item, "D_LENGTH", T)
                r.SetMediaItemInfo_Value(new_item, "B_LOOPSRC", 1)
                if st.color >= 1 then
                  r.SetMediaItemInfo_Value(new_item, "I_CUSTOMCOLOR", LOOP_COLOR)
                end
                lib.set_take_name(new_take,
                  lib.sanitize(st.prefix .. base_name .. st.suffix)
                  .. string.format("_%02d", num))
                if k == 1 and not first_loop then first_loop = new_item end
                made = made + 1
              else
                skipped[#skipped + 1] = "渲染文件缺失: " .. wav
              end
              for _, p in ipairs(parts) do
                r.DeleteTrackMediaItem(tmp, p)
              end
            else
              skipped[#skipped + 1] = "内容窗口构建失败"
            end
          else
            skipped[#skipped + 1] = "零交叉窗口失败"
          end
        end
      end
    end
  end

  r.DeleteTrack(tmp)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Generate %d loop(s)", made), -1)
  if first_loop then preview_item = first_loop end
  msg, sev = string.format("已生成 %d 个循环 → %s", made, odir)
    .. (#skipped > 0 and string.format("（跳过 %d）", #skipped) or ""),
    made > 0 and "ok" or "warn"
end

local function act_preview()
  -- 找第一个 B_LOOPSRC 且名字带后缀的 item 作为试听对象
  if not (preview_item and r.ValidatePtr(preview_item, "MediaItem*")) then
    local items = lib.selected_items()
    preview_item = items[1]
  end
  if not (preview_item and r.ValidatePtr(preview_item, "MediaItem*")) then
    msg, sev = "没有可试听的循环（先生成或选中一个循环 item）。", "warn"
    return
  end
  if preview_solo_saved then
    r.Main_OnCommand(40667, 0) -- stop
    for tr, solo in pairs(preview_solo_saved) do
      r.SetMediaTrackInfo_Value(tr, "I_SOLO", solo)
    end
    preview_solo_saved = nil
    msg, sev = "试听停止。", nil
    return
  end
  local tr = lib.item_track(preview_item)
  preview_solo_saved = {}
  for i = 0, r.CountTracks(0) - 1 do
    local t2 = r.GetTrack(0, i)
    preview_solo_saved[t2] = r.GetMediaTrackInfo_Value(t2, "I_SOLO")
    r.SetMediaTrackInfo_Value(t2, "I_SOLO", (t2 == tr) and 1 or 0)
  end
  r.Main_OnCommand(40289, 0) -- unselect all items
  r.SetMediaItemSelected(preview_item, true)
  r.SetEditCurPos(r.GetMediaItemInfo_Value(preview_item, "D_POSITION"), false, false)
  r.Main_OnCommand(1007, 0) -- play
  msg, sev = "试听中（再按一次/空格停止）…", nil
end

local function stop_preview_if_playing()
  if preview_solo_saved and (r.GetPlayState() & 1) == 0 then
    for tr, solo in pairs(preview_solo_saved) do
      r.SetMediaTrackInfo_Value(tr, "I_SOLO", solo)
    end
    preview_solo_saved = nil
  end
end

--------------------------------------------------------------------------------
-- UI

local function input_d(label, key, mn, fmt)
  local ch, v = ImGui.InputDouble(ctx, label, st[key], 0, 0, fmt or '%.2f')
  if ch then set_num(key, math.max(mn or 0, v)) end
end

local function input_text(label, key)
  local ch, v = ImGui.InputText(ctx, label, st[key] or "")
  if ch and v ~= nil then st[key] = v; lib.ext_set(key, v) end
end

local function toggle_key(label, key)
  local nv = fl.toggle(ctx, label, st[key] >= 1)
  if (nv and 1 or 0) ~= st[key] then set_num(key, nv and 1 or 0) end
end

local function draw_body()
  fl.subtitle(ctx, "Loopmaker")
  ImGui.Spacing(ctx)

  fl.begin_card(ctx, "##card_lm")
    fl.caption(ctx, "循环")
    local ch, v = ImGui.InputInt(ctx, "Loops per item", st.count)
    if ch then set_num("count", math.max(1, math.floor(v))) end
    input_d("Gap (s)", "gap_s", 0)
    input_d("Crossfade (ms)", "xf_ms", 1, '%.0f')
    ch, v = ImGui.SliderInt(ctx, "Fade shape (0=linear..6)", st.shape, 0, 6, '%d')
    if ch then set_num("shape", math.floor(v)) end
    input_d("Zero-cross search (ms)", "lm_zc_ms", 0.5, '%.1f')
    toggle_key("Snap loop start to whole seconds", "snapsec")
    toggle_key("Shuffle variation positions", "shuffle")
    fl.caption(ctx, "时选与 item 重叠部分 = 循环长度；无时选用整个 item")
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 2)
  fl.begin_card(ctx, "##card_name")
    fl.caption(ctx, "命名")
    input_text("Prefix", "prefix")
    input_text("Suffix", "suffix")
    ch, v = ImGui.InputInt(ctx, "Start #", st.start_n)
    if ch then set_num("start_n", math.max(0, math.floor(v))) end
    toggle_key("Color loop items", "color")
    fl.caption(ctx, "循环 WAV 输出到 <工程媒体目录>/bst_loops/，item 自动开启循环源")
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 6)
  if fl.button(ctx, "Generate loops", { accent = true, width = 200, height = 32 }) then
    act_generate()
  end
  ImGui.SameLine(ctx)
  if fl.button(ctx, preview_solo_saved and "Stop" or "Preview", { width = 100, height = 32 }) then
    act_preview()
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Space) then act_preview() end

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
  stop_preview_if_playing()
  local okf, open = pcall(function()
    ImGui.SetNextWindowSize(ctx, 470, 620, ImGui.Cond_FirstUseEver)
    local nc, nv = fl.push_theme(ctx)
    local visible, op = ImGui.Begin(ctx, 'bst Loopmaker', true)
    if visible then
      local ok, e = pcall(draw_body)
      if ok then err = nil else err = tostring(e) end
      if not ok then
        r.ShowConsoleMsg("bst Loopmaker: " .. tostring(e) .. "\n")
        for _ = 1, 8 do if not pcall(ImGui.EndChild, ctx) then break end end
      end
      ImGui.End(ctx)
    end
    fl.pop_theme(ctx, nc, nv)
    return op
  end)
  if not okf or not open then
    if preview_solo_saved then
      for tr, solo in pairs(preview_solo_saved) do
        r.SetMediaTrackInfo_Value(tr, "I_SOLO", solo)
      end
    end
    if not okf then
      r.ShowConsoleMsg("bst Loopmaker: frame aborted, closing (" .. tostring(open) .. ")\n")
    end
    if BST_LM_LIVE == ctx then BST_LM_LIVE = nil end
    return
  end
  r.defer(loop)
end

r.defer(loop)
