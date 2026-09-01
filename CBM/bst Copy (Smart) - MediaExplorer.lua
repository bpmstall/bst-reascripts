--[[
  bst Copy (Smart) - MediaExplorer — Media Explorer 版智能复制
  ====================================================
  注册在 Media Explorer 快捷键区 (31991), 建议把该区的 Ctrl+C 绑定到本动作。
  行为: 执行 ME 的「复制媒体文件路径」(ID 42303),
        主面板的剪贴板监视会把路径文本自动捕获为媒体条目。
  若你的 REAPER 版本里 42303 行为不符, 在动作列表过滤 "media explorer" 核对后改下方 ID。
--]]
reaper.Main_OnCommand(42303, 0)
