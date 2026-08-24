-- bst Clipboard Manager 动作 stub: 通过全局 CBM_CMD 分发到主面板 (协议不变)
-- toggle sidebar visibility (bind a shortcut to this action)
CBM_CMD = 'toggle'
CBM_ARGS = nil
local info = debug.getinfo(1, 'S')
local src = (info and info.source or ''):gsub('^@', '')
local dir = src:match('^(.*)[/' .. string.char(92) .. ']') or (reaper.GetResourcePath() .. '/Scripts')
dofile(dir .. '/bst Clipboard Manager.lua')
