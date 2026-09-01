-- OxTools shared library. Do NOT run this file as an action.
-- Scripts load it with:  local lib = dofile(dir .. "bst_lib.lua")

local M = {}
M.SEC = "OxTools"

-- ---------------------------------------------------------------- math
function M.db2lin(db) return 10 ^ (db / 20) end
function M.lin2db(lin) return 20 * math.log(math.max(lin or 0, 1e-9), 10) end
function M.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
function M.rand_sym(range) return (math.random() * 2 - 1) * range end

-- ---------------------------------------------------------------- ext state
function M.ext_get(key, default)
  local v = reaper.GetExtState(M.SEC, key)
  if v == nil or v == "" then return default end
  return v
end

function M.ext_getnum(key, default)
  local v = reaper.GetExtState(M.SEC, key)
  if v == nil or v == "" then return default end
  return tonumber(v) or default
end

function M.ext_set(key, value)
  reaper.SetExtState(M.SEC, key, tostring(value), true)
end

-- ---------------------------------------------------------------- items
function M.selected_items()
  local t = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    t[#t + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  return t
end

function M.take_name(take)
  if not take then return "" end
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  return name or ""
end

function M.set_take_name(take, name)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
end

function M.item_track(item)
  return reaper.GetMediaItem_Track(item)
end

function M.track_name(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if name == nil or name == "" then
    name = "Track " .. tostring(math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) + 1)
  end
  return name
end

-- ---------------------------------------------------------------- naming
function M.sanitize(s)
  s = tostring(s or "")
  s = s:gsub("%.%w+$", "")            -- strip file extension
  s = s:gsub('[%c%/\\:%*%?"<>|]+', "_")
  s = s:gsub("%s+", "_")
  s = s:gsub("_+", "_")
  s = s:gsub("^_+", ""):gsub("_+$", "")
  return s
end

function M.escape_pattern(s)
  return (s:gsub("[%c%(%)%.%%+%-%*%?%[%^%$%]]", "%%%1"))
end

-- ---------------------------------------------------------------- cloning
-- Deterministic clone of an item's active take onto dest_track at pos.
-- Returns new_item, new_take (or nil with a reason string).
function M.clone_item(item, dest_track, pos)
  local src_take = reaper.GetActiveTake(item)
  if not src_take then return nil, "empty item" end
  if reaper.TakeIsMIDI(src_take) then return nil, "MIDI take" end
  local src = reaper.GetMediaItemTake_Source(src_take)
  if not src then return nil, "no source" end
  -- Lua binding returns the filename string directly (single value!)
  local fn = reaper.GetMediaSourceFileName(src)
  if not fn or fn == "" then return nil, "no source file" end
  local new_src = reaper.PCM_Source_CreateFromFile(fn)
  if not new_src then return nil, "source load failed" end

  local new_item = reaper.AddMediaItemToTrack(dest_track)
  local new_take = reaper.AddTakeToMediaItem(new_item)
  reaper.SetMediaItemTake_Source(new_take, new_src)

  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
  reaper.SetMediaItemInfo_Value(new_item, "D_VOL", reaper.GetMediaItemInfo_Value(item, "D_VOL"))
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"))
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"))
  reaper.SetMediaItemInfo_Value(new_item, "C_FADEINSHAPE", reaper.GetMediaItemInfo_Value(item, "C_FADEINSHAPE"))
  reaper.SetMediaItemInfo_Value(new_item, "C_FADEOUTSHAPE", reaper.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE"))
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEINDIR", reaper.GetMediaItemInfo_Value(item, "D_FADEINDIR"))
  reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTDIR", reaper.GetMediaItemInfo_Value(item, "D_FADEOUTDIR"))

  reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(src_take, "D_STARTOFFS"))
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_VOL", reaper.GetMediaItemTakeInfo_Value(src_take, "D_VOL"))
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_PAN", reaper.GetMediaItemTakeInfo_Value(src_take, "D_PAN"))
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE", reaper.GetMediaItemTakeInfo_Value(src_take, "D_PLAYRATE"))
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_PITCH", reaper.GetMediaItemTakeInfo_Value(src_take, "D_PITCH"))
  reaper.SetMediaItemTakeInfo_Value(new_take, "B_PPITCH", reaper.GetMediaItemTakeInfo_Value(src_take, "B_PPITCH"))
  M.set_take_name(new_take, M.take_name(src_take))
  return new_item, new_take
end

-- ---------------------------------------------------------------- analysis
-- Peak (0..1+) of what an item plays (pre-track-FX), including its item and
-- take volume. nil if not scannable.
function M.item_peak(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local srate = reaper.GetMediaSourceSampleRate(src)   -- single int, 0 for MIDI
  if not srate or srate < 1 then srate = 48000 end
  local nch = reaper.GetMediaSourceNumChannels(src)    -- single int
  if not nch or nch < 1 then nch = 1 end

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil end

  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local block = 65536
  local buf = reaper.new_array(nch * block + 16)
  local peak, t = 0, 0
  while t < len do
    local frames = math.min(block, math.max(1, math.ceil((len - t) * srate)))
    buf.clear()
    local rv = reaper.GetAudioAccessorSamples(aa, srate, nch, t, frames, buf)
    if rv == 1 then
      local tbl = buf.table(1, nch * frames)
      for j = 1, #tbl do
        local a = tbl[j]
        if a < 0 then a = -a end
        if a > peak then peak = a end
      end
    elseif rv < 0 then
      break
    end
    t = t + frames / srate
  end
  reaper.DestroyAudioAccessor(aa)
  -- AudioAccessor output is pre-item/take-volume; scale it in so callers get
  -- the level the item actually plays at.
  local ivol = reaper.GetMediaItemInfo_Value(item, "D_VOL")
  if not ivol or ivol ~= ivol then ivol = 1 end
  local tvol = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")
  if not tvol or tvol ~= tvol then tvol = 1 end
  return peak * math.abs(ivol) * math.abs(tvol)
end

-- ---------------------------------------------------------------- render prefs
function M.get_proj_str(key)
  local _, v = reaper.GetSetProjectInfo_String(0, key, "", false)
  return v
end

function M.set_proj_str(key, value)
  reaper.GetSetProjectInfo_String(0, key, value, true)
end

function M.get_proj_num(key)
  return reaper.GetSetProjectInfo(0, key, 0, false)
end

function M.set_proj_num(key, value)
  reaper.GetSetProjectInfo(0, key, value, true)
end

-- ---------------------------------------------------------------- engines
-- Shared by the standalone scripts and the SD Toolbox GUI.

-- Render media items silently as individual files. Saves/restores every
-- touched project render setting. Returns list of settings keys touched.
-- opts: pattern (default "$track_$item"), format ("evaw"|base64),
--       srate (0 = project rate), mono (bool), via_master (bool, default false =
--       render through the item's own track chain; true = through master),
--       tail_ms (>0 = append tail to each rendered item)
function M.render_items(items, out_dir, opts)
  opts = opts or {}
  local keys_num = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_TAILFLAG",
                     "RENDER_TAILMS", "RENDER_ADDTOPROJ", "RENDER_SRATE",
                     "RENDER_CHANNELS", "RENDER_NORMALIZE" }
  local saved_num, saved_str = {}, {}
  for _, k in ipairs(keys_num) do saved_num[k] = M.get_proj_num(k) end
  for _, k in ipairs({ "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT" }) do
    saved_str[k] = M.get_proj_str(k)
  end

  M.set_proj_num("RENDER_SETTINGS", opts.via_master and 64 or 32) -- selected items (/via master)
  M.set_proj_num("RENDER_BOUNDSFLAG", 4)     -- bounds: selected media items
  if opts.tail_ms and opts.tail_ms > 0 then
    M.set_proj_num("RENDER_TAILFLAG", 16)    -- &16 = tail applies to item renders
    M.set_proj_num("RENDER_TAILMS", opts.tail_ms)
  else
    M.set_proj_num("RENDER_TAILFLAG", 0)
    M.set_proj_num("RENDER_TAILMS", 0)
  end
  M.set_proj_num("RENDER_ADDTOPROJ", 0)
  M.set_proj_num("RENDER_NORMALIZE", 0)      -- no hidden normalization surprises
  M.set_proj_num("RENDER_SRATE", opts.srate or 0)
  M.set_proj_num("RENDER_CHANNELS", opts.mono and 1 or 2)
  M.set_proj_str("RENDER_FILE", out_dir)
  M.set_proj_str("RENDER_PATTERN", opts.pattern or "$track_$item")
  M.set_proj_str("RENDER_FORMAT", opts.format or "evaw")

  -- Item renders take the CURRENT selection as their bounds, so make the
  -- requested items the selection (restored afterwards). Without this, every
  -- call would render whatever happened to be selected in the arrange view.
  local prev_sel = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    prev_sel[#prev_sel + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  reaper.Main_OnCommand(40289, 0) -- deselect all items
  for _, it in ipairs(items) do reaper.SetMediaItemSelected(it, true) end

  reaper.Main_OnCommand(42230, 0)            -- silent render, auto-close dialog

  reaper.Main_OnCommand(40289, 0)
  for _, it in ipairs(prev_sel) do reaper.SetMediaItemSelected(it, true) end

  for _, k in ipairs(keys_num) do M.set_proj_num(k, saved_num[k]) end
  for k, v in pairs(saved_str) do M.set_proj_str(k, v) end
end

-- Render the given items as ONE mixdown file (block export). REAPER's
-- "selected media items" source always writes one file PER ITEM, so a block's
-- layered items must instead go out as a master-mix render bounded to a time
-- selection, with only the block's tracks soloed. Saves/restores every touched
-- setting (render cfg, track solos, time selection). opts: pattern (a literal
-- filename), format, srate, mono, tail_ms.
function M.render_block_mixdown(items, out_dir, opts)
  opts = opts or {}
  if not items or #items == 0 then return end

  local pmin, pmax = math.huge, -math.huge
  local tracks = {}
  for _, it in ipairs(items) do
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    pmin = math.min(pmin, p)
    pmax = math.max(pmax, p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
    tracks[M.item_track(it)] = true
  end
  if pmin >= pmax then return end

  -- save state we mutate beyond the render cfg. NOTE: this binding takes
  -- five args and returns (start, end) only - a four-value destructure
  -- silently yields nils.
  local ts_old, te_old = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  ts_old, te_old = ts_old or 0, te_old or 0
  local saved_solo = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    saved_solo[tr] = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO")
    reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", tracks[tr] and 1 or 0)
  end
  reaper.GetSet_LoopTimeRange(true, false, pmin, pmax, false)

  local keys_num = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_TAILFLAG",
                     "RENDER_TAILMS", "RENDER_ADDTOPROJ", "RENDER_SRATE",
                     "RENDER_CHANNELS", "RENDER_NORMALIZE" }
  local saved_num, saved_str = {}, {}
  for _, k in ipairs(keys_num) do saved_num[k] = M.get_proj_num(k) end
  for _, k in ipairs({ "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT" }) do
    saved_str[k] = M.get_proj_str(k)
  end

  M.set_proj_num("RENDER_SETTINGS", 0)       -- master mix
  M.set_proj_num("RENDER_BOUNDSFLAG", 2)     -- time selection
  M.set_proj_num("RENDER_TAILFLAG", (opts.tail_ms and opts.tail_ms > 0) and 1 or 0)
  M.set_proj_num("RENDER_TAILMS", opts.tail_ms or 0)
  M.set_proj_num("RENDER_ADDTOPROJ", 0)
  M.set_proj_num("RENDER_NORMALIZE", 0)
  M.set_proj_num("RENDER_SRATE", opts.srate or 0)
  M.set_proj_num("RENDER_CHANNELS", opts.mono and 1 or 2)
  M.set_proj_str("RENDER_FILE", out_dir)
  M.set_proj_str("RENDER_PATTERN", opts.pattern or "block")
  M.set_proj_str("RENDER_FORMAT", opts.format or "evaw")

  reaper.Main_OnCommand(42230, 0)            -- silent render, auto-close dialog

  for _, k in ipairs(keys_num) do M.set_proj_num(k, saved_num[k]) end
  for k, v in pairs(saved_str) do M.set_proj_str(k, v) end
  for tr, solo in pairs(saved_solo) do
    reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", solo)
  end
  reaper.GetSet_LoopTimeRange(true, false, ts_old, te_old, false)
end

-- Generate randomized variations of items. opts:
--   count, pitch_st (semitone +- range), vol_db (+- dB), pan (0..1 spread),
--   gap_s (spacing after source item), ppitch (bool), suffix_base,
--   place ("seq" = sequential after source on same track [default],
--          "stack" = all variations at identical positions on a new "<track> VAR" track),
--   fade_max_ms (>0 = randomize each variation's fades up to this length)
-- Returns created count, skipped list. Caller owns the undo block.
function M.generate_variations(items, o)
  o.count    = math.max(1, math.floor(o.count or 1))
  o.pitch_st = o.pitch_st or 0
  o.vol_db   = o.vol_db or 0
  o.pan      = o.pan or 0
  o.gap_s    = o.gap_s or 0
  o.suffix_base = o.suffix_base or "_v"
  local stack = (o.place == "stack")
  local created, skipped = 0, {}
  local var_tracks = stack and {} or nil

  for i = 1, #items do
    local item = items[i]
    local src_track = M.item_track(item)
    local dest_track = src_track
    if var_tracks then
      local key = tostring(src_track)
      dest_track = var_tracks[key]
      if not dest_track then
        local n = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(n, false)
        dest_track = reaper.GetTrack(0, n)
        reaper.GetSetMediaTrackInfo_String(dest_track, "P_NAME", M.track_name(src_track) .. " VAR", true)
        var_tracks[key] = dest_track
      end
    end
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local base_name = M.take_name(reaper.GetActiveTake(item))
    if base_name == "" then base_name = "sfx" end

    for k = 1, o.count do
      local vpos = stack and pos or (pos + (len + o.gap_s) * k)
      -- clone_item returns (item, take) on success, (nil, reason) on failure
      local new_item, new_take = M.clone_item(item, dest_track, vpos)
      if new_item then
        if o.pitch_st > 0 then
          local cur = reaper.GetMediaItemTakeInfo_Value(new_take, "D_PITCH")
          reaper.SetMediaItemTakeInfo_Value(new_take, "D_PITCH", cur + M.rand_sym(o.pitch_st))
          -- B_PPITCH is a numeric property: 1/0, never a Lua boolean
          reaper.SetMediaItemTakeInfo_Value(new_take, "B_PPITCH", (o.ppitch ~= false) and 1 or 0)
        end
        if o.vol_db > 0 then
          local cur = reaper.GetMediaItemInfo_Value(new_item, "D_VOL")
          reaper.SetMediaItemInfo_Value(new_item, "D_VOL", cur * M.db2lin(M.rand_sym(o.vol_db)))
        end
        if o.pan > 0 then
          local cur = reaper.GetMediaItemTakeInfo_Value(new_take, "D_PAN")
          reaper.SetMediaItemTakeInfo_Value(new_take, "D_PAN", M.clamp(cur + M.rand_sym(o.pan), -1, 1))
        end
        if o.fade_max_ms and o.fade_max_ms > 0 then
          local fmax = o.fade_max_ms / 1000
          reaper.SetMediaItemInfo_Value(new_item, "D_FADEINLEN", math.random() * fmax)
          reaper.SetMediaItemInfo_Value(new_item, "D_FADEOUTLEN", math.random() * fmax)
        end
        M.set_take_name(new_take, string.format("%s%s%02d", base_name, o.suffix_base, k))
        created = created + 1
      else
        skipped[#skipped + 1] = tostring(new_take)
      end
    end
  end
  return created, skipped
end

-- Batch-rename active takes of items. opts:
--   prefix, suffix, search (Lua pattern), replace,
--   scheme_track (TrackName_Name), scheme_number (_001.. per track)
-- Returns renamed count. lib.last_error holds an invalid-pattern message.
-- Caller owns the undo block.
function M.rename_items(items, o)
  M.last_error = nil
  local counters, renamed = {}, 0
  for i = 1, #items do
    local take = reaper.GetActiveTake(items[i])
    if take then
      local track = M.item_track(items[i])
      local key = tostring(track)
      counters[key] = (counters[key] or 0) + 1

      local name = M.take_name(take)
      if o.search and o.search ~= "" then
        -- capture into a local FIRST: passing the gsub expression straight
        -- into pcall() would hand its (string, count) pair to string.gsub as
        -- (repl, max_n), silently limiting replacements to 0.
        local repl = (o.replace or ""):gsub("%%", "%%%%")
        local okg, res = pcall(string.gsub, name, o.search, repl)
        if not okg then
          M.last_error = tostring(res)
          break -- invalid pattern: stop instead of dying mid-undo-block
        end
        name = res
      end
      if name == "" then name = "sfx" end
      name = (o.prefix or "") .. name .. (o.suffix or "")
      if o.scheme_track then
        name = M.sanitize(M.track_name(track)) .. "_" .. M.sanitize(name)
      end
      if o.scheme_number then
        name = name .. string.format("_%03d", counters[key])
      end
      M.set_take_name(take, name)
      renamed = renamed + 1
    end
  end
  return renamed
end

-- Clone of an item's active take restricted to a project-time content window
-- [p1, p2] (inside the item), placed on dest_track at pos. Keeps playrate /
-- pitch / fades zeroed (caller decides fades). Returns new_item, new_take or
-- nil, reason.
function M.window_item(item, dest_track, pos, p1, p2)
  local src_take = reaper.GetActiveTake(item)
  if not src_take then return nil, "empty item" end
  if reaper.TakeIsMIDI(src_take) then return nil, "MIDI take" end
  local src = reaper.GetMediaItemTake_Source(src_take)
  if not src then return nil, "no source" end
  local fn = reaper.GetMediaSourceFileName(src)
  if not fn or fn == "" then return nil, "no source file" end
  local new_src = reaper.PCM_Source_CreateFromFile(fn)
  if not new_src then return nil, "source load failed" end

  local P0 = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local R  = reaper.GetMediaItemTakeInfo_Value(src_take, "D_PLAYRATE") or 1
  local O0 = reaper.GetMediaItemTakeInfo_Value(src_take, "D_STARTOFFS") or 0
  p1 = math.max(p1, P0)
  p2 = math.min(p2, P0 + reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
  if p2 - p1 <= 1e-6 then return nil, "empty window" end

  local new_item = reaper.AddMediaItemToTrack(dest_track)
  local new_take = reaper.AddTakeToMediaItem(new_item)
  reaper.SetMediaItemTake_Source(new_take, new_src)
  reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", p2 - p1)
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", O0 + (p1 - P0) * R)
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE", R)
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_PITCH",
    reaper.GetMediaItemTakeInfo_Value(src_take, "D_PITCH"))
  reaper.SetMediaItemTakeInfo_Value(new_take, "B_PPITCH",
    reaper.GetMediaItemTakeInfo_Value(src_take, "B_PPITCH"))
  reaper.SetMediaItemTakeInfo_Value(new_take, "D_VOL",
    reaper.GetMediaItemTakeInfo_Value(src_take, "D_VOL"))
  reaper.SetMediaItemInfo_Value(new_item, "D_VOL",
    reaper.GetMediaItemInfo_Value(item, "D_VOL"))
  return new_item, new_take
end

-- Project time of the loudest RMS window (about 10 ms) an item plays.
-- Peak-detection mode "none" returns the item center. nil if not scannable.
function M.item_rms_peak_time(item, mode)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if mode == "none" then return pos + len / 2 end
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local srate = reaper.GetMediaSourceSampleRate(src)
  if not srate or srate < 1 then srate = 48000 end
  local nch = reaper.GetMediaSourceNumChannels(src)
  if not nch or nch < 1 then nch = 1 end

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil end
  local win = math.max(math.floor(srate * 0.010), 64)  -- ~10 ms RMS window
  local best_rms, best_t, t = -1, nil, 0
  local buf = reaper.new_array(nch * win + 16)
  while t < len - 1e-6 do
    local frames = math.min(win, math.max(1, math.ceil((len - t) * srate)))
    buf.clear()
    local rv = reaper.GetAudioAccessorSamples(aa, srate, nch, t, frames, buf)
    if rv == 1 then
      local tbl = buf.table(1, nch * frames)
      local sum = 0
      for j = 1, #tbl do sum = sum + tbl[j] * tbl[j] end
      local rms = math.sqrt(sum / #tbl)
      if rms > best_rms then best_rms = rms; best_t = pos + t + frames / srate / 2 end
    elseif rv < 0 then
      break
    end
    t = t + frames / srate
  end
  reaper.DestroyAudioAccessor(aa)
  return best_t
end

-- ---------------------------------------------------------------- zero crossing
-- Nearest sign-flip time (item time) around t within +/-window seconds. nil if none.
function M.find_zero_cross(item, t, window)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local srate = reaper.GetMediaSourceSampleRate(src)
  if not srate or srate < 1 then srate = 48000 end
  local nch = reaper.GetMediaSourceNumChannels(src)
  if not nch or nch < 1 then nch = 1 end
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local win = window or 0.005
  local a = math.max(0, t - win)
  local b = math.min(len, t + win)
  if b <= a then return nil end

  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return nil end
  local frames = math.max(2, math.ceil((b - a) * srate))
  local buf = reaper.new_array(nch * frames + 16)
  buf.clear()
  local rv = reaper.GetAudioAccessorSamples(aa, srate, nch, a, frames, buf)
  local found = nil
  if rv == 1 then
    local tbl = buf.table(1, nch * frames)
    local prev = nil
    for i = 0, frames - 1 do
      local s = 0
      for c = 1, nch do s = s + tbl[i * nch + c] end
      s = s / nch
      if prev ~= nil and ((prev <= 0 and s >= 0) or (prev >= 0 and s <= 0)) then
        found = a + i / srate
        break
      end
      prev = s
    end
  end
  reaper.DestroyAudioAccessor(aa)
  return found
end

-- Trim item start/end ("start","end","both") to nearest zero crossings.
-- Returns true if anything changed.
function M.trim_to_zero(item, which, window)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local take = reaper.GetActiveTake(item)
  if not take then return false end
  local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local changed = false
  if which == "start" or which == "both" then
    local zt = M.find_zero_cross(item, 0.0005, window)
    if zt then
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos + zt)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len - zt)
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offs + zt * playrate)
      changed = true
    end
  end
  if which == "end" or which == "both" then
    len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local zt = M.find_zero_cross(item, len - 0.0005, window)
    if zt then
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", zt)
      changed = true
    end
  end
  return changed
end

-- Seamless one-shot loop: zero-cross both edges, then enable source looping.
function M.make_loop(item, window)
  M.trim_to_zero(item, "both", window)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 1)
end

return M
