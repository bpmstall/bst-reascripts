-- bst: Take Next (无 GUI 动作, 建议绑定快捷键)
-- 选中 item 切到下一个 take (循环)。对标 nvk_TAKES 变体切换。
-- 依赖同目录 bst_lib.lua

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local r = reaper

local TITLE = "Take Next"
local STEP = 1

math.randomseed(os.time())

local items = lib.selected_items()
if #items == 0 then
  r.MB("请先选中至少一个 item。", TITLE, 0)
  return
end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)
local n = 0
for _, it in ipairs(items) do
  local cnt = r.CountTakes(it)
  if cnt > 1 then
    local take = r.GetActiveTake(it)
    local cur = 0
    for i = 0, cnt - 1 do
      if r.GetTake(it, i) == take then cur = i break end
    end
    local nxt
    if STEP == "random" then
      nxt = math.random(0, cnt - 1)
      if nxt == cur then nxt = (nxt + 1) % cnt end
    else
      nxt = (cur + STEP) % cnt
      if take == nil then nxt = (STEP > 0) and 0 or cnt - 1 end
    end
    r.SetActiveTake(r.GetTake(it, nxt))
    n = n + 1
  end
end
r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock(string.format("bst: Take 切换 %d 个 item", n), -1)
if n == 0 then r.ShowConsoleMsg("bst Take: 选中 item 都没有多个 take\n") end
