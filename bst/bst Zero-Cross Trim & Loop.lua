-- bst: Zero-Cross Trim & Loop (Fluent panel)
-- Trims item edges to the nearest zero crossings (click-free edits) and
-- builds seamless one-shot loops. Operates on every selected audio item.

local r = reaper




if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Zero-Cross Trim & Loop', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local dir = debug.getinfo(1, "S").source:match("^@?(.*[%/\\])") or ""
local lib = dofile(dir .. "bst_lib.lua")
local fl = dofile(dir .. "bst_fluent.lua")(ImGui)
-- All ReaScripts share one global Lua environment: this plain global is a
-- singleton lock, so launching the action twice doesn't spawn twin instances
-- (twins closing free each other's context and crash the surviving panel).
if BST_ZC_LIVE and ImGui.ValidatePtr(BST_ZC_LIVE, 'ImGui_Context*') then
  return -- panel already open
end
local ctx = ImGui.CreateContext('bst Zero-Cross')
BST_ZC_LIVE = ctx

local st = {
  window_ms    = lib.ext_getnum("zc_window_ms", 5),
  all_selected = lib.ext_getnum("zc_all", 1),
}
local msg, sev = "选中音频 item 后裁剪或做循环。", nil
local err = nil


local KIND_LABEL = {
  start = "Trim start",
  ["end"] = "Trim end",
  both = "Trim both edges",
  loop = "Make seamless loop",
}

local function set_num(key, v) st[key] = v; lib.ext_set(key, v) end

local function targets()
  local items = lib.selected_items()
  if #items == 0 then
    msg, sev = "没有选中的 item。", "warn"
    return nil
  end
  if st.all_selected >= 1 then return items end
  return { items[1] }
end

local function run(kind)
  local items = targets()
  if not items then return end
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local changed = 0
  for _, item in ipairs(items) do
    if kind == "loop" then
      lib.make_loop(item, st.window_ms / 1000)
      changed = changed + 1
    else
      if lib.trim_to_zero(item, kind, st.window_ms / 1000) then changed = changed + 1 end
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: %s (%d item(s))", KIND_LABEL[kind], changed), -1)
  msg, sev = string.format("%s —— 已调整 %d 个 item。", KIND_LABEL[kind], changed),
    changed > 0 and "ok" or "warn"
end

local function draw_body()
  fl.subtitle(ctx, "Zero-Cross Trim / Loop")
  ImGui.Spacing(ctx)

  local ch, v = ImGui.InputDouble(ctx, "Search window (ms)", st.window_ms, 1, 10, '%.0f')
  if ch then set_num("window_ms", math.max(1, v)) end
  local nv = fl.toggle(ctx, "Apply to all selected items (off = first only)",
    st.all_selected >= 1)
  if (nv and 1 or 0) ~= st.all_selected then set_num("all_selected", nv and 1 or 0) end

  ImGui.Dummy(ctx, 0, 4)
  fl.begin_card(ctx, "##card_zc")
    fl.caption(ctx, "编辑")
    if fl.button(ctx, "Trim start", { width = 130 }) then run("start") end
    ImGui.SameLine(ctx)
    if fl.button(ctx, "Trim end", { width = 110 }) then run("end") end
    ImGui.SameLine(ctx)
    if fl.button(ctx, "Trim both", { accent = true, width = 120 }) then run("both") end
    ImGui.Dummy(ctx, 0, 2)
    if fl.button(ctx, "Make seamless loop", { accent = true, width = 200 }) then run("loop") end
    fl.caption(ctx, "循环 = 两端零交叉对齐 + 开启 item 循环源")
  fl.end_card(ctx)

  local items = lib.selected_items()
  if #items > 0 then
    local take = r.GetActiveTake(items[1])
    local name = lib.take_name(take)
    ImGui.Dummy(ctx, 0, 4)
    fl.caption(ctx, string.format("第一个选中：%s  |  %.3f 秒",
      name ~= "" and name or "（未命名）",
      r.GetMediaItemInfo_Value(items[1], "D_LENGTH")))
  end

  if err then
    fl.infobar(ctx, "bad", "错误：" .. tostring(err))
  else
    fl.infobar(ctx, sev, msg)
  end
end

fl.attach_fonts(ctx)

local function loop()
  if not ctx or not ImGui.ValidatePtr(ctx, 'ImGui_Context*') then
    return -- stale instance from an older run; its context is gone
  end
  -- Whole frame protected: if the context dies mid-frame (a duplicate or
  -- stale instance was torn down), stop quietly instead of erroring forever.
  local okf, open = pcall(function()
    ImGui.SetNextWindowSize(ctx, 460, 380, ImGui.Cond_FirstUseEver)
    local nc, nv = fl.push_theme(ctx)
    local visible, op = ImGui.Begin(ctx, 'bst Zero-Cross Trim & Loop', true)
    if visible then
    local ok, e = pcall(draw_body)
    -- 不能写 `ok and nil or tostring(e)`：成功时会得到字符串 "nil"
    if ok then err = nil else err = tostring(e) end
    if not ok then
      r.ShowConsoleMsg("bst Zero-Cross Trim & Loop: " .. tostring(e) .. "\n")
      for _ = 1, 8 do if not pcall(ImGui.EndChild, ctx) then break end end
    end
    ImGui.End(ctx)
    end
    fl.pop_theme(ctx, nc, nv)
    return op
  end)
  if not okf or not open then
    if not okf then -- one-line diagnosis instead of a silent close
      r.ShowConsoleMsg("bst Zero-Cross Trim & Loop: frame aborted, closing (" .. tostring(open) .. ")\n")
    end
    if BST_ZC_LIVE == ctx then BST_ZC_LIVE = nil end
    -- no explicit DestroyContext: ReaImGui frees contexts when the script
    -- stops deferring; explicit destruction yanks the pointer from under any
    -- sibling instance on builds that still export it
    return
  end
  r.defer(loop)
end

r.defer(loop)
