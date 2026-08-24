--[[
  bst Copy Items — 复制 item 同时捕获到剪贴板面板
  ======================================================
  替代 Ctrl+C: 先执行 REAPER 原生 "Edit: Copy items", 再捕获选中 item 到面板。
  (智能版见 bst Copy (Smart).lua, 已默认绑定 Ctrl+C)
--]]
-- 1) REAPER 原生复制 (Ctrl+C 的标准行为: 把 item 放进 REAPER 内部剪贴板)
reaper.Main_OnCommand(40698, 0)  -- 40698 = "Edit: Copy items"

-- 2) 捕获选中 item 到 bst Clipboard Manager 面板
CBM_CMD = 'capture_items'
CBM_ARGS = nil
local info = debug.getinfo(1, 'S')
local src = (info and info.source or ''):gsub('^@', '')
local dir = src:match('^(.*)[/' .. string.char(92) .. ']') or (reaper.GetResourcePath() .. '/Scripts')
dofile(dir .. '/bst Clipboard Manager.lua')
