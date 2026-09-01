--[[
  bst Copy (Smart) - MIDI — MIDI 编辑器版智能复制
  ====================================================
  注册在 MIDI 编辑器快捷键区 (32060), 建议把该区的 Ctrl+C 绑定到本动作。
  行为: 把当前 MIDI 编辑器 take 的音符捕获进剪贴板面板,
        然后转发 MIDI 编辑器原生复制 (Edit: Copy), 原工作流不受影响。
--]]
local ed = reaper.MIDIEditor_GetActive()
if not ed then return end

CBM_CMD = 'capture_midi'
CBM_ARGS = nil
local info = debug.getinfo(1, 'S')
local src = (info and info.source or ''):gsub('^@', '')
local dir = src:match('^(.*)[/' .. string.char(92) .. ']') or (reaper.GetResourcePath() .. '/Scripts')
dofile(dir .. '/bst Clipboard Manager.lua')

-- 转发 MIDI 编辑器原生复制 (Edit: Copy selected events)
reaper.MIDIEditor_LastFocused_OnCommand(40060, true)
