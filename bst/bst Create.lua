-- bst: Create (nvk_CREATE-style multi-layer sound generator, Fluent panel)
-- Searches local sample libraries / project items by keywords, randomly layers
-- matching audio assets across dedicated tracks, automatically aligns transient
-- peaks (via snap offsets), and shapes layers with pitch/volume/reverse variation.
-- Supports batch variation generation and in-place re-roll / replace.
-- Keys: create_* in ExtState "OxTools". Built on bst_fluent.lua and bst_lib.lua.

local r = reaper

if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Create', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)

if BST_CREATE_LIVE and ImGui.ValidatePtr(BST_CREATE_LIVE, 'ImGui_Context*') then
  return -- panel already open
end
local ctx = ImGui.CreateContext('bst Create')
BST_CREATE_LIVE = ctx

--------------------------------------------------------------------------------
-- State & Preferences
--------------------------------------------------------------------------------
local AUDIO_EXTS = { [".wav"] = true, [".aif"] = true, [".aiff"] = true, [".flac"] = true, [".ogg"] = true, [".mp3"] = true }

local st = {
  main_query  = lib.ext_get("create_query", "impact metal"),
  var_count   = math.max(1, math.min(10, math.floor(lib.ext_getnum("create_var_count", 3)))),
  gap_s       = lib.ext_getnum("create_gap_s", 0.5),
  max_len_s   = lib.ext_getnum("create_max_len", 2.0),
  align_peak  = (lib.ext_getnum("create_align_peak", 1) == 1),
  auto_fade   = (lib.ext_getnum("create_auto_fade", 1) == 1),
  create_folder = (lib.ext_getnum("create_folder", 1) == 1),
  lib_dirs    = lib.ext_get("create_lib_dirs", "F:\\Sound Pack"),
  use_proj    = (lib.ext_getnum("create_use_proj", 1) == 1),
}

-- 4 default layers (can add/remove/toggle)
local DEFAULT_LAYERS = {
  { name = "Attack", query = "click hit attack", vol = 0.0, pan = 0.0, pitch_st = 3, rev_prob = 0, jitter_ms = 0, enabled = true },
  { name = "Body",   query = "metal punch body", vol = 0.0, pan = 0.0, pitch_st = 4, rev_prob = 10, jitter_ms = 5, enabled = true },
  { name = "Sub",    query = "sub low boom thud", vol = 1.0, pan = 0.0, pitch_st = 2, rev_prob = 0, jitter_ms = 0, enabled = true },
  { name = "Tail",   query = "tail reverb ring", vol = -3.0, pan = 0.1, pitch_st = 5, rev_prob = 20, jitter_ms = 15, enabled = true },
}

local layers = {}
for i, def in ipairs(DEFAULT_LAYERS) do
  local pre = "create_l" .. i .. "_"
  layers[i] = {
    name      = lib.ext_get(pre .. "name", def.name),
    query     = lib.ext_get(pre .. "query", def.query),
    vol       = lib.ext_getnum(pre .. "vol", def.vol),
    pan       = lib.ext_getnum(pre .. "pan", def.pan),
    pitch_st  = lib.ext_getnum(pre .. "pitch", def.pitch_st),
    rev_prob  = lib.ext_getnum(pre .. "rev", def.rev_prob),
    jitter_ms = lib.ext_getnum(pre .. "jit", def.jitter_ms),
    enabled   = (lib.ext_getnum(pre .. "en", def.enabled and 1 or 0) == 1),
  }
end

local function save_state()
  lib.ext_set("create_query", st.main_query)
  lib.ext_set("create_var_count", st.var_count)
  lib.ext_set("create_gap_s", st.gap_s)
  lib.ext_set("create_max_len", st.max_len_s)
  lib.ext_set("create_align_peak", st.align_peak and 1 or 0)
  lib.ext_set("create_auto_fade", st.auto_fade and 1 or 0)
  lib.ext_set("create_folder", st.create_folder and 1 or 0)
  lib.ext_set("create_lib_dirs", st.lib_dirs)
  lib.ext_set("create_use_proj", st.use_proj and 1 or 0)
  for i, l in ipairs(layers) do
    local pre = "create_l" .. i .. "_"
    lib.ext_set(pre .. "name", l.name)
    lib.ext_set(pre .. "query", l.query)
    lib.ext_set(pre .. "vol", l.vol)
    lib.ext_set(pre .. "pan", l.pan)
    lib.ext_set(pre .. "pitch", l.pitch_st)
    lib.ext_set(pre .. "rev", l.rev_prob)
    lib.ext_set(pre .. "jit", l.jitter_ms)
    lib.ext_set(pre .. "en", l.enabled and 1 or 0)
  end
end

--------------------------------------------------------------------------------
-- Sample Index & Search
--------------------------------------------------------------------------------
local db_files = {}       -- all scanned files { path = "...", name = "..." }
local is_scanning = false
local scan_msg = "素材库未扫描"
local status_msg = "就绪"
local show_settings = false

local function get_file_ext(p)
  return p:match("(%.[^.]+)$") and p:match("(%.[^.]+)$"):lower() or ""
end

local function scan_folder_recursive(path, bucket, max_depth)
  max_depth = max_depth or 6
  if max_depth <= 0 then return end
  local i = 0
  while true do
    local fn = r.EnumerateFiles(path, i)
    if not fn then break end
    local ext = get_file_ext(fn)
    if AUDIO_EXTS[ext] then
      local sep = (path:sub(-1) == "/" or path:sub(-1) == "/") and "" or "/"
      local full = path .. sep .. fn
      bucket[#bucket + 1] = { path = full, name = fn:lower(), display = fn }
    end
    i = i + 1
  end
  local j = 0
  while true do
    local sub = r.EnumerateSubdirectories(path, j)
    if not sub then break end
    if sub ~= "." and sub ~= ".." and sub ~= ".git" then
      local sep = (path:sub(-1) == "/" or path:sub(-1) == "/") and "" or "/"
      scan_folder_recursive(path .. sep .. sub, bucket, max_depth - 1)
    end
    j = j + 1
  end
end

local function refresh_library()
  db_files = {}
  local t0 = r.time_precise()

  -- 1. Scan configured directories
  for line in st.lib_dirs:gmatch("[^\r\n;]+") do
    local p = line:gsub("^%s+", ""):gsub("%s+$", "")
    if p ~= "" then
      scan_folder_recursive(p, db_files, 6)
    end
  end

  -- 2. Scan current project directory
  if st.use_proj then
    local _, proj_fn = r.EnumProjects(-1, "")
    if proj_fn and proj_fn ~= "" then
      local proj_dir = proj_fn:match("^(.*[\\/])")
      if proj_dir then
        scan_folder_recursive(proj_dir, db_files, 4)
      end
    end
  end

  local dur = r.time_precise() - t0
  scan_msg = string.format("已索引 %d 个样本 (耗时 %.2fs)", #db_files, dur)
  status_msg = scan_msg
end

-- Matches multi-term query: "impact metal -loop"
local function match_query(str, query)
  if not query or query == "" then return true end
  local text = str:lower()
  for word in query:gmatch("%S+") do
    word = word:lower()
    if word:sub(1, 1) == "-" then
      local neg = word:sub(2)
      if neg ~= "" and text:find(neg, 1, true) then
        return false
      end
    else
      if not text:find(word, 1, true) then
        return false
      end
    end
  end
  return true
end

local function search_samples(layer_query)
  local q = (layer_query and layer_query ~= "") and layer_query or st.main_query
  local matches = {}
  for _, item in ipairs(db_files) do
    if match_query(item.path, q) then
      matches[#matches + 1] = item.path
    end
  end
  return matches, q
end

--------------------------------------------------------------------------------
-- Sound Generation Engine (nvk_CREATE core)
--------------------------------------------------------------------------------
local function create_layer_tracks(base_name, active_layers)
  r.PreventUIRefresh(1)
  local root_idx = r.GetNumTracks()
  r.InsertTrackAtIndex(root_idx, true)
  local root_track = r.GetTrack(0, root_idx)
  r.GetSetMediaTrackInfo_String(root_track, "P_NAME", "[Create] " .. base_name, true)

  local track_list = {}
  if #active_layers == 1 and not st.create_folder then
    track_list[1] = root_track
    r.PreventUIRefresh(-1)
    return root_track, track_list
  end

  -- Set root as folder start
  r.SetMediaTrackInfo_Value(root_track, "I_FOLDERDEPTH", 1)

  for idx, l in ipairs(active_layers) do
    local t_idx = root_idx + idx
    r.InsertTrackAtIndex(t_idx, true)
    local t = r.GetTrack(0, t_idx)
    r.GetSetMediaTrackInfo_String(t, "P_NAME", string.format("L%d_%s", idx, l.name), true)
    track_list[idx] = t
    if idx == #active_layers then
      -- Close folder on last child track
      r.SetMediaTrackInfo_Value(t, "I_FOLDERDEPTH", -1)
    end
  end
  r.PreventUIRefresh(-1)
  return root_track, track_list
end

local function insert_sample_at(dest_track, file_path, pos, layer_cfg)
  local src = r.PCM_Source_CreateFromFile(file_path)
  if not src then return nil end

  local item = r.AddMediaItemToTrack(dest_track)
  local take = r.AddTakeToMediaItem(item)
  r.SetMediaItemTake_Source(take, src)

  local src_len = r.GetMediaSourceLength(src) or 2.0
  local play_len = math.min(src_len, st.max_len_s)

  r.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  r.SetMediaItemInfo_Value(item, "D_LENGTH", play_len)

  -- Volume & Pan
  local vol_lin = lib.db2lin(layer_cfg.vol)
  r.SetMediaItemInfo_Value(item, "D_VOL", vol_lin)
  r.SetMediaItemTakeInfo_Value(take, "D_PAN", lib.clamp(layer_cfg.pan, -1.0, 1.0))

  -- Pitch randomization
  if layer_cfg.pitch_st > 0 then
    local p_delta = lib.rand_sym(layer_cfg.pitch_st)
    r.SetMediaItemTakeInfo_Value(take, "D_PITCH", p_delta)
    r.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
  end

  -- Reverse probability
  if layer_cfg.rev_prob > 0 and math.random(100) <= layer_cfg.rev_prob then
    -- Toggle reverse take
    local cur_src = r.GetMediaItemTake_Source(take)
    if cur_src then
      -- REAPER reverse take via chunk or setting playrate negative
      local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", -math.abs(rate))
      r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", play_len)
    end
  end

  -- Timing jitter
  if layer_cfg.jitter_ms and layer_cfg.jitter_ms > 0 then
    local jit_s = lib.rand_sym(layer_cfg.jitter_ms / 1000)
    local cur_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    r.SetMediaItemInfo_Value(item, "D_POSITION", math.max(0, cur_pos + jit_s))
  end

  -- Transient / Peak Snap Alignment
  if st.align_peak then
    local peak_time = lib.item_rms_peak_time(item, "rms")
    if peak_time then
      local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
      local snap_offs = math.max(0, peak_time - item_pos)
      r.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", snap_offs)
      -- Shift item so snap offset aligns with target pos
      r.SetMediaItemInfo_Value(item, "D_POSITION", math.max(0, pos - snap_offs))
    end
  end

  -- Auto Fade In / Fade Out
  if st.auto_fade then
    r.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0.003) -- 3ms transient anti-pop
    r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", math.min(0.2, play_len * 0.3))
  end

  -- Tag take name with query for later re-roll
  local fn = file_path:match("([^\\/]+)$") or "sample"
  lib.set_take_name(take, fn)
  -- Store query in ExtState or take guid for re-roll
  local guid = r.BR_GetMediaItemTakeGUID and r.BR_GetMediaItemTakeGUID(take) or tostring(take)
  r.SetProjExtState(0, "BST_CREATE_TAKE", guid, layer_cfg.query ~= "" and layer_cfg.query or st.main_query)

  return item
end

local function generate_variations()
  if #db_files == 0 then
    refresh_library()
    if #db_files == 0 then
      status_msg = "未找到音频文件，请在设置中指定素材库目录！"
      return
    end
  end

  local active_layers = {}
  for _, l in ipairs(layers) do
    if l.enabled then active_layers[#active_layers + 1] = l end
  end

  if #active_layers == 0 then
    status_msg = "请至少启用一个 Layer！"
    return
  end

  math.randomseed(os.time())
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local cursor_pos = r.GetCursorPosition()
  local root_track, track_list = create_layer_tracks(st.main_query, active_layers)

  local total_created = 0
  for v = 1, st.var_count do
    local var_pos = cursor_pos + (v - 1) * (st.max_len_s + st.gap_s)
    for l_idx, layer_cfg in ipairs(active_layers) do
      local pool, used_q = search_samples(layer_cfg.query)
      if #pool > 0 then
        local chosen_file = pool[math.random(#pool)]
        local it = insert_sample_at(track_list[l_idx], chosen_file, var_pos, layer_cfg)
        if it then total_created = total_created + 1 end
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst Create: %d 变奏分层生成", st.var_count), -1)

  status_msg = string.format("成功生成 %d 组变奏 (共 %d 个分层 Item)！", st.var_count, total_created)
end

-- Re-roll selected items with another random sample from matching query
local function reroll_selected()
  local items = lib.selected_items()
  if #items == 0 then
    status_msg = "请先在时间线上选中要替换的 Item。"
    return
  end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local replaced = 0

  for _, item in ipairs(items) do
    local take = r.GetActiveTake(item)
    if take then
      local guid = r.BR_GetMediaItemTakeGUID and r.BR_GetMediaItemTakeGUID(take) or tostring(take)
      local _, q = r.GetProjExtState(0, "BST_CREATE_TAKE", guid)
      if not q or q == "" then q = st.main_query end

      local pool = search_samples(q)
      if #pool > 0 then
        local new_file = pool[math.random(#pool)]
        local new_src = r.PCM_Source_CreateFromFile(new_file)
        if new_src then
          r.SetMediaItemTake_Source(take, new_src)
          local fn = new_file:match("([^\\/]+)$") or "sample"
          lib.set_take_name(take, fn)
          replaced = replaced + 1
        end
      end
    end
  end

  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst Create: 重新随机 %d 个 Item", replaced), -1)
  status_msg = string.format("已重新换选 %d 个 Item！", replaced)
end

--------------------------------------------------------------------------------
-- GUI Loop (Fluent 2 Style)
--------------------------------------------------------------------------------
fl.attach_fonts(ctx)

local function loop()
  local nc, nv = fl.push_theme(ctx)
  ImGui.SetNextWindowSize(ctx, 580, 560, ImGui.Cond_FirstUseEver)
  local visible, p_open = ImGui.Begin(ctx, 'bst Create (nvk_CREATE 式分层生成)', true)

  if visible then
    -- Header & Search Bar
    ImGui.Text(ctx, "全局关键词 (Global Query):")
    ImGui.SetNextItemWidth(ctx, -120)
    local q_changed, new_q = ImGui.InputText(ctx, "##main_q", st.main_query)
    if q_changed then st.main_query = new_q end

    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "素材库设置", 110, 0) then
      show_settings = not show_settings
    end

    -- Settings panel drawer
    if show_settings then
      if fl.begin_card and fl.begin_card(ctx, "settings_card", 130) then
        ImGui.Text(ctx, "音效素材库目录 (支持多路径，分号或换行分隔):")
        local d_changed, new_d = ImGui.InputTextMultiline(ctx, "##dirs", st.lib_dirs, -1, 50)
        if d_changed then st.lib_dirs = new_d end

        local p_changed, new_p = ImGui.Checkbox(ctx, "同时包含当前工程媒体目录", st.use_proj)
        if p_changed then st.use_proj = new_p end

        ImGui.SameLine(ctx)
        if fl.button(ctx, "立即扫描素材库") then
          refresh_library()
        end
        ImGui.SameLine(ctx)
        ImGui.TextDisabled(ctx, scan_msg)
        fl.end_card(ctx)
      end
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Parameters
    ImGui.Text(ctx, "生成参数:")
    ImGui.SetNextItemWidth(ctx, 110)
    local vc_changed, new_vc = ImGui.SliderInt(ctx, "变奏组数 (Variations)", st.var_count, 1, 10)
    if vc_changed then st.var_count = new_vc end

    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 110)
    local ml_changed, new_ml = ImGui.SliderDouble(ctx, "最长秒数 (Max s)", st.max_len_s, 0.2, 10.0, "%.1fs")
    if ml_changed then st.max_len_s = new_ml end

    local ap_changed, new_ap = ImGui.Checkbox(ctx, "瞬态峰值吸附对齐 (Auto Transient Align)", st.align_peak)
    if ap_changed then st.align_peak = new_ap end

    ImGui.SameLine(ctx)
    local af_changed, new_af = ImGui.Checkbox(ctx, "微淡入淡出 (Auto Fade)", st.auto_fade)
    if af_changed then st.auto_fade = new_af end

    ImGui.Spacing(ctx)

    -- Layers Card
    ImGui.Text(ctx, "分层配置 (Layers):")
    if fl.begin_card and fl.begin_card(ctx, "layers_card", 160) then
      for i, l in ipairs(layers) do
        ImGui.PushID(ctx, i)
        local en_c, new_en = ImGui.Checkbox(ctx, "##en", l.enabled)
        if en_c then l.enabled = new_en end
        ImGui.SameLine(ctx)

        ImGui.Text(ctx, string.format("L%d [%s]", i, l.name))
        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, 130)
        local lq_c, new_lq = ImGui.InputText(ctx, "##lq", l.query)
        if lq_c then l.query = new_lq end

        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, 60)
        local p_c, new_p = ImGui.DragInt(ctx, "±st##p", l.pitch_st, 0.2, 0, 24)
        if p_c then l.pitch_st = new_p end

        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, 60)
        local v_c, new_v = ImGui.DragDouble(ctx, "dB##v", l.vol, 0.1, -24, 12, "%.1f")
        if v_c then l.vol = new_v end

        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, 60)
        local r_c, new_r = ImGui.DragInt(ctx, "rev%##r", l.rev_prob, 0.5, 0, 100)
        if r_c then l.rev_prob = new_r end

        ImGui.PopID(ctx)
      end
      fl.end_card(ctx)
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Action Buttons
    if fl.button(ctx, string.format("✨ 一键生成 %d 组变奏 (Generate)", st.var_count), { accent = true, height = 36 }) then
      generate_variations()
      save_state()
    end

    ImGui.Spacing(ctx)
    if fl.button(ctx, "🎲 选中项就地换选 (Re-roll Selected)", { width = -1, height = 28 }) then
      reroll_selected()
    end

    -- Status bar
    ImGui.Spacing(ctx)
    ImGui.TextDisabled(ctx, "状态: " .. status_msg)

    ImGui.End(ctx)
  end

  fl.pop_theme(ctx, nc, nv)

  if p_open then
    r.defer(loop)
  else
    save_state()
    BST_CREATE_LIVE = nil
  end
end

r.defer(loop)
