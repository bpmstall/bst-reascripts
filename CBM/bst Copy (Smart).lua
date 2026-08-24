--[[
  bst Copy (Smart) — 智能复制并捕获到剪贴板面板
  ====================================================
  根据当前选中状态自动选择复制类型:
    · 选中 item → 复制 item
    · 选中轨道 (无 item 选中) → 复制轨道
    · 光标在包络上 / 选中包络 → 复制包络点
  先执行 REAPER 原生复制命令, 再立即捕获到剪贴板面板。

  绑定: 本动作已绑定 Ctrl+C (覆盖默认复制, 见 reaper-kb.ini)。
--]]
local cnt_items  = reaper.CountSelectedMediaItems(0)
local cnt_tracks = reaper.CountSelectedTracks(0)
local env = reaper.GetSelectedEnvelope(0)

-- 1) 执行 REAPER 原生复制
if cnt_items > 0 then
  reaper.Main_OnCommand(40698, 0)  -- Edit: Copy items
elseif cnt_tracks > 0 then
  reaper.Main_OnCommand(41383, 0)  -- Edit: Copy tracks
elseif env then
  -- 复制选中包络点 (焦点在包络时 Ctrl+C 的等效动作)
  reaper.Main_OnCommand(40154, 0)
end

-- 2) 捕获到 bst Clipboard Manager 面板
if cnt_items > 0 then
  CBM_CMD = 'capture_items'
elseif cnt_tracks > 0 then
  CBM_CMD = 'capture_tracks'
elseif env then
  CBM_CMD = 'capture_envelope'
end

if CBM_CMD then
  CBM_ARGS = nil
  local info = debug.getinfo(1, 'S')
  local src = (info and info.source or ''):gsub('^@', '')
  local dir = src:match('^(.*)[/' .. string.char(92) .. ']') or (reaper.GetResourcePath() .. '/Scripts')
  dofile(dir .. '/bst Clipboard Manager.lua')
end
