-- bst: Render Blocks (LKC RenderBlocks 核心流程复刻 + 状态管理)
-- A "block" = an empty label item + content items, joined with REAPER's native
-- item grouping. Blocks render as one mixdown each (layered items inside a
-- block are summed). Workflow: PACK -> NAME -> RENDER -> iterate.
--
--  Pack            selection becomes one block (label spans the content extents)
--  Unpack          selected blocks: removes grouping + deletes the label item
--  Pack clusters   timeline-overlapping selected items become one block per cluster
--  Name/index/@gate    naming editor; @ gate exports only blocks whose name
--                      starts with '@' when enabled; index suffix per block order
--  Tail            绝对 ms 或 块长百分比 (相对 tail)
--  Render          one WAV per block via the shared silent renderer;
--                  渲染成功后标签写入 <RBST 状态行并变绿 (已渲染标记)
--  跳过已渲染      只渲染没有标记的块; 清除渲染标记可全部复位
--
-- 标签 P_NOTES 结构: 第一行 = 块名 (导出文件名), 其余行 = 状态寄存
--   "\n<RBST YYYYMMDD HH:MM>" = 已渲染标记 (改名会重置)

local r = reaper




if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Render Blocks', 0)
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
if BST_RB_LIVE and ImGui.ValidatePtr(BST_RB_LIVE, 'ImGui_Context*') then
  return -- panel already open
end
local ctx = ImGui.CreateContext('bst Render Blocks')
BST_RB_LIVE = ctx
local BLOCK_COLOR = r.ColorToNative(76, 194, 255) | 0x1000000
local RENDERED_COLOR = r.ColorToNative(102, 204, 128) | 0x1000000

local INDEX_MODES = { "_01", "_001", "(none)" }
local RBST_TAG = '<RBST '

local st = {
  name     = "",
  gate     = lib.ext_getnum("rb_gate", 1),
  index_i  = math.floor(lib.ext_getnum("rb_index", 1)),
  index_start = math.floor(lib.ext_getnum("rb_index_start", 1)),
  tail_ms  = lib.ext_getnum("rb_tail", 0),
  tail_mode = math.floor(lib.ext_getnum("rb_tail_mode", 1)), -- 1=绝对 ms, 2=块长 %
  tail_pct = lib.ext_getnum("rb_tail_pct", 10),
  skip_rendered = math.floor(lib.ext_getnum("rb_skip", 0)),
  render_dir   = lib.ext_get("render_dir", ""),
  fmt_i    = math.floor(lib.ext_getnum("render_fmt_i", 1)),
  sr_i     = math.floor(lib.ext_getnum("render_sr_i", 1)),
  mono     = lib.ext_getnum("render_mono", 0),
}
local FMT_CODES = { "ZXZhdxgB", "ZXZhdxAB", "evaw" }
local RATE_VALUES = { 0, 48000, 44100 }

local msg, sev = "选中 item 后打包成块。", nil
local err = nil
math.randomseed(os.time())

--------------------------------------------------------------------------------
-- block engine

local function is_label(item) return r.GetActiveTake(item) == nil end

-- 标签 notes: 第一行 = 块名, 后续 <RBST 行 = 状态寄存
local function block_name(item)
  local _, notes = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
  notes = notes or ""
  return (notes:match('^([^\n]*)') or ''), notes:find(RBST_TAG, 1, true) ~= nil
end

local function set_rendered(item, name)
  r.GetSetMediaItemInfo_String(item, "P_NOTES",
    name .. '\n' .. RBST_TAG .. os.date('%Y%m%d %H:%M'), true)
  r.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", RENDERED_COLOR)
end

local function clear_mark(item, name)
  r.GetSetMediaItemInfo_String(item, "P_NOTES", name, true)
  r.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", BLOCK_COLOR)
end

local function gid_of(item)
  return math.floor(r.GetMediaItemInfo_Value(item, "I_GROUPID") or 0)
end

local function members_of_group(gid)
  local t = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    if gid_of(it) == gid then t[#t + 1] = it end
  end
  return t
end

local function find_label(members)
  for _, it in ipairs(members) do
    if is_label(it) then return it end
  end
end

local function unique_gid()
  local gid = math.floor(os.time()) % 100000000 + math.random(1, 99999)
  while #members_of_group(gid) > 0 do gid = gid + 1 end
  return gid
end

local function extents(items)
  local pmin, pmax = math.huge, -math.huge
  for _, it in ipairs(items) do
    local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
    pmin = math.min(pmin, p)
    pmax = math.max(pmax, p + r.GetMediaItemInfo_Value(it, "D_LENGTH"))
  end
  return pmin, pmax
end


-- pack: selection -> one block. Returns gid or nil.
local function pack(items, name)
  if not items or #items == 0 then return nil end
  -- refuse if any item is already grouped
  for _, it in ipairs(items) do
    if gid_of(it) ~= 0 then msg, sev = "选中内容里已有分组的 item —— 请先解包。", "warn"; return nil end
  end
  local pmin, pmax = extents(items)
  local gid = unique_gid()
  local label = r.AddMediaItemToTrack(lib.item_track(items[1]))
  r.SetMediaItemInfo_Value(label, "D_POSITION", pmin)
  r.SetMediaItemInfo_Value(label, "D_LENGTH", pmax - pmin)
  r.SetMediaItemInfo_Value(label, "B_UISEL", 0)
  r.SetMediaItemInfo_Value(label, "I_CUSTOMCOLOR", BLOCK_COLOR)
  r.GetSetMediaItemInfo_String(label, "P_NOTES", name or ("block_" .. os.date("%H%M%S")), true)
  for _, it in ipairs(items) do
    r.SetMediaItemInfo_Value(it, "I_GROUPID", gid)
  end
  r.SetMediaItemInfo_Value(label, "I_GROUPID", gid)
  return gid
end

-- unpack every block touched by the selection; returns count
local function unpack_selected()
  local gids, seen = {}, {}
  for _, it in ipairs(lib.selected_items()) do
    local g = gid_of(it)
    if g ~= 0 and not seen[g] then seen[g] = true; gids[#gids + 1] = g end
  end
  local n = 0
  for _, g in ipairs(gids) do
    local members = members_of_group(g)
    for _, it in ipairs(members) do
      if is_label(it) then r.DeleteTrackMediaItem(r.GetMediaItem_Track(it), it) end
    end
    for _, it in ipairs(members) do
      if not is_label(it) then r.SetMediaItemInfo_Value(it, "I_GROUPID", 0) end
    end
    n = n + 1
  end
  return n
end

-- clusters: union-find over timeline overlap; returns array of item arrays
local function clusters(items)
  local arr = {}
  for _, it in ipairs(items) do
    local pos = r.GetMediaItemInfo_Value(it, "D_POSITION")
    arr[#arr + 1] = { it = it, pos = pos,
                      pend = pos + r.GetMediaItemInfo_Value(it, "D_LENGTH") }
  end
  table.sort(arr, function(a, b) return a.pos < b.pos end)
  local out, cur = {}, nil
  for _, e in ipairs(arr) do
    if cur and e.pos < cur.pend - 1e-9 then
      cur.items[#cur.items + 1] = e.it
      cur.pend = math.max(cur.pend, e.pend)
    else
      cur = { pend = e.pend, items = { e.it } }
      out[#out + 1] = cur
    end
  end
  local groups = {}
  for _, c in ipairs(out) do groups[#groups + 1] = c.items end
  return groups
end

-- collect target blocks: from selection, else from time selection.
-- returns array of { label=, members=, audio= } sorted by position.
local function target_blocks()
  local sel = lib.selected_items()
  local gids, seen = {}, {}
  local srcmode = (#sel > 0)
  local pool = sel
  if not srcmode then
    -- GetSet_LoopTimeRange returns (start, end) directly
    local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
    ts, te = ts or 0, te or 0
    if te - ts < 1e-6 then return nil, "请选中块，或框选一段时间。", "warn" end
    pool = {}
    for i = 0, r.CountMediaItems(0) - 1 do
      local it = r.GetMediaItem(0, i)
      local p = r.GetMediaItemInfo_Value(it, "D_POSITION")
      if p >= ts - 1e-9 and p <= te + 1e-9 then pool[#pool + 1] = it end
    end
  end
  for _, it in ipairs(pool) do
    local g = gid_of(it)
    if g ~= 0 and not seen[g] then seen[g] = true; gids[#gids + 1] = g end
  end
  local blocks = {}
  for _, g in ipairs(gids) do
    local members = members_of_group(g)
    local label = find_label(members)
    if label then
      local audio = {}
      for _, it in ipairs(members) do
        if not is_label(it) then audio[#audio + 1] = it end
      end
      blocks[#blocks + 1] = { label = label, members = members, audio = audio,
                              pos = r.GetMediaItemInfo_Value(label, "D_POSITION") }
    end
  end
  table.sort(blocks, function(a, b) return a.pos < b.pos end)
  if #blocks == 0 then return nil, "没有找到已打包的块（请先打包）。", "warn" end
  return blocks
end

-- 全工程的块标签 (清除渲染标记用)
local function all_labels()
  local t = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local it = r.GetMediaItem(0, i)
    if is_label(it) and gid_of(it) ~= 0 then t[#t + 1] = it end
  end
  return t
end

local function first_selected_block()
  for _, it in ipairs(lib.selected_items()) do
    local g = gid_of(it)
    if g ~= 0 then
      local label = find_label(members_of_group(g))
      if label then return label end
    end
  end
end

--------------------------------------------------------------------------------
-- actions

local function act_pack()
  r.Undo_BeginBlock(); r.PreventUIRefresh(1)
  local sel = lib.selected_items()
  local gid = pack(sel)
  r.PreventUIRefresh(-1); r.UpdateArrange()
  if gid then
    r.Undo_EndBlock("bst: Pack block", -1)
    msg, sev = "已把 " .. #sel .. " 个 item 打包成一个块。", "ok"
  else
    r.Undo_EndBlock("bst: Pack block (nothing)", -1)
    if #sel == 0 then msg, sev = "请先选中要打包的 item。", "warn" end
  end
end

local function act_clusters()
  r.Undo_BeginBlock(); r.PreventUIRefresh(1)
  local groups = clusters(lib.selected_items())
  local made = 0
  for _, grp in ipairs(groups) do
    if pack(grp) then made = made + 1 end
  end
  r.PreventUIRefresh(-1); r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Pack %d cluster(s)", made), -1)
  msg, sev = string.format("已打包 %d 个簇。", made), made > 0 and "ok" or "warn"
end

local function act_unpack()
  r.Undo_BeginBlock(); r.PreventUIRefresh(1)
  local n = unpack_selected()
  r.PreventUIRefresh(-1); r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: Unpack %d block(s)", n), -1)
  msg, sev = string.format("已解包 %d 个块。", n), n > 0 and "ok" or "warn"
end

local function act_apply_name()
  local label = first_selected_block()
  if not label then msg, sev = "请选中块内的 item。", "warn"; return end
  r.Undo_BeginBlock()
  -- 改名即重置状态寄存 (第一行才是块名)
  r.GetSetMediaItemInfo_String(label, "P_NOTES", st.name, true)
  r.SetMediaItemInfo_Value(label, "I_CUSTOMCOLOR", BLOCK_COLOR)
  r.Undo_EndBlock("bst: Rename block", -1)
  msg, sev = "块已命名为「" .. st.name .. "」。", "ok"
end

local function act_clear_marks()
  r.Undo_BeginBlock(); r.PreventUIRefresh(1)
  local n = 0
  for _, lb in ipairs(all_labels()) do
    local name, rendered = block_name(lb)
    if rendered then clear_mark(lb, name) n = n + 1 end
  end
  r.PreventUIRefresh(-1); r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: 清除 %d 个渲染标记", n), -1)
  msg, sev = string.format("已清除 %d 个渲染标记。", n), "ok"
end

local function choose_folder()
  local ok, d = r.GetUserFileName(3, "Choose render output folder", st.render_dir, "")
  if ok and d and d ~= "" then
    st.render_dir = d:gsub("[%/\\]+$", "")
    lib.ext_set("render_dir", st.render_dir)
  end
end

local function act_render()
  if st.render_dir == "" then msg, sev = "请先选择输出目录。", "warn"; return end
  local blocks, m, s = target_blocks()
  if not blocks then msg, sev = m, s; return end

  -- @ gate + naming + 跳过已渲染
  local exported, skipped_gate, skipped_done = {}, 0, 0
  for _, b in ipairs(blocks) do
    local nm, rendered = block_name(b.label)
    nm = nm or ""
    if st.gate >= 1 and nm:sub(1, 1) ~= "@" then
      skipped_gate = skipped_gate + 1
    elseif st.skip_rendered >= 1 and rendered then
      skipped_done = skipped_done + 1
    elseif b.audio and #b.audio > 0 then
      b.name = (st.gate >= 1) and nm:sub(2) or nm
      exported[#exported + 1] = b
    end
  end
  if #exported == 0 then
    msg, sev = "没有可导出的内容（@ 门/已渲染过滤掉了所有块？）。", "warn"
    return
  end

  local out_dir = st.render_dir:gsub("[%/\\]+$", "") .. "/"
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  for bi, b in ipairs(exported) do
    local num = bi - 1 + math.max(0, st.index_start)
    local suffix = ""
    if st.index_i == 1 then suffix = string.format("_%02d", num)
    elseif st.index_i == 2 then suffix = string.format("_%03d", num) end
    local fname = lib.sanitize(b.name ~= "" and b.name or ("block_" .. bi)) .. suffix
    -- tail: 绝对 ms 或 块长百分比
    local _, pmaxb = extents(b.audio)
    local block_len = math.max(pmaxb - b.pos, 0.01)
    local tail_ms = st.tail_ms
    if st.tail_mode == 2 then
      tail_ms = math.floor(st.tail_pct / 100 * block_len * 1000 + 0.5)
    end
    -- one MIXDOWN per block: item-mode renders would write one file per item
    lib.render_block_mixdown(b.audio, out_dir, {
      pattern    = fname,
      format     = FMT_CODES[st.fmt_i] or "evaw",
      srate      = RATE_VALUES[st.sr_i] or 0,
      mono       = st.mono >= 1,
      tail_ms    = math.max(tail_ms, 0),
    })
    -- 渲染成功 → 状态寄存 + 已渲染标记 (绿)
    set_rendered(b.label, b.name)
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(string.format("bst: 渲染 %d 个块", #exported), -1)
  msg, sev = string.format("已渲染 %d 个块 → %s（@ 门滤掉 %d，已渲染跳过 %d）",
    #exported, out_dir, skipped_gate, skipped_done), "ok"
end

--------------------------------------------------------------------------------
local function draw_body()
  fl.subtitle(ctx, "Render Blocks")
  ImGui.Spacing(ctx)

  fl.begin_card(ctx, "##card_rb")
    fl.caption(ctx, "块")
    if fl.button(ctx, "Pack", { accent = true, width = 90 }) then act_pack() end
    ImGui.SameLine(ctx)
    if fl.button(ctx, "Unpack", { width = 90 }) then act_unpack() end
    ImGui.SameLine(ctx)
    if fl.button(ctx, "Pack clusters", { width = 110 }) then act_clusters() end
    fl.caption(ctx, "标签 = 覆盖整组的空 item；随时改名 / 重新打包")
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 2)
  fl.begin_card(ctx, "##card_name")
    fl.caption(ctx, "命名")
    local ch, v = ImGui.InputTextWithHint(ctx, "##rbname", "block name...", st.name)
    if ch then st.name = v end
    -- ReaImGui Combo takes a NUL-terminated item string and a 0-BASED index
    ch, v = ImGui.Combo(ctx, "Index##rbi", st.index_i - 1,
      table.concat(INDEX_MODES, "\0") .. "\0")
    if ch then st.index_i = math.floor(v) + 1; lib.ext_set("rb_index", st.index_i) end
    ch, v = ImGui.InputInt(ctx, "Start##rbs", st.index_start)
    if ch then
      st.index_start = math.max(0, math.floor(v))
      lib.ext_set("rb_index_start", st.index_start)
    end
    fl.caption(ctx, "序号 = 导出顺序累加; Index 选 (none) 则文件名不加序号")
    local nv = fl.toggle(ctx, "@ gate (only export names starting with @)",
      st.gate >= 1)
    if (nv and 1 or 0) ~= st.gate then st.gate = nv and 1 or 0; lib.ext_set("rb_gate", st.gate) end
    nv = fl.toggle(ctx, "只渲染未标记的块 (跳过绿标签)", st.skip_rendered >= 1)
    if (nv and 1 or 0) ~= st.skip_rendered then
      st.skip_rendered = nv and 1 or 0
      lib.ext_set("rb_skip", st.skip_rendered)
    end
    if fl.button(ctx, "Apply name to first selected block", { width = 240 }) then
      act_apply_name()
    end
    fl.caption(ctx, "渲染过的块标签变绿并写入 <RBST 状态; 改名会重置标记")
    if fl.button(ctx, "清除全部渲染标记", { subtle = true, width = 200 }) then
      act_clear_marks()
    end
  fl.end_card(ctx)

  ImGui.Dummy(ctx, 0, 2)
  fl.begin_card(ctx, "##card_render")
    fl.caption(ctx, "渲染")
    fl.caption(ctx, "目录：" .. (st.render_dir ~= "" and st.render_dir or "（未设置）"))
    if fl.button(ctx, "选择目录...", { width = 130 }) then choose_folder() end
    ImGui.SameLine(ctx)
    if fl.button(ctx, "格式跟随工具箱", { subtle = true }) then
      msg, sev = "格式与采样率跟随 SD Toolbox 渲染页的设置。", nil
    end
    ch, v = ImGui.Combo(ctx, "尾部类型##rbtm", st.tail_mode - 1, "绝对 ms\0块长 %\0")
    if ch then
      st.tail_mode = math.floor(v) + 1
      lib.ext_set("rb_tail_mode", st.tail_mode)
    end
    if st.tail_mode == 2 then
      ch, v = ImGui.InputDouble(ctx, "尾部 (%)##rbtp", st.tail_pct, 5, 25, '%.0f')
      if ch and v >= 0 then
        st.tail_pct = math.floor(v)
        lib.ext_set("rb_tail_pct", st.tail_pct)
      end
    else
      ch, v = ImGui.InputDouble(ctx, "Tail (ms)##rbt", st.tail_ms, 50, 500, '%.0f')
      if ch and v >= 0 then
        st.tail_ms = math.floor(v)
        lib.ext_set("rb_tail", st.tail_ms)
        lib.ext_set("render_tail_ms", st.tail_ms)
      end
    end
    if fl.button(ctx, "RENDER BLOCKS", { accent = true, width = 200, height = 32 }) then
      act_render()
    end
    fl.caption(ctx, "每块一个混音文件 —— 块内分层 item 相加，经总线渲染")
  fl.end_card(ctx)

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
    ImGui.SetNextWindowSize(ctx, 480, 600, ImGui.Cond_FirstUseEver)
    local nc, nv = fl.push_theme(ctx)
    local visible, op = ImGui.Begin(ctx, 'bst Render Blocks', true)
    if visible then
    local ok, e = pcall(draw_body)
    -- 不能写 `ok and nil or tostring(e)`：成功时会得到字符串 "nil"
    if ok then err = nil else err = tostring(e) end
    if not ok then
      r.ShowConsoleMsg("bst Render Blocks: " .. tostring(e) .. "\n")
      for _ = 1, 8 do if not pcall(ImGui.EndChild, ctx) then break end end
    end
    ImGui.End(ctx)
    end
    fl.pop_theme(ctx, nc, nv)
    return op
  end)
  if not okf or not open then
    if not okf then -- one-line diagnosis instead of a silent close
      r.ShowConsoleMsg("bst Render Blocks: frame aborted, closing (" .. tostring(open) .. ")\n")
    end
    if BST_RB_LIVE == ctx then BST_RB_LIVE = nil end
    -- no explicit DestroyContext: ReaImGui frees contexts when the script
    -- stops deferring; explicit destruction yanks the pointer from under any
    -- sibling instance on builds that still export it
    return
  end
  r.defer(loop)
end

r.defer(loop)
