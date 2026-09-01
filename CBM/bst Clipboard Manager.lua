--[[
  bst Clipboard Manager for REAPER — Fluent 版剪贴板侧边栏
  =====================================================================
  由 Clipboard Manager.lua 重构: UI 层整体迁移到 Fluent 2 设计系统
  (Scripts/OxTools/ox_fluent.lua), 业务逻辑(捕获/粘贴/切片/IPC/剪贴板
  监视)与存储格式(entries.lua / ExtState CBM·CBM_UI)完全兼容旧版。

  本版 UI/交互改进:
    · Fluent 主题(ox_fluent push_theme) + Segoe Fluent Icons 图标字体
    · 工具栏: 搜索框(hint) + [捕获]主按钮 + 设置/清空; 清空需二次确认
    · 类型筛选 chips: 全部/音频/视图/MIDI/轨道/标记/包络 一键过滤
    · 条目卡片化(fl.begin_card): 徽章+标题+相对时间+预览+操作行
    · 操作反馈 toast(infobar): 捕获/粘贴/清空等结果直接浮出提示,
      不再只写 ReaConsole
    · 空状态引导 + 底部状态条(SWS/ffmpeg 状态点)
    · 标题按像素宽度截断(utf8 安全), 不再按字符数硬切

  功能与依赖同旧版: 必须 ReaImGui(>=0.10); 可选 SWS(拖出落点)、
  ffmpeg(视频/GIF/图片缩略图)。动作子脚本(bst Capture Items.lua 等)
  通过全局 CBM_CMD/CBM_ARGS + dofile 本文件分发, 协议不变。
--------------------------------------------------------------------- ]]

local r = reaper

-- ============================ 调试开关 ============================
-- 控制台输出开关: true=打印 [CBM] 日志到 ReaConsole, false=静默
local DEBUG = false
local function log(...)
  if DEBUG then reaper.ShowConsoleMsg(...) end
end

-- 前置声明: 函数体在文件后半部分定义, 这里先声明为局部以形成正确的上值引用
local probe_video, FONT, FONT_OK, ptr_ok, load_font

-- ============================ 路径 & 基础工具 ============================

local RES     = r.GetResourcePath()
local CBM_DIR = RES .. '/CBM'
local IPC_DIR = CBM_DIR .. '/ipc'
local CACHE   = CBM_DIR .. '/cache'
local ENTRIES = CBM_DIR .. '/entries.lua'
r.RecursiveCreateDirectory(IPC_DIR, 0)
r.RecursiveCreateDirectory(CACHE, 0)

local function file_exists(p) local f = io.open(p, 'r') if f then f:close() return true end end
local function read_file(p)   local f = io.open(p, 'rb') if not f then return nil end local s = f:read('*a') f:close() return s end
local function write_file(p, s) local f = io.open(p, 'wb') if not f then return false end f:write(s) f:close() return true end
local function file_size(p)   local f = io.open(p, 'rb') if not f then return 0 end local n = f:seek('end') f:close() return n or 0 end

-- 受保护调用: 成功返回前若干返回值, 失败返回 nil (静默)
local function pc(fn, ...)
  local ok, a, b, c, d, e, f, g = pcall(fn, ...)
  if ok then return a, b, c, d, e, f, g end
end

-- ---------- 序列化 (entries.lua 持久化) ----------

local function esc_long(s)
  local lvl = 0
  while s:find(']' .. ('='):rep(lvl) .. ']') do lvl = lvl + 1 end
  return '[' .. ('='):rep(lvl) .. '[' .. s .. ']' .. ('='):rep(lvl) .. ']'
end

local function ser(v)
  local t = type(v)
  if t == 'string'  then return esc_long(v) end
  if t == 'number'  then return string.format('%.17g', v) end
  if t == 'boolean' then return tostring(v) end
  if t ~= 'table'   then return 'nil' end
  local n = 0 for _ in pairs(v) do n = n + 1 end
  local parts = {}
  if #v == n and n > 0 then
    for i = 1, n do parts[i] = ser(v[i]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  for k, val in pairs(v) do parts[#parts+1] = tostring(k) .. '=' .. ser(val) end
  return '{' .. table.concat(parts, ',') .. '}'
end

local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 0x1000000000000000 end
  h = math.tointeger(h) or 0
  return string.format('%012x', h)
end

local function fmt_t(sec)
  sec = math.max(tonumber(sec) or 0, 0)
  local m = math.floor(sec / 60) local s = sec - m * 60
  local h = math.floor(m / 60) m = m - h * 60
  if h > 0 then return string.format('%d:%02d:%06.3f', h, m, s) end
  return string.format('%d:%06.3f', m, s)
end

local function ago(ts)
  local d = os.time() - (ts or os.time())
  if d < 60 then return d .. '秒前' end
  if d < 3600 then return math.floor(d / 60) .. '分钟前' end
  if d < 86400 then return math.floor(d / 3600) .. '小时前' end
  return math.floor(d / 86400) .. '天前'
end

local function basename(p) return (p:gsub('[^\\/]*[\\/]', '')) end
local function ext_of(p)   return (basename(p):match('%.(%w+)$') or ''):lower() end

local AUDIO_EXT = { wav=1, mp3=1, flac=1, ogg=1, oga=1, aif=1, aiff=1, aifc=1,
                    w64=1, opus=1, m4a=1, ape=1, wv=1, caf=1 }
local VIDEO_EXT = { mp4=1, mov=1, mkv=1, avi=1, webm=1, mpeg=1, mpg=1, m2v=1,
                    mts=1, m2ts=1, flv=1, vob=1, gif=1 }
local IMAGE_EXT = { png=1, jpg=1, jpeg=1, bmp=1, webp=1, tif=1, tiff=1, tga=1 }

local function class_of(ext)
  if AUDIO_EXT[ext] then return 'audio' end
  if VIDEO_EXT[ext] then return 'video' end
  if IMAGE_EXT[ext] then return 'image' end
  return nil
end

-- ============================ stub 命令分发 ============================
-- 子脚本 (bst Capture Items.lua 等) 通过 dofile 本文件 + 全局 CBM_CMD/CBM_ARGS 调用;
-- 这里在加载 ReaImGui 之前处理, 让 stub 不需要 ReaImGui 也能发送命令。

local function ipc_request(cmd, args)
  for i = 0, 15 do
    local p = IPC_DIR .. '/req_' .. i .. '.json'
    if not file_exists(p) then
      local lines = { 'CMD ' .. tostring(cmd) }
      if type(args) == 'table' then
        for k, v in pairs(args) do lines[#lines+1] = 'ARG ' .. tostring(k) .. ' ' .. tostring(v) end
      end
      if write_file(p, table.concat(lines, '\n') .. '\n') then return i end
      return nil
    end
  end
end

if CBM_CMD then
  local cmd = CBM_CMD
  if cmd == 'toggle' then
    local hb = tonumber(r.GetExtState('CBM', 'hb') or '0') or 0
    if os.time() - hb <= 4 then
      local cur = r.GetExtState('CBM', 'visible')
      r.SetExtState('CBM', 'visible', cur == '1' and '0' or '1', false)
    else
      local main = tonumber(r.GetExtState('CBM', 'main_cmd') or '0') or 0
      if main > 0 then
        r.Main_OnCommand(main, 0)
      else
        r.MB('Clipboard Manager 未运行。\n请先在动作列表加载运行一次 bst Clipboard Manager.lua', 'bst Clipboard Manager', 0)
      end
    end
  else
    local hb = tonumber(r.GetExtState('CBM', 'hb') or '0') or 0
    if os.time() - hb > 4 then
      r.MB('Clipboard Manager 未运行。\n请先启动侧边栏主脚本。', 'bst Clipboard Manager', 0)
      return
    end
    local slot = ipc_request(cmd, CBM_ARGS)
    if not slot then r.MB('IPC 槽位已满, 请重试', 'bst Clipboard Manager', 0) return end
    local t0, path = os.clock(), IPC_DIR .. '/resp_' .. slot .. '.json'
    local function wait()
      local s = read_file(path)
      if s then
        os.remove(path)
        log('[CBM] ' .. s .. '\n')
        return
      end
      if os.clock() - t0 > 8 then r.MB('等待主脚本响应超时', 'bst Clipboard Manager', 0) return end
      r.defer(wait)
    end
    r.defer(wait)
  end
  return
end
-- ============================ ReaImGui + Fluent 加载 ============================

local imgui



if not r.ImGui_GetBuiltinPath then
  r.MB('本脚本需要 ReaImGui 扩展 (v0.10+)：\n1. 菜单 Extensions → ReaPack → Browse packages\n2. 搜索 "reaimgui"（作者 cfillion）→ Install\n3. 重启 REAPER 后再运行本脚本。', 'bst Clipboard Manager', 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. '/?.lua'
imgui = require 'imgui' '0.10'   -- 必须顶层直接执行(不可 pcall 包裹), 否则 shim 初始化上下文错误
if type(imgui) ~= 'table' then
  imgui = r.ImGui  -- 旧版回退
end
if type(imgui) ~= 'table' then
  r.MB('需要 ReaImGui 扩展 (v0.10+): Extensions → ReaPack → 搜索 ReaImGui → 安装并重启 REAPER', 'bst Clipboard Manager', 0)
  return
end

-- Fluent 2 设计系统 (bst_fluent): 本面板所有 UI 颜色/圆角/间距 token 均来自这里,
-- 不再手绘调色板。缺失时给出明确指引后退出。
-- 库定位: 优先本目录, 其次 Scripts/bst/, 兼容旧位置 Scripts/OxTools/
local OX_FLUENT
do
  local selfdir = ((debug.getinfo(1, 'S').source or ''):match('^@(.*)[/\\]')) or ''
  local cands = {
    selfdir .. '/bst_fluent.lua',
    RES .. '/Scripts/bst/bst_fluent.lua',
    RES .. '/Scripts/OxTools/bst_fluent.lua',
    RES .. '/Scripts/OxTools/ox_fluent.lua',
  }
  for _, cand in ipairs(cands) do
    if file_exists(cand) then OX_FLUENT = cand break end
  end
end
if not OX_FLUENT then
  r.MB('找不到 Fluent 库 (bst_fluent.lua):\n请确认 Scripts/bst/ 目录存在。', 'bst Clipboard Manager', 0)
  return
end
local fl = dofile(OX_FLUENT)(imgui)
fl.set_theme('dark')

-- ctx 的生存周期由 ReaImGui 管理: 当脚本被 REAPER 重新运行时, 旧实例的 ctx 会被
-- ReaImGui 销毁, 而旧 defer 循环仍持有已失效的 ctx 指针 → 每帧报
-- "expected a valid ImGui_Context*" 并导致黑屏/波形不绘制。这里:
--   1) 用 name 单例 + 每次创建后缓存;
--   2) 每帧用 ValidatePtr 校验, 失效则透明重建, 避免向用户喷错;
--   3) 正常退出时 pc 包装释放 (部分构建不导出 DestroyContext)。
local ctx = nil

local function create_context()
  if imgui.CreateContext then
    local ok, c = pcall(imgui.CreateContext, 'bst Clipboard Manager')
    if ok and c then return c end
  end
  return nil
end

local function ensure_context()
  -- 校验当前 ctx 是否仍有效 (被 ReaImGui 回收后 userdata 指针失效);
  -- 失效则透明重建并更新上值 ctx, 使整帧后续 ctx 引用都指向新上下文。
  if ctx then
    if not imgui.ValidatePtr or imgui.ValidatePtr(ctx, 'ImGui_Context*') then
      return ctx
    end
  end
  ctx = create_context()
  -- ctx 重建后需重新挂载字体 (旧 ctx 上挂的字体已随其销毁)
  if ctx and load_font and not (FONT and ptr_ok(FONT, 'ImGui_Font*')) then
    FONT, FONT_OK = load_font()
    fl.icon_font = nil
    fl.attach_fonts(ctx)
    fl.set_ui_font(FONT)
  end
  return ctx
end

ctx = create_context()
log(('[CBM] ctx: %s\n'):format(ctx and tostring(ctx) or 'nil'))

local HAS_SWS = r.BR_GetMouseCursorContext ~= nil

-- ============================ 调色板 (Fluent tokens) ============================
-- UI chrome 全部取自 ox_fluent 的 dark 主题 token;
-- 下面只补充两类数据可视化色 (波形双声道 / 类型徽章分类色), 属于图表配色,
-- Fluent token 集未覆盖。

local T = fl.dark

local function with_alpha(hex32, a8)
  return (hex32 & 0xFFFFFF00) | (a8 & 0xFF)
end

local PAL = {
  -- 背景分层
  bg      = T.bg,
  card    = T.card,
  -- 预览区数据可视化配色 —— MiniMeters 风: 近黑微蓝底, 单一柔和蓝系,
  -- 波形 = 峰值剪影(低透明) + RMS 内芯(高亮) 分层; 面板不再出现蓝紫撞色
  bg2     = 0x12151BFF,
  field   = T.ctrl,

  -- 边框/分隔线
  border  = T.stroke,
  border_h= T.stroke_strong,
  grid    = 0xFFFFFF12,
  grid_h  = T.stroke_strong,

  -- 主强调色
  accent  = T.accent,
  accent_d= with_alpha(T.accent, 0x90),
  wave_peak = 0x4CC2FF5E,  -- 波形峰值剪影 (accent 半透明填充)
  wave_rms  = 0x93DCFFEE,  -- 波形 RMS 内芯 (同色系高亮)
  wave      = 0x74D2FFD8,  -- 主波色 (MIDI 音符/包络线共用)
  wave2     = 0x5E7A8CB4,  -- 次级元素 (未选中音符): 灰蓝, 去紫
  wave_dim  = 0x74D2FF80,  -- 切片虚线等次级提示

  -- 选区 (中性白, 低透明度底 + 实线边)
  sel     = 0xFFFFFF20,
  selb    = 0xE9EFF5C0,

  -- 文本层级
  txt     = T.text_pri,
  txt2    = T.text_sec,
  txt3    = T.text_dis,

  -- 语义色
  red     = T.bad,
  green   = T.ok,
  orange  = 0xFFB36BFF,  -- 数据可视化补色 (包络)
  violet  = 0xB9A0FBFF,
  ink     = 0x1F1F1FFF,  -- 徽章上的深色文字
}

local KIND_LABEL = { item='音频', video='视频', image='图片', midi='MIDI', proj='工程',
                     empty='空', notes='MIDI', track='轨道', marker='标记', envelope='包络',
                     fxchain='FX链' }
-- 类型徽章分类色 (图表配色扩展, 基于 Fluent accent/warn/ok 系)
local KIND_COLOR = {
  item     = 0x4CC2FFFF,  -- 蓝 (音频)
  video    = 0xCEB9FFFF,  -- 淡紫 (视频)
  image    = 0x8AE0E8FF,  -- 青 (图片)
  midi     = 0x86D78AFF,  -- 绿 (MIDI 源)
  proj     = 0xB9A0FBFF,  -- 紫灰 (工程引用)
  empty    = 0xA8B2BCFF,  -- 灰 (空 item)
  notes    = 0x86D78AFF,  -- 绿 (MIDI)
  track    = 0x76D7ADFF,  -- 薄荷 (轨道)
  marker   = T.warn,      -- 黄 (标记)
  envelope = 0xFFB36BFF,  -- 橙 (包络)
  fxchain  = 0xB9A0FBFF,  -- 紫灰 (FX 链)
}

-- ============================ 状态 & 持久化 ============================

local S = {
  entries = {}, next_id = 1, dirty = false, last_save = 0,
  visible = true, quit = false, drag = nil, wave_drag = nil, filter = '',
  kind_filter = 'all',
  boards = { { id = 'global', name = '通用', entries = {} } },
  active_board = 'global',
  search_hist = {},
  renaming = nil, renaming_name = nil,
  confirm_clear_until = 0,
  toast = nil,          -- { sev='ok'|'info'|'warn'|'bad', text='', exp=os.clock() }
  last_clip_key = nil, last_clip_poll = 0,
  set = { cap = 64, slice_mode = 'off', slice_fixed = 4, slice_thresh = 0.5, ffmpeg = '' },
  pv = {},  -- id -> { src, peaks, imgs, tex, thumb_key }
}
-- entries 即当前面板的 entries 表 (切换面板 = 重新绑定别名)
S.boards[1].entries = S.entries

local function set_toast(sev, text, secs)
  S.toast = { sev = sev, text = tostring(text or ''), exp = os.clock() + (secs or 2.5) }
end

local function set_load()
  local s = r.GetExtState('CBM', 'settings') or ''
  for k, v in s:gmatch('(%w+)=([^;\n]*)') do
    if k == 'cap' or k == 'slice_fixed' then S.set[k] = tonumber(v) or S.set[k]
    elseif k == 'slice_thresh' then S.set[k] = tonumber(v) or S.set[k]
    elseif k == 'slice_mode' or k == 'ffmpeg' then S.set[k] = v end
  end
end

local function set_save()
  local t = {}
  for k, v in pairs(S.set) do t[#t+1] = k .. '=' .. tostring(v) end
  r.SetExtState('CBM', 'settings', table.concat(t, ';'), true)
end
set_load()

-- ============================ 多面板 (boards) ============================
-- 通用面板全局共享; 「📁 本项目」按工程自动分板; 自定义面板按用途建。
-- 复制/捕获永远进入当前激活面板; 切换面板后 S.entries 重新绑定。

local function get_board(id)
  for _, b in ipairs(S.boards) do if b.id == id then return b end end
end

local function project_key()
  local _, fn = r.EnumProjects(-1)
  if fn and fn ~= '' then return fn end
  return 'unsaved'
end

local function project_name()
  local _, fn = r.EnumProjects(-1)
  if fn and fn ~= '' then return basename(fn) end
  return '未保存工程'
end

local function switch_board(id)
  local b = get_board(id)
  if not b or id == S.active_board then return end
  S.active_board = id
  S.entries = b.entries
  S.dirty = true
  set_toast('info', '已切换到面板「' .. b.name .. '」(' .. #b.entries .. ' 条)', 1.6)
end

local function ensure_board(id, name)
  local b = get_board(id)
  if not b then
    b = { id = id, name = name or id, entries = {} }
    S.boards[#S.boards+1] = b
    S.dirty = true
  end
  return b
end

-- 「本项目」模式: 面板跟随当前工程 (每工程一份独立历史)
local function sync_proj_board()
  if S.active_board:sub(1, 5) ~= 'proj:' then return end
  local want = 'proj:' .. project_key()
  local b = get_board(want)
  if not b then b = ensure_board(want, '📁 ' .. project_name()) end
  if S.active_board ~= want then
    S.active_board = want
    S.entries = b.entries
  end
end

-- ============================ 搜索 (通配符 + 记忆) ============================
local function wildcard_match(s, q)
  if q == '' then return true end
  if not q:find('%*') and not q:find('%?') then return s:find(q, 1, true) ~= nil end
  -- * = 任意一串, ? = 单个字符, 其余按字面
  local p = q:gsub('[%^%$%(%)%%%.%[%]%+%-%]', '%%%1')
  p = p:gsub('%%%*', '.*'):gsub('%%%?', '.')
  return s:match('^' .. p .. '$') ~= nil
end

local function hist_load()
  S.search_hist = {}
  local raw = r.GetExtState('CBM', 'search_hist') or ''
  for term in raw:gmatch('[^\n]+') do S.search_hist[#S.search_hist+1] = term end
end

local function hist_add(term)
  if not term or term == '' then return end
  for i, v in ipairs(S.search_hist) do
    if v == term then table.remove(S.search_hist, i) break end
  end
  table.insert(S.search_hist, 1, term)
  while #S.search_hist > 12 do table.remove(S.search_hist) end
  local parts = {}
  for _, v in ipairs(S.search_hist) do parts[#parts+1] = v end
  r.SetExtState('CBM', 'search_hist', table.concat(parts, '\n'), true)
end

hist_load()

-- UI 设置 (拖出落点/窗口尺寸), 由 bst Settings.lua 面板写入, 主脚本读取
S.ui = { drop_mode = 'cursor', win_w = 440, win_h = 800 }
local ui_raw = r.GetExtState('CBM_UI', 'ui') or ''
for k, v in ui_raw:gmatch('(%w+)=([^;\n]*)') do
  if k == 'win_w' or k == 'win_h' then S.ui[k] = tonumber(v) or S.ui[k]
  elseif k == 'drop_mode' then S.ui[k] = v end
end

local function entry_key(e)
  -- 内容指纹: 同一对象重复复制/捕获时用于去重
  -- chunk 类条目直接哈希整块 (FX 链/轨道/包络), 其余按内容字段
  if e.chunk and (e.kind == 'fxchain' or e.kind == 'track' or e.kind == 'envelope') then
    return e.kind .. '|' .. hash(e.chunk)
  end
  local extra = ''
  if e.kind == 'marker' then extra = #e.marks .. '|' .. (e.marks[1] and e.marks[1].pos or '')
  elseif e.kind == 'envelope' then extra = #e.points .. '|' .. (e.points[1] and e.points[1].t or '')
  elseif e.kind == 'notes' then extra = e.nnotes or #e.notes or 0 end
  return table.concat({ e.kind or '', e.file or e.title or '', e.stype or '',
                        e.soffs or '', e.len or '', e.pitch or '', extra }, '|')
end

local function add_entry(e)
  if not e then return nil end
  if e.key == nil then e.key = entry_key(e) end
  -- 去重: 已有同内容条目 → 销毁其预览资源并移除, 新条目置顶 (时间刷新)
  for i = #S.entries, 1, -1 do
    local old = S.entries[i]
    if old.key == e.key then
      if S.pv[old.id] and S.pv[old.id].src then pc(r.PCM_Source_Destroy, S.pv[old.id].src) end
      S.pv[old.id] = nil
      table.remove(S.entries, i)
    end
  end
  e.id = S.next_id S.next_id = S.next_id + 1
  e.time = os.time()
  if e.kind == 'item' and not e.win then
    if e.is_midi then e.win = { a = 0, b = e.len or 1 }
    elseif e.soffs then e.win = { a = e.soffs, b = e.soffs + e.len * (e.rate or 1) }
    elseif e.src_len then e.win = { a = 0, b = e.src_len } end
  end
  table.insert(S.entries, 1, e)
  while #S.entries > (S.set.cap or 64) do
    local old = table.remove(S.entries)
    if S.pv[old.id] and S.pv[old.id].src then pc(r.PCM_Source_Destroy, S.pv[old.id].src) end
    S.pv[old.id] = nil
  end
  S.dirty = true
  return e
end

local function find_entry(id)
  if id == 'last' or id == nil then return S.entries[1] end
  id = tonumber(id)
  for _, e in ipairs(S.entries) do if e.id == id then return e end end
end

local function remove_entry(id)
  for i, e in ipairs(S.entries) do
    if e.id == id then
      if S.pv[id] and S.pv[id].src then pc(r.PCM_Source_Destroy, S.pv[id].src) end
      S.pv[id] = nil
      table.remove(S.entries, i) S.dirty = true return
    end
  end
end

local function entry_save()
  local t = { next_id = S.next_id, active = S.active_board, boards = {} }
  for _, b in ipairs(S.boards) do
    t.boards[#t.boards+1] = { id = b.id, name = b.name, entries = b.entries }
  end
  write_file(ENTRIES, 'return ' .. ser(t) .. '\n')
end

local function entry_load()
  local f = loadfile(ENTRIES)
  if not f then return end
  local ok, t = pcall(f)
  if not ok or type(t) ~= 'table' then return end
  -- 过滤旧版本遗留/已移除的类型 (text、files 不再支持): 只保留 REAPER 内部对象
  local keep = {}
  local dropped = 0
  for _, e in ipairs(t.entries or {}) do
    if e.kind == 'item' or e.kind == 'track' or e.kind == 'marker'
       or e.kind == 'notes' or e.kind == 'envelope' or e.kind == 'fxchain' then
      -- 旧版本/外部数据防御: 补齐缺字段, 避免渲染/粘贴期 nil 拼接或格式化报错
      if e.kind == 'track' and type(e.d) == 'table' then
        e.d.name = tostring(e.d.name or '')
        e.d.vol = tonumber(e.d.vol) or 1
        e.d.pan = tonumber(e.d.pan) or 0
        e.d.sends = tonumber(e.d.sends) or 0
        e.d.recvs = tonumber(e.d.recvs) or 0
        e.d.nchan = tonumber(e.d.nchan) or 2
        if type(e.d.fx) == 'table' then
          for fi, fx in ipairs(e.d.fx) do
            if type(fx) == 'table' then
              fx.name = tostring(fx.name or ('FX' .. (fi - 1)))
              fx.preset = tostring(fx.preset or '')
              if fx.on == nil then fx.on = true end
            end
          end
        else
          e.d.fx = {}
        end
      end
      if e.kind == 'envelope' then
        e.env_name = tostring(e.env_name or '包络')
        if type(e.points) ~= 'table' then e.points = {} end
      end
      if e.kind == 'notes' and type(e.notes) ~= 'table' then e.notes = {} end
      if e.kind == 'marker' and type(e.marks) ~= 'table' then e.marks = {} end
      if e.kind == 'item' then e.pitch = tonumber(e.pitch) or 0 end
      keep[#keep+1] = e
    else
      dropped = dropped + 1
    end
  end
  -- v2 多面板结构优先; v1 旧格式 (单 entries) 整体归入通用面板
  if type(t.boards) == 'table' and #t.boards > 0 then
    local boards, total = {}, 0
    for _, b in ipairs(t.boards) do
      local list = {}
      for _, e in ipairs(b.entries or {}) do
        if e.kind == 'item' or e.kind == 'track' or e.kind == 'marker'
           or e.kind == 'notes' or e.kind == 'envelope' or e.kind == 'fxchain' then
          list[#list+1] = e
        end
      end
      boards[#boards+1] = { id = tostring(b.id), name = tostring(b.name or b.id), entries = list }
      total = total + #list
    end
    local has_global
    for _, b in ipairs(boards) do if b.id == 'global' then has_global = true end end
    if not has_global then table.insert(boards, 1, { id = 'global', name = '通用', entries = {} }) end
    S.boards = boards
    S.next_id = t.next_id or (total + 1)
    S.active_board = 'global'
    for _, b in ipairs(boards) do if b.id == t.active then S.active_board = t.active end end
    S.entries = get_board(S.active_board).entries
  else
    S.boards = { { id = 'global', name = '通用', entries = keep } }
    S.next_id = t.next_id or (#keep + 1)
    S.active_board = 'global'
    S.entries = S.boards[1].entries
  end
  if dropped > 0 then S.dirty = true end  -- 下次防抖保存时写回干净文件
end

-- ============================ 捕获 ============================

local function capture_items()
  local n = r.CountSelectedMediaItems(0)
  if n == 0 then return nil, '没有选中的 item' end
  local made = {}
  for i = 0, math.min(n, 16) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local take = pc(r.GetActiveTake, it)
    local _, chunk = pc(r.GetItemStateChunk, it, '', false)
    if not chunk then chunk = '' end
    local e = {
      kind = 'item',
      pos   = r.GetMediaItemInfo_Value(it, 'D_POSITION'),
      len   = r.GetMediaItemInfo_Value(it, 'D_LENGTH'),
      vol   = r.GetMediaItemInfo_Value(it, 'D_VOL'),
      fadein  = r.GetMediaItemInfo_Value(it, 'D_FADEINLEN'),
      fadeout = r.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN'),
      icolor = r.GetMediaItemInfo_Value(it, 'I_CUSTOMCOLOR'),
      chunk = chunk,
    }
    e.stype = chunk:match('<SOURCE[ \t]*(%a+)')
    if take and r.TakeIsMIDI(take) then
      e.is_midi = true
      e.title = (r.GetTakeName(take) or 'MIDI'):sub(1, 48)
      local _, nn = pc(r.MIDI_CountEvts, take)
      e.nnotes = nn or 0
      e.notes = {}
      for j = 0, math.min((nn or 0) - 1, 512) do
        local _, sel, muted, sp, ep, ch, pitch, vel = r.MIDI_GetNote(take, j)
        if sp then e.notes[#e.notes+1] = { sp, ep, pitch, vel, ch, sel and 1 or 0 } end
      end
      e.len = e.len or 1
    elseif take then
      local src = pc(r.GetMediaItemTake_Source, take)
      -- GetMediaSourceFileName 的 Lua 绑定只返回一个字符串, 解构两个值会让 fn 恒为 nil
      local fn = pc(r.GetMediaSourceFileName, src, '')
      -- GetMediaSourceFileName 对带 <EXT ORIGINAL_FILENAME>/代理/片段源 可能返回空,
      -- 此时从 item chunk 的 FILE 行兜底解析真实源文件路径 (chunk 一定含 FILE)。
      if not fn or fn == '' then
        fn = (chunk or ''):match('<SOURCE[^\n]*\nFILE "([^"]*)"')
          or (chunk or ''):match('FILE "([^"]*)"')
          or (chunk or ''):match("FILE '([^']*)'")
      end
      e.file = fn
      e.soffs = r.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') or 0
      e.rate  = r.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE') or 1
      e.pitch = r.GetMediaItemTakeInfo_Value(take, 'D_PITCH') or 0
      e.take_name = r.GetTakeName(take) or basename(fn or '')
      e.title = e.take_name:sub(1, 48)
      if fn and fn ~= '' then
        e.fclass = class_of(ext_of(fn))  -- 视频/图片 item 走缩略图预览
        e.fsize  = file_size(fn)
      end
      if src then
        e.sr  = pc(r.GetMediaSourceSampleRate, src) or 0
        e.nch = pc(r.GetMediaSourceNumChannels, src) or 0
        e.src_len = pc(r.GetMediaSourceLength, src) or e.len
      end
      -- 视频类 item 补充尺寸/帧率 (用于缩略图与元数据)
      if e.fclass == 'video' and fn and fn ~= '' then
        local vw, vh, fps = probe_video(fn)
        if vw then e.vw, e.vh, e.fps = vw, vh, fps end
      end
    else
      e.title = '(空 take)'
    end
    made[#made+1] = add_entry(e)
  end
  return made[1], ('已捕获 %d 个 item'):format(#made)
end

local function parse_track_display(tr, chunk)
  local d = {}
  d.name = ({pc(r.GetSetMediaTrackInfo_String, tr, 'P_NAME', '', false)})[2] or ''
  d.color = tonumber(chunk:match('\nI_CUSTOM (%-?%d+)') or '0') or 0
  d.nchan = r.GetMediaTrackInfo_Value(tr, 'I_NCHAN') or 2
  d.sends = r.GetTrackNumSends(tr, 0) or 0
  d.recvs = r.GetTrackNumSends(tr, -1) or 0
  local _, vol, pan = pc(r.GetTrackUIVolPan, tr)
  d.vol = vol or 1 d.pan = pan or 0
  d.fx = {}
  for i = 0, (pc(r.TrackFX_GetCount, tr) or 0) - 1 do
    local _, nm = pc(r.TrackFX_GetFXName, tr, i, '')
    local _, preset = pc(r.TrackFX_GetPreset, tr, i, '')
    -- TrackFX_GetEnabled 只返回一个布尔, 解构两个值会让 bypass 恒为 "开启"
    local enabled = pc(r.TrackFX_GetEnabled, tr, i)
    d.fx[#d.fx+1] = { name = (nm and nm ~= '' and nm) or ('FX' .. i),
                      preset = preset or '', on = enabled ~= false }
  end
  return d
end

local function capture_tracks()
  local n = r.CountSelectedTracks2(0, false)
  if n == 0 then return nil, '没有选中的轨道' end
  local made = {}
  for i = 0, math.min(n, 8) - 1 do
    local tr = r.GetSelectedTrack2(0, i, false)
    if tr then
      local _, chunk = pc(r.GetTrackStateChunk, tr, '', false)
      chunk = chunk or ''
      local d = parse_track_display(tr, chunk)
      local chain = chunk:match('<FXCHAIN.-\n>') or ''
      local e = {
        kind = 'track',
        title = ('%s'):format(d.name ~= '' and d.name or ('Track %d'):format(r.CSurf_TrackToID(tr, false))),
        chunk = chunk, chain = chain, d = d,
      }
      made[#made+1] = add_entry(e)
    end
  end
  return made[1], ('已捕获 %d 条轨道'):format(#made)
end

local function capture_markers(scope)
  local a, b = pc(r.GetSet_LoopTimeRange, false, false, 0, 0, false)
  a, b = a or 0, b or 0
  local use_sel = scope ~= 'all' and a ~= b
  local marks = {}
  local i = 0
  while true do
    local rv, isrgn, pos, rgnend, name, num, color
    if r.EnumProjectMarkers3 then
      rv, isrgn, pos, rgnend, name, num, color = r.EnumProjectMarkers3(0, i)
    else
      rv, isrgn, pos, rgnend, name, num = r.EnumProjectMarkers(0, i)
      color = 0
    end
    if not rv or rv == 0 then break end
    if not use_sel or (pos >= a - 1e-9 and pos <= b + 1e-9) then
      marks[#marks+1] = { pos = pos, rgnend = rgnend or pos, isrgn = isrgn and 1 or 0,
                          name = name or '', num = num or 0, color = color or 0 }
    end
    i = i + 1
    if i > 2000 then break end
  end
  if #marks == 0 then return nil, '没有捕获到标记' .. (use_sel and ' (时间选区内)' or '') end
  table.sort(marks, function(x, y) return x.pos < y.pos end)
  local e = { kind = 'marker', marks = marks, title = ('%d 个标记/区域'):format(#marks) }
  if #marks == 1 then e.title = (marks[1].name ~= '' and marks[1].name or ('标记 #' .. marks[1].num)) end
  return add_entry(e), e.title
end

local function capture_midi()
  local ed = pc(r.MIDIEditor_GetActive)
  local take = ed and pc(r.MIDIEditor_GetTake, ed)
  if not take or not r.TakeIsMIDI(take) then return nil, 'MIDI 编辑器中没有活动 take' end
  local _, nn = pc(r.MIDI_CountEvts, take)
  local notes = {}
  for i = 0, (nn or 0) - 1 do
    local _, sel, muted, sp, ep, ch, pitch, vel = r.MIDI_GetNote(take, i)
    if sel and sp then notes[#notes+1] = { sp, ep, pitch, vel, ch } end
    if #notes >= 512 then break end
  end
  if #notes == 0 then return nil, 'MIDI 编辑器中没有选中音符' end
  local e = { kind = 'notes', notes = notes, title = ('MIDI: %d 音符'):format(#notes) }
  return add_entry(e), e.title
end

local function capture_envelope()
  local env = pc(r.GetSelectedEnvelope, 0)
  if not env then return nil, '没有选中的包络' end
  local _, name = pc(r.GetEnvelopeName, env, '')
  local pts = {}
  -- 收集所有点 (预览完整包络曲线)
  for i = 0, (pc(r.CountEnvelopePoints, env) or 0) - 1 do
    local _, t, v, shape, tension, sel = r.GetEnvelopePoint(env, i)
    pts[#pts+1] = { t = t, v = v, shape = shape or 0 }
  end
  if #pts == 0 then return nil, '包络上没有点' end
  table.sort(pts, function(x, y) return x.t < y.t end)
  local e = { kind = 'envelope', env_name = name or '包络', points = pts, title = name or '包络点' }
  return add_entry(e), e.title
end

local function capture_auto()
  if (r.CountSelectedMediaItems(0) or 0) > 0 then return capture_items() end
  if (r.CountSelectedTracks2(0, false) or 0) > 0 then return capture_tracks() end
  local ed = pc(r.MIDIEditor_GetActive)
  local take = ed and pc(r.MIDIEditor_GetTake, ed)
  if take and r.TakeIsMIDI(take) then return capture_midi() end
  if pc(r.GetSelectedEnvelope, 0) then return capture_envelope() end
  local a, b = pc(r.GetSet_LoopTimeRange, false, false, 0, 0, false)
  if a and b and a ~= b then return capture_markers() end
  return nil, '没有可捕获的对象 (item/轨道/MIDI/包络/时间选区)'
end

-- ============================ ffmpeg 缩略图 ============================

local FFMPEG = false -- false=未探测 ''=无 其他=路径

-- 探测单个候选可执行文件是否可用: 返回 (路径, 版本首行) 或 nil
local function probe_ffmpeg_candidate(c)
  if not c or c == '' then return nil end
  local cmd = '"' .. c .. '" -version'
  local out = pc(r.ExecProcess, cmd, 3000) or ''
  out = out:gsub('^%s+', ''):gsub('%s+$', '')
  -- ExecProcess 成功时返回字符串以退出码(0)开头; 含 "ffmpeg version" 更可靠
  if out:match('^0') and out:lower():find('ffmpeg') then
    return c, out
  end
  return nil
end

local function ffmpeg_path()
  if FFMPEG ~= false then return FFMPEG end
  local cand = {}

  -- 1) 用户手动填写的路径 (可能是 exe 全路径, 也可能是目录, 或 "ffmpeg" 命令名)
  local manual = S.set.ffmpeg
  if manual and manual ~= '' then
    manual = manual:gsub('^%s+', ''):gsub('%s+$', '')
    if manual:lower():match('%.exe$') or manual:lower():match('[\\/][^\\/]+$') then
      cand[#cand+1] = manual
    else
      -- 当作目录: 尝试补 \ffmpeg.exe
      cand[#cand+1] = manual:gsub('[\\/]$', '') .. '\\ffmpeg.exe'
      cand[#cand+1] = manual
    end
  end

  -- 2) 系统 PATH 里的 ffmpeg
  cand[#cand+1] = 'ffmpeg'
  cand[#cand+1] = 'ffmpeg.exe'

  -- 3) WinGet 软链接 (Gyan.FFmpeg / 其他 winget 安装)
  local lap = os.getenv('LOCALAPPDATA')
  if lap then
    cand[#cand+1] = lap .. '\\Microsoft\\WinGet\\Links\\ffmpeg.exe'
  end

  -- 4) 常见固定位置
  cand[#cand+1] = 'C:\\ffmpeg\\bin\\ffmpeg.exe'
  cand[#cand+1] = 'C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe'

  for _, c in ipairs(cand) do
    local p = probe_ffmpeg_candidate(c)
    if p then FFMPEG = p return p end
  end
  FFMPEG = ''
  return ''
end

local function run_ffmpeg(args)
  local exe = ffmpeg_path()
  if exe == '' then return nil, 'ffmpeg 不可用', '' end
  local out = pc(r.ExecProcess, '"' .. exe .. '" ' .. args, 8000) or ''
  local ok = (out:gsub('^%s+', ''):match('^0') ~= nil)
  return ok, (ok and 'ok' or 'exit!=0'), out
end

probe_video = function(path)
  local exe = ffmpeg_path()
  if exe == '' then return nil end
  local out = pc(r.ExecProcess, ('"%s" -i "%s"'):format(exe, path), 6000) or ''
  local vw, vh = out:match('Video:.-,(%d+)x(%d+)')
  local fps = out:match('([%d%.]+) fps')
  if vw and vh then return tonumber(vw), tonumber(vh), fps and tonumber(fps) or nil end
end

-- 生成缩略图 PNG 列表 (img=单帧/gif 多帧/strip=单帧视频画面); 返回 (png_paths, total_frames)
-- t: 可选, 视频(strip)模式下要抽取的时间点(秒); 缺省取 1 秒
local function get_thumb(path, size, mode, t)
  local key = hash(path) .. '_' .. tostring(size)
  if mode == 'strip' then key = key .. '_t' .. tostring(math.floor((t or 1) * 100)) end
  local meta_p = CACHE .. '/' .. key .. '.meta'
  local meta = read_file(meta_p)
  -- 存在 .meta 但 PNG 丢失(旧代码遗留/手动删)时也需重新生成
  local has_png = file_exists(CACHE .. '/' .. key .. '_1.png')
  if not meta or not has_png then
    -- Windows: ffmpeg 输出路径一律用反斜杠, 避免混合分隔符导致序列文件写丢
    local ff_cache = CACHE:gsub('/', '\\')
    local ff_out   = ff_cache .. '\\' .. key .. '_%d.png'
    local ff_in    = path
    local scale    = 'scale=288:162:force_original_aspect_ratio=decrease,pad=288:162:(ow-iw)/2:(oh-ih)/2'
    local cmd, n

    if mode == 'gif' then
      -- GIF: 抽取最多 12 帧均匀分布
      n = 12
      cmd = ('-y -v error -i "%s" -frames:v %d -vf "%s" "%s"'):format(ff_in, n, scale, ff_out)
    else
      -- 视频(strip)/图片(img): 单帧; 视频取指定时间点(默认 1s 避开片头黑场), 图片第 1 帧
      n = 1
      -- -ss 放在 -i 之后 = 输出侧快速定位 (放前面对某些容器不前向 seek)
      local ss = (mode == 'strip') and (' -ss ' .. tostring(t or 1)) or ''
      cmd = ('-y -v error -i "%s"%s -frames:v 1 -vf "%s" "%s"'):format(ff_in, ss, scale, ff_out)
    end

    local ok, why, out = run_ffmpeg(cmd)
    if not ok then
      if not S.thumb_diag then
        S.thumb_diag = true
        log(('[CBM] 缩略图失败: %s\n  cmd=%s\n  out=%s\n'):format(tostring(why), cmd, tostring(out):gsub('%s+$','')))
      end
      return nil
    end
    write_file(meta_p, tostring(n))
    meta = read_file(meta_p)
  end
  local total = tonumber(meta or '') or 1
  local pngs = {}
  for i = 1, total + 1 do
    local p = CACHE .. '/' .. key .. '_' .. i .. '.png'
    if file_exists(p) then pngs[#pngs+1] = p end
  end
  if #pngs == 0 then
    if not S.thumb_diag2 then
      S.thumb_diag2 = true
      log(('[CBM] 缩略图 PNG 未生成: meta=%s cache=%s key=%s\n'):format(tostring(meta), CACHE, key))
    end
    return nil
  end
  return pngs, total
end

-- ============================ 粘贴 / 拖出引擎 ============================

local function resolve_track(spec)
  if spec == nil or spec == '' or spec == 'selected' then
    local tr = r.GetSelectedTrack2(0, 0, false)
    if tr then return tr end
    return r.GetTrack(0, 0)
  end
  local idx = tonumber(spec)
  if idx then return r.CSurf_TrackFromID(idx, false) end
  return r.GetSelectedTrack2(0, 0, false) or r.GetTrack(0, 0)
end

local function track_valid(tr) return tr and (pc(r.CSurf_TrackToID, tr, false) or 0) > 0 end

-- 瞬态检测: peaks 粗粒度包络上的上升沿
local function detect_transients(src, a, b, thresh, mingap)
  local dur = math.max(b - a, 0.01)
  local rate = 100
  local ns = math.min(math.ceil(dur * rate), 4000)
  if ns < 4 then return { a } end
  local buf = r.new_array(ns * 2 + 16) buf.clear()
  local rv = pc(r.PCM_Source_GetPeaks, src, ns / dur, a, 1, ns, 0, buf)
  if not rv or rv <= 0 then return { a } end
  local n = math.floor(rv) % 1048576
  if n < 4 then return { a } end
  local t = buf.table(1, n * 2) or {}
  local amp, gmax = {}, 0
  for i = 1, n do
    local v = math.max(math.abs(t[i] or 0), math.abs(t[n + i] or 0))
    amp[i] = v if v > gmax then gmax = v end
  end
  if gmax <= 0 then return { a } end
  local gate = gmax * (thresh or 0.5)
  local cuts, last = { a }, -1e9
  for i = 2, n do
    local time = a + (i - 1) / rate
    if amp[i] > gate and amp[i] > amp[i-1] * 1.4 and time - last > (mingap or 0.08) and time > a + 0.02 then
      cuts[#cuts+1] = time last = time
    end
  end
  cuts[#cuts+1] = b
  return cuts
end

local function compute_cuts(e, pv, mode)
  local a, b = e.win.a, e.win.b
  if e.sel then a, b = e.sel.a, e.sel.b end
  if b - a < 0.02 then return nil end
  if mode == 'off' or not mode then return nil end
  if mode == 'fixed' then
    local step = S.set.slice_fixed or 4
    if step < 0.05 then return nil end
    local cuts = {}
    local t = a
    while t < b - 0.01 do cuts[#cuts+1] = t t = t + step end
    cuts[#cuts+1] = b
    return cuts
  elseif mode == 'beats' then
    local _, div = pc(r.GetSetProjectGrid, 0, false, 0, 0, 0)
    div = div or 0.25
    local cuts = {}
    local qn0 = r.TimeMap_timeToQN(a)
    local qn1 = r.TimeMap_timeToQN(b)
    local q = math.ceil(qn0 / div) * div
    cuts[#cuts+1] = a
    while q < qn1 - 1e-6 do
      local t = r.TimeMap_QNToTime(q)
      if t > a + 0.01 and t < b - 0.01 then cuts[#cuts+1] = t end
      q = q + div
    end
    cuts[#cuts+1] = b
    return cuts
  elseif mode == 'transients' then
    local src = pv and pv.src
    if not src then return nil end
    local cuts = detect_transients(src, a, b, S.set.slice_thresh or 0.5, 0.08)
    cuts[#cuts] = b
    if #cuts < 2 then return nil end
    return cuts
  end
  return nil
end

local function track_display_name(track)
  local _, nm = pc(r.GetSetMediaTrackInfo_String, track, 'P_NAME', '', false)
  if not nm or nm == '' then
    local num = pc(r.CSurf_TrackToID, track, false)
    nm = 'Track ' .. tostring(num or 1)
  end
  return nm
end

local function insert_item_chunk(track, chunk, pos, len, soffs)
  local it = r.AddMediaItemToTrack(track)
  if not it then return nil end
  local ok = ({pc(r.SetItemStateChunk, it, chunk, false)})[1]
  if not ok then r.DeleteTrackMediaItem(track, it) return nil end
  r.SetMediaItemInfo_Value(it, 'D_POSITION', pos)
  if len then r.SetMediaItemInfo_Value(it, 'D_LENGTH', len) end
  local take = r.GetActiveTake(it)
  if take and soffs then r.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', soffs) end
  return it
end

local function paste_entry(e, pos, track, slice_mode)
  if not e then return false, '没有条目' end
  pos = pos or r.GetCursorPosition()
  if not track_valid(track) then track = resolve_track() end
  if not track_valid(track) then return false, '没有可用轨道' end
  local kind = e.kind
  local msg = ''

  r.PreventUIRefresh(1)
  r.Undo_BeginBlock()

  if kind == 'item' then
    local pv = S.pv[e.id]
    local use_sel = e.sel and (e.sel.b - e.sel.a) > 0.005
    local a, b = e.win.a, e.win.b
    if use_sel then a, b = e.sel.a, e.sel.b end
    local rate = e.rate or 1
    -- 视频/图片不切片 (瞬态检测对视频源无意义, 且可能返回空导致误判)
    local is_media = (e.fclass == 'video' or e.fclass == 'image')
    if not e.chunk and e.file then
      -- 无 chunk 条目 (媒体浏览器路径捕获): 直接用源文件建 item
      local src = pc(r.PCM_Source_CreateFromFile, e.file)
      if not src then
        msg = '源文件打开失败'
      else
        local len = (b - a) / rate
        local it = r.AddMediaItemToTrack(track)
        local tk = r.AddTakeToMediaItem(it)
        r.SetMediaItemTake_Source(tk, src)
        r.SetMediaItemInfo_Value(it, 'D_POSITION', pos)
        r.SetMediaItemInfo_Value(it, 'D_LENGTH', math.max(len, 0.001))
        if a > 0 then r.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', a * rate) end
        msg = ('已插入 item (%s)'):format(fmt_t(len))
      end
    else
    local cuts = (not e.is_midi and not is_media) and compute_cuts(e, pv, slice_mode) or nil
    if cuts and #cuts >= 2 then
      for i = 1, #cuts - 1 do
        local ca, cb = cuts[i], cuts[i+1]
        if cb - ca > 0.005 then
          insert_item_chunk(track, e.chunk, pos + (ca - cuts[1]) / rate, (cb - ca) / rate, ca)
        end
      end
      msg = ('已插入 %d 个切片'):format(#cuts - 1)
    else
      local len = (b - a) / rate
      local it = insert_item_chunk(track, e.chunk, pos, len, a)
      if it then msg = ('已插入 item (%s)'):format(fmt_t(len)) else msg = '插入失败' end
    end
    end

  elseif kind == 'notes' then
    local it = r.CreateNewMIDIItemInProj(track, pos, pos + 4, false)
    if not it then msg = '创建 MIDI item 失败'
    else
      local take = r.GetActiveTake(it)
      if type(e.notes) ~= 'table' or #e.notes == 0 then
        msg = '该条目没有音符数据'
      else
      local t0 = e.notes[1][1]
      local maxe = 0
      for _, nt in ipairs(e.notes) do
        r.MIDI_InsertNote(take, true, false, nt[1] - t0, nt[2] - t0, nt[5], nt[3], nt[4], true)
        if nt[2] - t0 > maxe then maxe = nt[2] - t0 end
      end
      r.MIDI_Sort(take)
      local qn0 = r.TimeMap_timeToQN(pos)
      local secs = r.TimeMap_QNToTime(qn0 + maxe / 960) - pos
      r.SetMediaItemInfo_Value(it, 'D_LENGTH', math.max(secs, 0.1))
      msg = ('已插入 %d 个音符'):format(#e.notes)
      end
    end

  elseif kind == 'track' then
    local idx = track_valid(track) and (r.CSurf_TrackToID(track, false) or 0) or r.GetNumTracks()
    r.InsertTrackAtIndex(idx, false)
    local ntr = r.GetTrack(0, idx)
    local chunk = (e.chunk or ''):gsub('\nTRACKID [^\n]*', '\nTRACKID ' .. r.genGuid(''))
    local ok = ({pc(r.SetTrackStateChunk, ntr, chunk, false)})[1]
    msg = ok and '已插入轨道' or '轨道恢复失败'

  elseif kind == 'marker' then
    if type(e.marks) ~= 'table' or #e.marks == 0 then
      msg = '该条目没有标记数据'
      return
    end
    local t0 = e.marks[1].pos
    for _, m in ipairs(e.marks) do
      local rel = m.pos - t0
      local re_ = m.isrgn == 1 and (pos + (m.rgnend - t0)) or 0
      r.AddProjectMarker2(0, m.isrgn == 1, pos + rel, re_, m.name, -1, m.color)
    end
    msg = ('已插入 %d 个标记/区域'):format(#e.marks)

  elseif kind == 'fxchain' then
    local fxn = (e.d and e.d.fx) or {}
    if #fxn == 0 then
      msg = 'FX 链为空'
    else
      local okn = 0
      for _, fx in ipairs(fxn) do
        local p = r.TrackFX_AddByName(track, fx.name, false, -1)
        if p and p >= 0 then okn = okn + 1 end
      end
      msg = ('已挂载 %d/%d 个 FX 到 %s'):format(okn, #fxn, track_display_name(track))
      if okn == 0 then msg = '全部 FX 未能按名挂载 (可尝试拖入 REAPER 原生粘贴)' end
    end

  elseif kind == 'envelope' then
    local env = pc(r.GetTrackEnvelopeByName, track, e.env_name)
    if not env then env = pc(r.GetSelectedEnvelope, 0) end
    if not env then
      msg = '目标轨道没有同名包络'
    else
      local t0 = e.points[1].t
      for _, p in ipairs(e.points) do
        r.InsertEnvelopePoint(env, pos + (p.t - t0), p.v, p.shape or 0, 0, true, true)
      end
      r.Envelope_SortPoints(env)
      msg = ('已插入 %d 个包络点'):format(#e.points)
    end

  else
    msg = '该类型不支持粘贴到编曲区'
  end

  r.Undo_EndBlock('bst CBM: 粘贴', -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  return true, msg
end

-- ============================ 剪贴板监视 (Ctrl+C 复制 item/track 自动捕获) ============================
-- 监听系统剪贴板 (SWS CF_GetClipboardBig 读 CF_UNICODETEXT):
--   REAPER Ctrl+C 复制 item/track/marker 会往系统剪贴板写 RPP chunk 文本 + 私有格式。
--   CF_GetClipboardBig 读到文本后, 检测是否含 <ITEM / <TRACK, 是则反解析为条目;
--   纯文本/其他内容一律忽略 (不进入剪贴板)。

-- 创建 SWS CF_GetClipboardBig 需要的 WDL_FastString (多级尝试)
local function create_faststring()
  -- 1) REAPER v7+ native
  if r.new_getCharPtr then
    local ok, fs = pcall(r.new_getCharPtr)
    if ok and fs then return fs, 'native (new_getCharPtr)' end
  end
  -- 2) SWS SNM_CreateFastString (所有 SWS 版本都有)
  if r.SNM_CreateFastString then
    local ok, fs = pcall(r.SNM_CreateFastString, '')
    if ok and fs then return fs, 'SWS (SNM_CreateFastString)' end
  end
  return nil, 'none'
end

local function cf_get_big()
  if not r.CF_GetClipboardBig then
    if not S.cf_absent_reported then
      S.cf_absent_reported = true
      log('[CBM] 剪贴板监视不可用: reaper.CF_GetClipboardBig 不存在 (SWS/cfillion 模块缺失?)\n')
    end
    return nil
  end

  local fs, via = create_faststring()
  if not fs then
    if not S.cf_fs_reported then
      S.cf_fs_reported = true
      log('[CBM] 无法创建 FastString (new_getCharPtr/SNM_CreateFastString 都不存在)\n')
    end
    return nil
  end

  -- 首次成功时打印用的方法
  if not S.cf_via_reported then
    S.cf_via_reported = true
    log(('[CBM] 剪贴板读取方式: %s\n'):format(via))
  end

  local ok = pcall(r.CF_GetClipboardBig, fs)
  if not ok then return nil end
  local ok2, s = pcall(function() return fs:get() end)
  if ok2 and type(s) == 'string' and s ~= '' then return s end
  return nil
end

-- 从 <ITEM ...> chunk 反解析出条目 (含波形元数据)
local function entry_from_item_chunk(chunk)
  local e = { kind = 'item', chunk = chunk, rate = 1, soffs = 0 }
  -- 顶层源类型 (REAPER 全部 <SOURCE 类型): WAVE/AIFF/MP3/OGG/FLAC/VIDEO/MIDI/
  -- SECTION/REVERSE/SUBPROJECT/PROJREF/CLICK/LTC... 决定预览与徽章展示
  e.stype = chunk:match('<SOURCE[ \t]*(%a+)')
  local len = chunk:match('\nLENGTH ([%d%.%-]+)')
  if len then e.len = tonumber(len) end
  local pos = chunk:match('\nPOSITION ([%d%.%-]+)')
  if pos then e.pos = tonumber(pos) end
  local soffs = chunk:match('\nSOFFS ([%d%.%-]+)')
  if soffs then e.soffs = tonumber(soffs) end
  local rate = chunk:match('\nPLAYRATE ([%d%.%-]+)')
  if rate then e.rate = tonumber(rate) or 1 end
  local name = chunk:match('\nNAME "([^"]*)"')
  -- FILE 紧跟 <SOURCE ... 行之后 (audio/midi 亦如是), 找不到再全局兜底
  local file = chunk:match('<SOURCE[^\n]*\nFILE "([^"]*)"') or chunk:match('FILE "([^"]*)"')
  if file and file ~= '' then
    e.file = file
    e.fclass = class_of(ext_of(file))
    e.fsize = file_size(file)
    e.take_name = (name and name ~= '' and name) or basename(file)
  end
  -- 无 FILE 行的源: 按类型归类 (SECTION/REVERSE 内嵌真实文件, 已由 FILE 兜底)
  if not e.fclass then
    if e.stype == 'MIDI' then e.fclass = 'midi'
    elseif e.stype == 'SUBPROJECT' or e.stype == 'PROJREF' then e.fclass = 'proj'
    elseif not e.stype then e.fclass = 'empty' end
  end
  e.title = (e.take_name or (name and name ~= '' and name) or 'item'):sub(1, 48)
  -- 预览窗口: 优先 item 片段 (soffs + len*rate)
  if e.soffs and e.len then
    e.win = { a = e.soffs, b = e.soffs + e.len * (e.rate or 1) }
  elseif e.src_len then
    e.win = { a = 0, b = e.src_len }
  elseif e.len then
    e.win = { a = 0, b = e.len }
  end
  return e
end

-- 重元数据 (PCM_Source 打开/视频探测): 剪贴板监视路径在去重之后才调用,
-- 重复复制同一对象时不再白做源解析
local function finalize_item_meta(e)
  if e.file and e.file ~= '' then
    local src = pc(r.PCM_Source_CreateFromFile, e.file)
    if src then
      e.sr = pc(r.GetMediaSourceSampleRate, src) or 0
      e.nch = pc(r.GetMediaSourceNumChannels, src) or 0
      e.src_len = pc(r.GetMediaSourceLength, src) or e.len
      pc(r.PCM_Source_Destroy, src)
    end
    if e.fclass == 'video' then
      local vw, vh, fps = probe_video(e.file)
      if vw then e.vw, e.vh, e.fps = vw, vh, fps end
    end
  end
end

local function key_exists(key)
  for _, old in ipairs(S.entries) do if old.key == key then return true end end
end

-- 从 <TRACK ...> chunk 反解析出轨道条目 (名称/颜色/FX 列表)
local function entry_from_track_chunk(chunk)
  local e = { kind = 'track', chunk = chunk }
  local name = chunk:match('\nNAME "([^"]*)"')
  local color = tonumber(chunk:match('\nI_CUSTOM (%d+)') or chunk:match('\nPEAKCOL (%d+)')) or 0
  local fxn = {}
  for fxname in chunk:gmatch('\n<(%a[%w_]*) [^"\n]*"([^"]*)"') do
    if fxname and #fxname > 0 and #fxn < 16 then fxn[#fxn+1] = { name = fxname, preset = '', on = true } end
  end
  e.d = { name = name or '', color = color, fx = fxn, sends = 0, recvs = 0, vol = 1, pan = 0 }
  e.title = ((name and name ~= '' and name) or '轨道'):sub(1, 48)
  return e
end

-- 从 <FXCHAIN chunk 反解析 FX 链条目 (跨窗口复制: FX 浏览器/轨道 FX 链 Ctrl+C)
local function entry_from_fxchain_chunk(chunk)
  local fxn = {}
  for ln in chunk:gmatch('[^\r\n]+') do
    local ty = ln:match('^<VST%d*%s') or ln:match('^<AUv3%d*%s') or ln:match('^<AU%d*%s')
            or ln:match('^<CLAP%s') or ln:match('^<JS%s') or ln:match('^<DX%s')
    if ty then
      local nm = ln:match('"([^"]*)"') or ''
      if ty == 'JS' then nm = basename(nm):gsub('%.%w+$', '') end
      fxn[#fxn+1] = { name = (nm ~= '' and nm) or ty, preset = '', on = true }
    end
  end
  local first = fxn[1] and fxn[1].name or ''
  local e = { kind = 'fxchain', chunk = chunk,
              d = { name = '', color = 0, fx = fxn, sends = 0, recvs = 0, vol = 1, pan = 0 } }
  e.title = (first ~= '' and (first .. ((#fxn > 1) and ('  +' .. (#fxn - 1)) or ''))
             or '空 FX 链'):sub(1, 48)
  return e
end

-- 从 <PARMENV(EX) chunk 反解析包络条目 (轨道包络 Ctrl+C)
local function entry_from_parenv_chunk(chunk)
  local pts = {}
  for pt, val in chunk:gmatch('<PT%s+([%d%.%-]+)%s+([%d%.%-]+)') do
    pts[#pts+1] = { t = tonumber(pt) or 0, v = tonumber(val) or 0 }
  end
  local e = { kind = 'envelope', chunk = chunk, points = pts, env_name = '复制的包络' }
  e.title = ('复制的包络 · %d 点'):format(#pts)
  return e
end

-- 从媒体文件路径文本构建条目 (媒体浏览器 "复制文件路径" / 资源管理器)
local function entry_from_file_path(path)
  local e = { kind = 'item', file = path, rate = 1, soffs = 0, stype = 'FILEPATH' }
  e.fclass = class_of(ext_of(path))
  e.fsize = file_size(path)
  e.take_name = basename(path)
  e.title = basename(path):sub(1, 48)
  finalize_item_meta(e)
  e.len = e.src_len or 0
  e.win = { a = 0, b = e.src_len or e.len or 1 }
  return e
end

-- 轮询系统剪贴板: 内容变化且为 REAPER 对象时捕获
local function watch_clipboard()
  if os.clock() - (S.last_clip_poll or 0) < 1.0 then return end
  S.last_clip_poll = os.clock()
  local big = cf_get_big()
  if not big then return end
  local key = hash(big)
  if key == S.last_clip_key then return end
  S.last_clip_key = key

  -- 按外层类型判断: 轨道 chunk 内嵌 <ITEM/<FXCHAIN, 故比较首次出现位置
  local it_pos = big:find('<ITEM', 1, true)
  local tr_pos = big:find('<TRACK', 1, true)
  local fx_pos = big:find('<FXCHAIN', 1, true)
  local env_pos = big:find('<PARMENV', 1, true)

  if tr_pos and (not it_pos or tr_pos < it_pos) then
      -- 轨道 (可能含多条轨道, 取首个 chunk 作为代表条目)
      local name = big:match('\nNAME "([^"]*)"') or '轨道'
      add_entry(entry_from_track_chunk(big))
      log('[CBM] 检测到复制轨道 "' .. name .. '", 已捕获\n')
  elseif it_pos then
      local n_items = select(2, big:gsub('<ITEM', ''))
      if n_items == 1 then
        local e = entry_from_item_chunk(big)
        e.key = entry_key(e)
        if not key_exists(e.key) then
          finalize_item_meta(e)
          add_entry(e)
          log('[CBM] 检测到复制 item, 已捕获\n')
        end
      else
        -- 多 item: 逐个按 <ITEM ...> 到闭合 > 切分
        local count = 0
        local pos = 1
        while pos <= #big and count < 16 do
          local s, e_ = big:find('<ITEM', pos, true)
          if not s then break end
          local close
          local depth = 0
          for line in big:sub(s):gmatch('[^\n]*\n?') do
            local stripped = line:match('^%s*(.-)%s*$')
            if stripped == '>' then
              depth = depth - 1
              if depth <= 0 then break end
            elseif line:find('^<', 1) then
              depth = depth + 1
            end
            close = (close or (s - 1)) + #line
          end
          close = close or #big
          local e = entry_from_item_chunk(big:sub(s, close))
          e.key = entry_key(e)
          if not key_exists(e.key) then
            finalize_item_meta(e)
            add_entry(e)
            count = count + 1
          end
          pos = close + 1
        end
        log(('[CBM] 检测到复制 %d 个 item, 已捕获\n'):format(count))
      end
  elseif fx_pos and (not env_pos or fx_pos <= env_pos) then
    -- FX 链复制 (轨道 FX 链 / FX 浏览器 Ctrl+C)
    local e = entry_from_fxchain_chunk(big)
    e.key = entry_key(e)
    if not key_exists(e.key) then
      add_entry(e)
      log(('[CBM] 检测到复制 FX 链 (%d 个 FX), 已捕获\n'):format(#(e.d.fx)))
    end
  elseif env_pos then
    -- 轨道包络复制
    local e = entry_from_parenv_chunk(big)
    e.key = entry_key(e)
    if not key_exists(e.key) then
      add_entry(e)
      log(('[CBM] 检测到复制包络 (%d 点), 已捕获\n'):format(#e.points))
    end
  else
    -- 纯文本: 媒体浏览器/资源管理器复制的媒体文件路径 → 直接成条目
    local path = big:match('^%s*([%a]:[\\/][^\r\n]+)') or big:match('^%s*(\\\\[^\r\n]+)')
    path = path and path:gsub('%s+$', '')
    if path and file_exists(path) and class_of(ext_of(path)) then
      local e = entry_from_file_path(path)
      e.key = entry_key(e)
      if not key_exists(e.key) then
        add_entry(e)
        log('[CBM] 检测到媒体文件路径, 已捕获: ' .. path .. '\n')
      end
    else
    -- 剪贴板变化但非 REAPER 对象: 忽略; 首次打印摘要便于排查
    if not S.clip_diag_shown then
      S.clip_diag_shown = true
      local head = big:sub(1, 100):gsub('[\r\n]', ' ')
      log(('[CBM] 剪贴板变化但非 REAPER 对象 (len=%d): "%s"\n'):format(#big, head))
    end
    end
  end
end

-- ============================ 导出 ============================

local function export_entry(e, path)
  if not e or not path or path == '' then return false, '缺少参数' end
  local ok
  if e.kind == 'item' then
    if e.file and e.file ~= '' then
      local srcf, dstf = io.open(e.file, 'rb'), io.open(path, 'wb')
      if srcf and dstf then dstf:write(srcf:read('*a')) ok = true end
      if srcf then srcf:close() end if dstf then dstf:close() end
      return ok, ok and ('已复制源文件 → %s'):format(path) or '复制失败'
    else
      ok = write_file(path, e.chunk or '')
      return ok, ok and '已导出 item chunk (.ritem)' or '写入失败'
    end
  elseif e.kind == 'track' then
    ok = write_file(path, e.chunk or '')
    return ok, ok and '已导出轨道模板 (.rTrackTemplate)' or '写入失败'
  elseif e.kind == 'marker' then
    local t = { 'num,name,time,rgnend,is_region,color' }
    for _, m in ipairs(e.marks) do
      t[#t+1] = ('%d,"%s",%.6f,%.6f,%d,%d'):format(m.num, (m.name:gsub('"', '""')), m.pos, m.rgnend, m.isrgn, m.color)
    end
    ok = write_file(path, table.concat(t, '\n'))
    return ok, ok and '已导出标记 CSV' or '写入失败'
  end
  return false, '该类型不支持导出'
end

-- ============================ IPC 服务端 ============================

local function exec_cmd(cmd, args)
  args = args or {}
  if cmd == 'ping' then
    return true, 'version 2.1.0 entries ' .. #S.entries
  elseif cmd == 'capture' then
    local e, m = capture_auto() return e ~= nil, m or '失败'
  elseif cmd == 'capture_items' then
    local e, m = capture_items() return e ~= nil, m or '失败'
  elseif cmd == 'capture_tracks' then
    local e, m = capture_tracks() return e ~= nil, m or '失败'
  elseif cmd == 'capture_markers' then
    local e, m = capture_markers(args.scope) return e ~= nil, m or '失败'
  elseif cmd == 'capture_midi' then
    local e, m = capture_midi() return e ~= nil, m or '失败'
  elseif cmd == 'capture_envelope' then
    local e, m = capture_envelope() return e ~= nil, m or '失败'
  elseif cmd == 'list' then
    local rows = {}
    for _, e in ipairs(S.entries) do
      local dur = ''
      if e.kind == 'item' then dur = fmt_t(e.len or 0)
      elseif e.kind == 'marker' then dur = ('%d marks'):format(#e.marks)
      elseif e.kind == 'notes' then dur = ('%d notes'):format(#e.notes)
      elseif e.kind == 'envelope' then dur = ('%d pts'):format(#e.points)
      elseif e.kind == 'track' then dur = ('%d fx'):format(#(e.d and e.d.fx or {}))
      end
      rows[#rows+1] = ('%d\t%s\t%s\t%s'):format(e.id, e.kind, (e.title or ''):gsub('[\t\r\n]', ' '), dur)
    end
    return true, table.concat(rows, '\n')
  elseif cmd == 'info' then
    local e = find_entry(args.id)
    if not e then return false, '没有找到条目 ' .. tostring(args.id) end
    local t = { 'id: ' .. e.id, 'kind: ' .. e.kind, 'title: ' .. (e.title or ''),
                'created: ' .. os.date('%Y-%m-%d %H:%M:%S', e.time or 0) }
    if e.len then t[#t+1] = 'length: ' .. fmt_t(e.len) end
    if e.src_len then t[#t+1] = 'source_length: ' .. fmt_t(e.src_len) end
    if e.file then t[#t+1] = 'file: ' .. e.file end
    if e.sr then t[#t+1] = ('sample_rate: %d Hz'):format(e.sr) end
    if e.nch then t[#t+1] = 'channels: ' .. e.nch end
    if e.nnotes then t[#t+1] = 'midi_notes: ' .. e.nnotes end
    if e.marks then t[#t+1] = 'markers: ' .. #e.marks end
    if e.points then t[#t+1] = 'envelope_points: ' .. #e.points end
    if e.d then
      t[#t+1] = 'track_fx: ' .. #e.d.fx
      t[#t+1] = 'track_sends: ' .. e.d.sends
    end
    return true, table.concat(t, '\n')
  elseif cmd == 'paste' then
    local e = find_entry(args.id)
    if not e then return false, '没有找到条目' end
    local pos = tonumber(args.time) or r.GetCursorPosition()
    local tr = resolve_track(args.track)
    local ok, msg = paste_entry(e, pos, tr, args.slice)
    return ok, msg
  elseif cmd == 'export' then
    local e = find_entry(args.id)
    return export_entry(e, args.path)
  elseif cmd == 'clear' then
    local b = get_board(S.active_board) or S.boards[1]
    local n = #b.entries
    for _, e in ipairs(b.entries) do
      if S.pv[e.id] and S.pv[e.id].src then pc(r.PCM_Source_Destroy, S.pv[e.id].src) end
    end
    S.pv = {}
    b.entries = {}
    S.entries = b.entries
    S.dirty = true
    -- 重置剪贴板监视状态: 清空后若再复制同一内容, 也能正常触发
    S.last_clip_key = nil
    S.last_clip_poll = os.clock()
    -- 立刻写盘, 而不是等 1s 防抖 (确保重启不复活旧条目)
    entry_save()
    S.dirty = false S.last_save = os.clock()
    return true, ('已清空面板「%s」%d 条'):format(b.name, n)
  end
  return false, '未知命令: ' .. tostring(cmd)
end

-- IPC 轮询 (主脚本端): 服务 stub 子脚本 / cli 发来的捕获・粘贴请求
-- 对影响状态的动作在面板上弹 toast 反馈 (list/info/ping 这类查询不打扰)
local function ipc_poll()
  for i = 0, 15 do
    local p = IPC_DIR .. '/req_' .. i .. '.json'
    local s = read_file(p)
    if s then
      local cmd = s:match('^CMD ([%w_]+)')
      local args = {}
      for k, v in s:gmatch('\nARG (%w+) ([^\n]*)') do args[k] = v end
      local ok, payload = exec_cmd(cmd, args)
      write_file(IPC_DIR .. '/resp_' .. i .. '.json', (ok and 'OK\n' or 'ERR\n') .. (payload or '') .. '\n')
      os.remove(p)
      if cmd == 'capture' or cmd == 'paste' or cmd == 'clear'
         or cmd:match('^capture_') or cmd == 'export' then
        local head = (payload or ''):gsub('[\r\n].*', '')
        set_toast(ok and 'ok' or 'bad', ((ok and '' or '失败 · ') .. head):sub(1, 80))
      end
    end
  end
end

-- ============================ 预览绘制 ============================

local function nice_step(span)
  local steps = { 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
                  1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600 }
  for _, st in ipairs(steps) do if span / st <= 10 then return st end end
  return 3600
end

-- 音频波形 (MiniMeters 风: 峰值剪影 + RMS 内芯, 单一柔和蓝系)
local function draw_waveform(e, x, y, w, h)
  local dl = imgui.GetWindowDrawList(ctx)
  imgui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, PAL.bg2, 4)
  imgui.DrawList_AddRect(dl, x + 0.5, y + 0.5, x + w - 0.5, y + h - 0.5, PAL.grid, 4)
  local pv = S.pv[e.id]
  if not pv then S.pv[e.id] = {} pv = S.pv[e.id] end
  -- 源文件解析: e.file 可能为 nil(旧条目/视频)/含空白; 若缺失则从 chunk 的 FILE 行兜底
  if not pv.src then
    local f = e.file
    if not f or f:match('^%s*$') then
      f = (e.chunk or ''):match('FILE "([^"]*)"') or (e.chunk or ''):match("FILE '([^']*)'")
      if f and f ~= '' then e.file = f end
    end
    if f and f ~= '' then
      local ok, s = pcall(r.PCM_Source_CreateFromFile, f)
      if ok and s then
        pv.src = s
      else
        -- 表面化真实错误, 便于排查为何 mp3/wav 打不开
        if not pv.err_reported then
          pv.err_reported = true
          log(('[CBM] 波形源创建失败: file=%q 存在=%s 错误=%s\n'):format(
            tostring(f), tostring(file_exists(f)), tostring(s)))
        end
      end
    end
  end
  if not pv.src then
    imgui.DrawList_AddText(dl, x + 8, y + h / 2 - 7, PAL.txt2, '(无音频源)')
    return
  end
  e.win = e.win or { a = 0, b = e.src_len or 1 }
  local nch = math.max(e.nch or 2, 2)
  local span = e.win.b - e.win.a
  if span <= 0.001 then e.win.b = e.win.a + 0.001 span = 0.001 end

  local key = ('%.4f|%.4f|%d|%d'):format(e.win.a, e.win.b, math.floor(w), nch)
  if not pv.peaks or pv.peaks.key ~= key then
    local ns = math.min(math.max(math.floor(w), 16), 2048)
    -- peakmode 0 = 峰值 min/max, 1 = RMS; 布局同为 [max 块 | min 块]
    local buf = r.new_array(ns * nch * 2 + 16) buf.clear()
    local rv = pc(r.PCM_Source_GetPeaks, pv.src, ns / span, e.win.a, nch, ns, 0, buf)
    local n = (rv and math.floor(rv) % 1048576) or 0
    local t, rt, rn = {}, {}, 0
    if n > 0 then
      t = buf.table(1, n * nch * 2) or {}
      buf.clear()
      local rv2 = pc(r.PCM_Source_GetPeaks, pv.src, ns / span, e.win.a, nch, ns, 1, buf)
      local n2 = (rv2 and math.floor(rv2) % 1048576) or 0
      if n2 > 0 then rt = buf.table(1, n2 * nch * 2) or {} rn = n2 end
    end
    pv.peaks = { key = key, n = n, t = t, rt = rt, rn = rn, ns = ns, nch = nch }
  end
  local pk = pv.peaks
  local n = pk.n
  local half = h / 2

  -- 峰值剪影(低透明) + RMS 内芯(高亮), 声道同色 —— MiniMeters 分层画法
  local vpeak = 0.0001
  for i = 1, n * nch do
    local v = pk.t[i] or 0 if v > vpeak then vpeak = v end
    v = pk.t[n * nch + i] or 0 if -v > vpeak then vpeak = -v end
  end
  if vpeak > 1 then vpeak = 1 end
  local rn = pk.rn or 0
  local draw_ch = function(ci, yy, hh)
    local cy = yy + hh / 2
    for sx = 0, math.floor(w) - 1 do
      local si = math.floor(sx / w * n) + 1
      if si <= n then
        local base = (si - 1) * nch + ci + 1
        local mx = math.max(pk.t[base] or 0, 0)
        local mn = math.max(-(pk.t[n * nch + base] or 0), 0)
        local y1 = cy - mx / vpeak * (hh / 2) * 0.96
        local y2 = cy + mn / vpeak * (hh / 2) * 0.96
        if y2 - y1 < 1 then y2 = y1 + 1 end
        imgui.DrawList_AddRectFilled(dl, x + sx, y1, x + sx + 1, y2, PAL.wave_peak)
        if rn > 0 then
          local rmx = math.max(pk.rt[base] or 0, 0)
          local rmn = math.max(-(pk.rt[rn * nch + base] or 0), 0)
          local ry1 = cy - rmx / vpeak * (hh / 2) * 0.96
          local ry2 = cy + rmn / vpeak * (hh / 2) * 0.96
          if ry2 - ry1 < 1 then ry2 = ry1 + 1 end
          imgui.DrawList_AddRectFilled(dl, x + sx, ry1, x + sx + 1, ry2, PAL.wave_rms)
        end
      end
    end
    imgui.DrawList_AddLine(dl, x, cy, x + w, cy, PAL.grid)
  end
  if nch >= 2 then
    draw_ch(0, y, half)
    draw_ch(1, y + half, half)
    -- 声道分隔 + 角标: 同色系下明确 "这是双声道"
    imgui.DrawList_AddLine(dl, x, y + half, x + w, y + half, PAL.grid)
    if w >= 90 and h >= 44 then
      imgui.DrawList_AddText(dl, x + 4, y + 1, PAL.txt3, 'L')
      imgui.DrawList_AddText(dl, x + 4, y + half + 1, PAL.txt3, 'R')
    end
  else
    draw_ch(0, y, h)
  end

  if e.sel then
    local xa = x + (e.sel.a - e.win.a) / span * w
    local xb = x + (e.sel.b - e.win.a) / span * w
    if xb < xa then xa, xb = xb, xa end
    imgui.DrawList_AddRectFilled(dl, xa, y, xb, y + h, PAL.sel)
    imgui.DrawList_AddLine(dl, xa, y, xa, y + h, PAL.selb)
    imgui.DrawList_AddLine(dl, xb, y, xb, y + h, PAL.selb)
    imgui.DrawList_AddText(dl, xa + 4, y + 2, PAL.selb, fmt_t(e.sel.b - e.sel.a))
  end

  -- 切片预览: 按当前切片模式计算断点并画虚线分隔 (拖出前即可看到切成几段)
  local slice_mode = e.slice_mode or S.set.slice_mode or 'off'
  if slice_mode ~= 'off' and slice_mode then
    local cuts = compute_cuts(e, pv, slice_mode)
    if cuts and #cuts >= 2 then
      local a0 = e.sel and e.sel.a or e.win.a
      local b0 = e.sel and e.sel.b or e.win.b
      local sspan = math.max(b0 - a0, 0.001)
      -- 虚线分隔 + 段数角标
      for i = 1, #cuts - 1 do
        local cx = x + (cuts[i] - a0) / sspan * w
        if cx > x + 1 and cx < x + w - 1 then
          for dy = 0, h - 4, 4 do
            imgui.DrawList_AddLine(dl, cx, y + dy, cx, y + math.min(dy + 2, h), PAL.wave_dim)
          end
        end
      end
      local nsegs = #cuts - 1
      imgui.DrawList_AddText(dl, x + w - 48, y + 2, PAL.wave_dim, ('%d 段'):format(nsegs))
    end
  end

  if h >= 52 then
    local st = nice_step(span)
    local t = math.ceil(e.win.a / st) * st
    while t < e.win.b do
      local xx = x + (t - e.win.a) / span * w
      imgui.DrawList_AddLine(dl, xx, y + h - 8, xx, y + h, PAL.grid)
      imgui.DrawList_AddText(dl, xx + 2, y + h - 20, PAL.txt2, fmt_t(t))
      t = t + st
    end
  end

  -- 时长角标
  local dur_txt = fmt_t(e.src_len or (e.win.b or 0))
  imgui.DrawList_AddText(dl, x + 4, y + 2, PAL.wave, dur_txt)
  imgui.DrawList_AddRect(dl, x, y, x + w, y + h, PAL.border, 4)
end

local function draw_pianoroll(e, x, y, w, h)
  local dl = imgui.GetWindowDrawList(ctx)
  imgui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, PAL.bg2)
  local notes = e.notes
  if not notes or #notes == 0 then return end
  local pmin, pmax, tmin, tmax = 127, 0, math.huge, -math.huge
  for _, nt in ipairs(notes) do
    if nt[3] < pmin then pmin = nt[3] end
    if nt[3] > pmax then pmax = nt[3] end
    if nt[1] < tmin then tmin = nt[1] end
    if nt[2] > tmax then tmax = nt[2] end
  end
  pmin = math.max(pmin - 2, 0) pmax = math.min(pmax + 2, 127)
  if pmax <= pmin then pmax = pmin + 1 end
  local tspan = math.max(tmax - tmin, 1)
  for _, nt in ipairs(notes) do
    local nx = x + (nt[1] - tmin) / tspan * w
    local nw = math.max((nt[2] - nt[1]) / tspan * w, 2)
    local ny = y + h - (nt[3] - pmin + 1) / (pmax - pmin + 1) * h
    local col = (nt[6] == 0) and PAL.wave2 or PAL.wave
    imgui.DrawList_AddRectFilled(dl, nx, ny, nx + nw, ny + math.max(h / (pmax - pmin + 1) - 1, 2), col)
  end
  imgui.DrawList_AddRect(dl, x, y, x + w, y + h, PAL.grid)
end

local function draw_env_curve(e, x, y, w, h)
  local dl = imgui.GetWindowDrawList(ctx)
  imgui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, PAL.bg2)
  local pts = e.points
  if not pts or #pts == 0 then return end
  local tmin, tmax = pts[1].t, pts[#pts].t
  if tmax <= tmin then tmax = tmin + 1 end
  local vmin, vmax = math.huge, -math.huge
  for _, p in ipairs(pts) do
    if p.v < vmin then vmin = p.v end
    if p.v > vmax then vmax = p.v end
  end
  if vmax - vmin < 1e-9 then vmax = vmin + 1 end
  local px, py
  for _, p in ipairs(pts) do
    local xx = x + (p.t - tmin) / (tmax - tmin) * w
    local yy = y + h - (p.v - vmin) / (vmax - vmin) * h
    if px then imgui.DrawList_AddLine(dl, px, py, xx, yy, PAL.wave, 2) end
    px, py = xx, yy
  end
  imgui.DrawList_AddRect(dl, x, y, x + w, y + h, PAL.grid)
end

-- 视频/图片/GIF 缩略图: file 记录形如 { path, ext, size, class }
-- 视频(strip)支持: 底部时间线拖动看帧 + 主体拖拽选时区 (e.sel)
local function draw_thumb(e, file, x, y, w, h)
  local dl = imgui.GetWindowDrawList(ctx)
  imgui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, PAL.bg2)
  if not file or not file.path then
    imgui.DrawList_AddText(dl, x + 8, y + h / 2 - 7, PAL.txt2, '(无预览源)')
    return
  end
  local pv = S.pv[e.id]
  if not pv then S.pv[e.id] = {} pv = S.pv[e.id] end
  local is_video = (file.class == 'video')
  local mode = file.ext == 'gif' and 'gif' or (file.class == 'image' and 'img' or 'strip')

  -- 视频总时长 (源长度); 取 e.src_len 或 e.len 或 1 兜底
  local total_len = (e.src_len and e.src_len > 0 and e.src_len) or (e.len and e.len > 0 and e.len) or 1
  -- 播放头(当前帧时间点); 量化到 0.05s 步进以复用缓存、避免拖动时每帧重跑 ffmpeg
  if not e.tv then e.tv = 0 end
  e.tv = math.max(0, math.min(e.tv, total_len))
  local tv_q = math.floor(e.tv / 0.05 + 0.5) * 0.05

  -- 时间线区域高度
  local tl_h = is_video and 16 or 0
  local pic_h = h - tl_h

  local key = file.path .. '#' .. tostring(tv_q)
  if pv.thumb_key ~= key then
    pv.imgs = nil pv.tex = nil
    pv.stage = 'ffmpeg'
    local pngs = get_thumb(file.path, file.size, mode, tv_q)
    if pngs then
      pv.stage = 'create_image'
      local imgs = {}
      for _, p in ipairs(pngs) do
        local im = pc(imgui.CreateImage, p)
        if im then imgs[#imgs+1] = im pcall(imgui.Attach, ctx, im) end
      end
      if #imgs > 0 then pv.imgs = imgs pv.tex = imgs[1] pv.stage = 'ok' end
    end
    pv.thumb_key = key
  end

  -- 绘制帧画面 (图片区)
  if pv.tex then
    local w_, h_ = pc(imgui.Image_GetSize, pv.tex)
    w_, h_ = w_ or 288, h_ or 162
    local sc = math.min(w / w_, pic_h / h_)
    local iw, ih = w_ * sc, h_ * sc
    local ox, oy = x + (w - iw) / 2, y + (pic_h - ih) / 2
    imgui.DrawList_AddImage(dl, pv.tex, ox, oy, ox + iw, oy + ih)
  else
    local stage = pv.stage or 'ffmpeg'
    local ffok = ffmpeg_path() ~= ''
    local msg
    if not ffok then msg = '(无预览: 未找到 ffmpeg)'
    elseif stage == 'ffmpeg' then msg = '(无预览: ffmpeg 生成失败)'
    elseif stage == 'create_image' then msg = '(无预览: 图片加载失败)'
    else msg = '(无预览)' end
    imgui.DrawList_AddText(dl, x + 8, y + pic_h / 2 - 7, PAL.txt2, msg)
  end

  -- 选区遮罩 (视频/音频通用, 画在图像区)
  if e.sel and is_video then
    local xa = x + (e.sel.a / total_len) * w
    local xb = x + (e.sel.b / total_len) * w
    if xb < xa then xa, xb = xb, xa end
    imgui.DrawList_AddRectFilled(dl, xa, y, xb, y + pic_h, PAL.sel)
    imgui.DrawList_AddLine(dl, xa, y, xa, y + pic_h, PAL.selb)
    imgui.DrawList_AddLine(dl, xb, y, xb, y + pic_h, PAL.selb)
    imgui.DrawList_AddText(dl, xa + 4, y + 2, PAL.selb, fmt_t(e.sel.b - e.sel.a))
  end

  -- 时间线 (仅视频)
  if is_video then
    local ty = y + pic_h
    imgui.DrawList_AddRectFilled(dl, x, ty, x + w, ty + tl_h, PAL.bg)
    imgui.DrawList_AddRect(dl, x, ty, x + w, ty + tl_h, PAL.grid)
    -- 播放头
    local hx = x + (e.tv / total_len) * w
    imgui.DrawList_AddLine(dl, hx, ty, hx, ty + tl_h, PAL.selb, 2)
    -- 选区段高亮
    if e.sel then
      local xa = x + (e.sel.a / total_len) * w
      local xb = x + (e.sel.b / total_len) * w
      if xb < xa then xa, xb = xb, xa end
      imgui.DrawList_AddRectFilled(dl, xa, ty, xb, ty + tl_h, PAL.sel)
    end
    -- 时间文本
    imgui.DrawList_AddText(dl, x + 4, ty - 1, PAL.txt2, fmt_t(e.tv) .. ' / ' .. fmt_t(total_len))
  end
end

-- ============================ 卡片辅助 ============================

-- 补齐旧条目缺失的源文件信息 (老版本/GetMediaSourceFileName 失败的条目只有 chunk)
local function repair_entry(e)
  if e.kind ~= 'item' then return end
  if e.file and e.file ~= '' then
    if e.fclass == nil then e.fclass = class_of(ext_of(e.file)) end
    return
  end
  local chunk = e.chunk or ''
  local fn = chunk:match('<SOURCE[^\n]*\nFILE "([^"]*)"')
    or chunk:match('FILE "([^"]*)"')
    or chunk:match("FILE '([^']*)'")
  if fn and fn ~= '' then
    e.file = fn
    e.fclass = class_of(ext_of(fn))
    if e.fsize == nil then e.fsize = file_size(fn) end
  end
end

-- 决定 item/条目用哪种预览, 返回: 'wave'|'thumb'|'piano'|'env'|'marker'|'track'|'info'
local function preview_kind(e)
  if e.kind == 'item' then
    if e.is_midi then return 'piano' end
    -- 惰性补齐/修复媒体信息: 兼容旧持久化条目(无 fclass/file 字段) 与新捕获条目
    repair_entry(e)
    if e.fclass == 'midi' or e.fclass == 'proj' or e.fclass == 'empty' then return 'info' end
    if e.fclass == 'video' or e.fclass == 'image' then return 'thumb' end
    -- 有源音频文件或已知音频时长 → 波形; 否则(空 take/无媒体源) → 信息块
    if (e.file and e.file ~= '' and e.fclass == 'audio') or (e.src_len and e.src_len > 0) then
      return 'wave'
    end
    return 'info'
  elseif e.kind == 'notes' then return 'piano'
  elseif e.kind == 'envelope' then return 'env'
  elseif e.kind == 'marker' then return 'marker'
  elseif e.kind == 'track' then return 'track'
  elseif e.kind == 'fxchain' then return 'track'
  end
  return 'info'
end

-- 预览区高度 (按类型自适应; compact 下整体压扁)
local function preview_height(e, k, compact)
  if compact then return 32 end
  if k == 'wave' then return 76 end
  if k == 'thumb' then return 80 end
  if k == 'piano' or k == 'env' then return 62 end
  if k == 'marker' then return math.min(6, #(e.marks or {})) * 15 + 12 end
  if k == 'track' then return math.min(3, #(e.d and e.d.fx or {})) * 14 + 26 end
  return 30  -- info
end

-- utf8 安全的按像素宽度截断 (超出以 … 结尾)。先按字节二分, 再回退到
-- UTF-8 字符首字节边界, 保证不切断多字节汉字。
local function fit_text(text, maxw)
  text = tostring(text or '')
  maxw = maxw or math.huge
  if maxw <= 0 then return text end
  if imgui.CalcTextSize(ctx, text) <= maxw then return text end
  local n, lo, hi, best = #text, 1, #text, 1
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if imgui.CalcTextSize(ctx, text:sub(1, mid) .. '…') <= maxw then
      best = mid lo = mid + 1
    else
      hi = mid - 1
    end
  end
  while best > 1 do
    local b = text:byte(best)
    if not (b >= 0x80 and b < 0xC0) then break end  -- best 是某字符首字节即可
    best = best - 1
  end
  return text:sub(1, best) .. '…'
end

-- 无媒体源的条目: 简短信息块, 不画空波形
local function draw_info_block(e, x, y, w, h)
  local dl = imgui.GetWindowDrawList(ctx)
  imgui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, PAL.bg2, 4)
  local lines = {}
  if e.kind == 'item' then
    if e.len then lines[#lines+1] = fmt_t(e.len) .. 's' end
    lines[#lines+1] = e.take_name or '(无媒体源 / 空 item)'
  else
    lines[#lines+1] = e.title or '(无预览)'
  end
  local str = table.concat(lines, '   ')
  imgui.DrawList_AddText(dl, x + 10, y + (h - 14) / 2, PAL.txt2,
    fit_text(str, math.max(w - 20, 20)))
  imgui.DrawList_AddRect(dl, x, y, x + w, y + h, PAL.grid, 4)
end

-- 类型徽章: 半透明色底 + 同色文字 (低饱和, MiniMeters 式), 固定高度,
-- 可传 y_abs 让调用方做像素级垂直对齐
local BADGE_H = 16
local function draw_badge_at(label, color, y_abs)
  local tw, th = imgui.CalcTextSize(ctx, label)
  local bw, bh = tw + 12, BADGE_H
  local bx, by = imgui.GetCursorScreenPos(ctx)
  if y_abs then by = y_abs end
  imgui.Dummy(ctx, bw, bh)
  local dl = imgui.GetWindowDrawList(ctx)
  imgui.DrawList_AddRectFilled(dl, bx, by, bx + bw, by + bh, with_alpha(color, 0x2A), 4)
  imgui.DrawList_AddRect(dl, bx, by, bx + bw, by + bh, with_alpha(color, 0x44), 4)
  imgui.DrawList_AddText(dl, bx + 6, by + (bh - th) / 2, color, label)
  return bw, bh
end

-- 类型筛选 chips
local KIND_CHIPS = {
  { id = 'all',      label = '全部' },
  { id = 'audio',    label = '音频' },
  { id = 'visual',   label = '视图' },
  { id = 'midi',     label = 'MIDI' },
  { id = 'track',    label = '轨道' },
  { id = 'fxchain',  label = 'FX链' },
  { id = 'marker',   label = '标记' },
  { id = 'envelope', label = '包络' },
}

local function match_kind(e, f)
  if f == 'all' or f == '' or f == nil then return true end
  if f == 'audio' then
    return e.kind == 'item' and not e.is_midi
       and e.fclass ~= 'video' and e.fclass ~= 'image'
       and e.fclass ~= 'midi' and e.fclass ~= 'proj' and e.fclass ~= 'empty'
  end
  if f == 'visual' then
    return e.kind == 'item' and (e.fclass == 'video' or e.fclass == 'image')
  end
  if f == 'midi' then
    return e.kind == 'notes' or (e.kind == 'item' and (e.is_midi or e.fclass == 'midi'))
  end
  return e.kind == f
end

-- chip 按钮: 选中态 accent 实底, 未选中 ghost。返回是否被点击。
local function chip(id, label, selected)
  local pushed = 0
  if selected then
    imgui.PushStyleColor(ctx, imgui.Col_Button, T.accent)
    imgui.PushStyleColor(ctx, imgui.Col_ButtonHovered, T.accent_hov)
    imgui.PushStyleColor(ctx, imgui.Col_ButtonActive, T.accent_act)
    imgui.PushStyleColor(ctx, imgui.Col_Text, T.on_accent)
    pushed = 4
  else
    imgui.PushStyleColor(ctx, imgui.Col_Button, 0x00000000)
    imgui.PushStyleColor(ctx, imgui.Col_ButtonHovered, T.sub_hov)
    imgui.PushStyleColor(ctx, imgui.Col_ButtonActive, T.sub_act)
    pushed = 3
  end
  local clicked = imgui.SmallButton(ctx, label .. '##chip_' .. id)
  if pushed > 0 then imgui.PopStyleColor(ctx, pushed) end
  return clicked
end

-- ============================ 单条卡片 ============================

-- 卡片主体 (在 fl.begin_card/end_card 之间由 pcall 保护执行:
-- 即使中途报错, end_card 也必然执行, BeginChild/EndChild 保持配对)
local function card_body(e, compact)
  local w = select(1, imgui.GetContentRegionAvail(ctx))
  local pk = preview_kind(e)
  local prev_h = preview_height(e, pk, compact)

  -- ---- 头部行: 徽章(固定高) + 标题 + 时间, 全部画在同一条垂直中线上 ----
  local badge_kind = e.kind
  if e.kind == 'item' then
    if e.fclass == 'video' then badge_kind = 'video'
    elseif e.fclass == 'image' then badge_kind = 'image'
    elseif e.fclass == 'midi' then badge_kind = 'midi'
    elseif e.fclass == 'proj' then badge_kind = 'proj'
    elseif e.fclass == 'empty' then badge_kind = 'empty'
    else badge_kind = 'item' end
  end
  local blabel = KIND_LABEL[badge_kind] or tostring(badge_kind)
  local bcol = KIND_COLOR[badge_kind] or PAL.accent
  local HEAD_H = BADGE_H + 2
  local ago_txt = ago(e.time)
  local tw_ago = select(1, imgui.CalcTextSize(ctx, ago_txt))
  local bx, by = imgui.GetCursorScreenPos(ctx)
  local bw = select(1, draw_badge_at(blabel, bcol, by + (HEAD_H - BADGE_H) / 2))
  local dl_h = imgui.GetWindowDrawList(ctx)
  local title_txt = e.title or ''
  local title_max = math.max(w - bw - 8 - tw_ago - 12, 24)
  local _, th_t = imgui.CalcTextSize(ctx, title_txt)
  local ty = by + (HEAD_H - th_t) / 2
  imgui.DrawList_AddText(dl_h, bx + bw + 8, ty, PAL.txt, fit_text(title_txt, title_max))
  imgui.DrawList_AddText(dl_h, bx + w - tw_ago, ty, T.text_dis, ago_txt)
  imgui.Dummy(ctx, w, HEAD_H)

  -- ---- 预览区 ----
  local px, py = imgui.GetCursorScreenPos(ctx)
  imgui.InvisibleButton(ctx, '##pv' .. e.id, w, prev_h)

  if pk == 'wave' then
    draw_waveform(e, px, py, w, prev_h)
  elseif pk == 'thumb' then
    draw_thumb(e, { path = e.file, ext = ext_of(e.file or ''), size = e.fsize or 0, class = e.fclass },
               px, py, w, prev_h)
  elseif pk == 'piano' then
    draw_pianoroll(e, px, py, w, prev_h)
  elseif pk == 'env' then
    draw_env_curve(e, px, py, w, prev_h)
  elseif pk == 'info' then
    draw_info_block(e, px, py, w, prev_h)
  elseif pk == 'marker' then
    local dl = imgui.GetWindowDrawList(ctx)
    local _, py2 = imgui.GetItemRectMax(ctx)
    imgui.DrawList_AddRectFilled(dl, px, py, px + w, py2, PAL.bg2, 4)
    local yy = py + 6
    for i, m in ipairs(e.marks) do
      if yy > py2 - 15 or i > (compact and 3 or 6) then
        imgui.DrawList_AddText(dl, px + 10, yy, PAL.txt2, ('...共 %d 个'):format(#e.marks))
        break
      end
      imgui.DrawList_AddText(dl, px + 10, yy, PAL.selb, ('#%-3d'):format(m.num))
      imgui.DrawList_AddText(dl, px + 52, yy, PAL.wave, fmt_t(m.pos))
      imgui.DrawList_AddText(dl, px + 128, yy, PAL.txt, (m.name or ''):sub(1, 40) .. (m.isrgn == 1 and ' [区域]' or ''))
      yy = yy + 15
    end
    imgui.DrawList_AddRect(dl, px, py, px + w, py2, PAL.grid, 4)
  elseif pk == 'track' then
    local dl = imgui.GetWindowDrawList(ctx)
    local _, py2 = imgui.GetItemRectMax(ctx)
    imgui.DrawList_AddRectFilled(dl, px, py, px + w, py2, PAL.bg2, 4)
    local d = e.d or {}
    imgui.DrawList_AddRectFilled(dl, px + 8, py + 8, px + 20, py + 20,
      d.color ~= 0 and ((d.color & 0xFFFFFF) | 0xFF000000) or PAL.txt2, 3)
    if e.kind == 'fxchain' then
      imgui.DrawList_AddText(dl, px + 28, py + 8, PAL.txt,
        ('FX 链 · %d 个效果器'):format(#(d.fx or {})))
    else
      imgui.DrawList_AddText(dl, px + 28, py + 8, PAL.txt,
        ('%s  vol %.1f dB  pan %+.0f'):format(fit_text(d.name ~= '' and d.name or '(未命名)', w - 140),
          20 * math.log(math.max(d.vol or 1, 0.0001), 10), (d.pan or 0) * 100))
    end
    local yy = py + 28
    local fxn = d.fx or {}
    for i = 1, math.min(#fxn, compact and 1 or 3) do
      local fx = fxn[i]
      -- 旧数据可能缺 name/preset/on, 全部兜底, 避免插件行显示 "nil" 或拼接报错
      local fxline = tostring(fx.name or ('FX' .. i))
        .. (fx.preset and fx.preset ~= '' and (' · ' .. fx.preset) or '')
        .. (fx.on and '' or ' (bypass)')
      imgui.DrawList_AddText(dl, px + 28, yy, (fx.on ~= false) and PAL.green or PAL.red, fxline)
      yy = yy + 14
    end
    if #fxn > 3 then
      imgui.DrawList_AddText(dl, px + 28, yy, PAL.txt2, ('...共 %d 个 FX, %d 发送, %d 接收'):format(#fxn, d.sends or 0, d.recvs or 0))
    end
    imgui.DrawList_AddRect(dl, px, py, px + w, py2, PAL.grid, 4)
  end

  -- 预览交互: 缩放/选区(波形) + 时间线拖动/选区(视频)
  local is_video_thumb = (pk == 'thumb' and e.fclass == 'video')

  -- (1) 波形: 滚轮缩放 + 双击清选区
  if imgui.IsItemHovered(ctx) and pk == 'wave' and e.win then
    local wheel = imgui.GetMouseWheel(ctx) or 0
    if wheel ~= 0 and e.win.b > e.win.a then
      local mx = select(1, imgui.GetMousePos(ctx))
      local t = e.win.a + (mx - px) / w * (e.win.b - e.win.a)
      local f = wheel > 0 and 0.78 or 1.28
      local maxb = e.src_len or e.win.b
      local na, nb = t - (t - e.win.a) * f, t + (e.win.b - t) * f
      e.win.a = math.max(0, na) e.win.b = math.min(maxb, nb)
      if e.win.b - e.win.a < 0.01 then e.win.b = e.win.a + 0.01 end
    end
    if imgui.IsMouseDoubleClicked(ctx, 0) then e.sel = nil end
  end

  -- (2) 视频: 时间线拖动改变播放头 (看图), 双击时间线清选区
  if imgui.IsItemHovered(ctx) and is_video_thumb then
    local total_len = (e.src_len and e.src_len > 0 and e.src_len) or (e.len and e.len > 0 and e.len) or 1
    local mx = select(1, imgui.GetMousePos(ctx))
    local ty = py + prev_h - 16
    -- 鼠标在时间线区域内 → 拖动改变播放头
    if (imgui.IsMouseDown(ctx, 0)) and (mx >= ty) then
      local t = math.max(0, math.min((mx - px) / w, 1)) * total_len
      e.tv = t
    end
    if imgui.IsMouseDoubleClicked(ctx, 0) then e.sel = nil end
  end

  -- (3)+(4) 选时区拖拽: 波形 与 视频 统一处理
  local is_sel_drag_target = (pk == 'wave') or is_video_thumb
  if imgui.IsItemActive(ctx) and imgui.IsMouseDragging(ctx, 0) and is_sel_drag_target then
    local mx = select(1, imgui.GetMousePos(ctx))
    local t
    if pk == 'wave' then
      t = e.win.a + math.max(0, math.min(mx - px, w)) / w * (e.win.b - e.win.a)
    else
      -- 视频: 鼠标在时间线区(底部 16px)时不设选区(留给播放头), 仅在图片区设选区
      local ty = py + prev_h - 16
      if mx < ty then
        local total_len = (e.src_len and e.src_len > 0 and e.src_len) or (e.len and e.len > 0 and e.len) or 1
        t = math.max(0, math.min((mx - px) / w, 1)) * total_len
      end
    end
    if t ~= nil then
      if not S.wave_drag or S.wave_drag.id ~= e.id then S.wave_drag = { id = e.id, a = t } end
      S.wave_drag.b = t
    end
  elseif S.wave_drag and S.wave_drag.id == e.id then
    local a, b = S.wave_drag.a, S.wave_drag.b or S.wave_drag.a
    if math.abs(b - a) > 0.005 then
      e.sel = { a = math.min(a, b), b = math.max(a, b) }
    end
    S.wave_drag = nil
  end

  -- ---- 元数据行 ----
  if not compact then
    local meta = {}
    if e.kind == 'item' then
      if e.len then meta[#meta+1] = fmt_t(e.len) .. 's' end
      if e.sr and e.sr > 0 then meta[#meta+1] = ('%d Hz'):format(e.sr) end
      if e.nch and e.nch > 0 then meta[#meta+1] = e.nch .. 'ch' end
      if e.stype == 'SECTION' then meta[#meta+1] = '片段源'
      elseif e.stype == 'REVERSE' then meta[#meta+1] = '反向'
      elseif e.stype == 'MIDI' then meta[#meta+1] = 'MIDI 源'
      elseif e.stype == 'SUBPROJECT' or e.stype == 'PROJREF' then meta[#meta+1] = '工程引用' end
      if e.vol and e.vol ~= 1 then meta[#meta+1] = ('%.1f dB'):format(20 * math.log(math.max(e.vol, 0.0001), 10)) end
      if e.pitch and e.pitch ~= 0 then
        -- D_PITCH 可能是小数 (如 -0.5), %d 会抛 "number has no integer representation"
        local p = ('%.2f'):format(e.pitch):gsub('0+$', ''):gsub('%.$', '')
        meta[#meta+1] = 'pitch ' .. p
      end
      if e.vw and e.vh then meta[#meta+1] = ('%dx%d'):format(e.vw, e.vh) end
      if e.fps then meta[#meta+1] = ('%.2f fps'):format(e.fps) end
    elseif e.kind == 'notes' then
      meta[#meta+1] = #e.notes .. ' 音符'
    elseif e.kind == 'marker' then
      meta[#meta+1] = '原始位置保留, 拖出时整体平移'
    elseif e.kind == 'envelope' then
      meta[#meta+1] = (e.env_name or '包络') .. ' · ' .. #(e.points or {}) .. ' 点'
    end
    if #meta > 0 then
      imgui.PushStyleColor(ctx, imgui.Col_Text, T.text_tri)
      imgui.TextWrapped(ctx, table.concat(meta, '  ·  '))
      imgui.PopStyleColor(ctx)
    end
  end

  -- ---- 操作行: [拖到编曲区(accent)] [选区chip] [切片cycle] ... [信息][删除](右侧) ----
  local drag_label = compact and '拖出' or '⇱ 拖到编曲区'
  if imgui.Button(ctx, ('%s##d%d'):format(drag_label, e.id), compact and 64 or 118, 0) then end
  if imgui.IsItemHovered(ctx) then
    local tip = (S.ui.drop_mode or 'cursor') == 'mouse'
      and '按住拖到编曲区松开 → 插入到鼠标脚下\nShift = 强制瞬态切片'
      or '按住拖到编曲区松开 → 插入到编辑光标处\nShift = 强制瞬态切片'
    imgui.SetTooltip(ctx, tip)
  end
  if imgui.IsItemActive(ctx) then
    if not S.drag or S.drag.id ~= e.id then S.drag = { id = e.id, moved = false } end
    if imgui.IsMouseDragging(ctx, 0) then S.drag.moved = true end
  end
  imgui.SameLine(ctx)
  if e.sel then
    if imgui.SmallButton(ctx, ('选区 %.2fs##s%d'):format(e.sel.b - e.sel.a, e.id)) then e.sel = nil end
    if imgui.IsItemHovered(ctx) then imgui.SetTooltip(ctx, '点击取消波形/视频选区') end
    imgui.SameLine(ctx)
  end
  -- 切片按钮: 仅对可切片的音频 item 显示 (视频/图片/MIDI 不切片)
  local can_slice = (e.kind == 'item' and not e.is_midi
                     and e.fclass ~= 'video' and e.fclass ~= 'image')
  if can_slice then
    local modes = { { 'off', '切片:关' }, { 'fixed', '切片:固定' }, { 'transients', '切片:瞬态' }, { 'beats', '切片:节拍' } }
    local mi = e.slice_mode or S.set.slice_mode or 'off'
    local cur = 1
    for i, mm in ipairs(modes) do if mm[1] == mi then cur = i end end
    if imgui.SmallButton(ctx, ('%s##sm%d'):format(modes[cur][2], e.id)) then
      e.slice_mode = modes[(cur % #modes) + 1][1]
    end
    if imgui.IsItemHovered(ctx) then imgui.SetTooltip(ctx, '点击切换切片模式 (拖出时生效)') end
    imgui.SameLine(ctx)
  end
  -- 右侧: 信息 / 删除 (删除用危险色文字)
  local info_l = compact and '信息' or '信息'
  local del_l   = compact and '删' or '删除'
  local w_info = select(1, imgui.CalcTextSize(ctx, info_l)) + 18
  local w_del  = select(1, imgui.CalcTextSize(ctx, del_l)) + 18
  imgui.SameLine(ctx, math.max(w - w_info - w_del - 6, 0))
  if imgui.SmallButton(ctx, ('%s##i%d'):format(info_l, e.id)) then
    local _, txt = exec_cmd('info', { id = tostring(e.id) })
    log('[CBM] ' .. (txt or '') .. '\n')
    set_toast('info', (txt or ''):gsub('[\r\n].*', ''):sub(1, 80))
  end
  imgui.SameLine(ctx)
  imgui.PushStyleColor(ctx, imgui.Col_Text, T.bad)
  local del_clicked = imgui.SmallButton(ctx, ('%s##x%d'):format(del_l, e.id))
  imgui.PopStyleColor(ctx)
  if del_clicked then remove_entry(e.id) end

  imgui.Dummy(ctx, 0, 2)
end

local function draw_card(e, compact)
  fl.begin_card(ctx, '##cbmcard' .. e.id)
  local ok_body, err_body = pcall(card_body, e, compact)
  fl.end_card(ctx)
  if not ok_body then
    S.card_errs = S.card_errs or {}
    if not S.card_errs[err_body] then
      S.card_errs[err_body] = true
      log(('[CBM CARD ERROR] %s\n'):format(tostring(err_body)))
      -- 静默渲染错误对用户不可见 (DEBUG 关闭时 log 是空操作), 用 toast 显式暴露
      set_toast('bad', '卡片渲染出错: ' .. tostring(err_body):sub(1, 90), 6)
    end
  end
end

-- ============================ 主帧 ============================

local function frame()
  -- 心跳 & 显隐
  r.SetExtState('CBM', 'hb', tostring(os.time()), false)
  local want = r.GetExtState('CBM', 'visible')
  if want == '0' then S.visible = false elseif want == '1' then S.visible = true end

  ipc_poll()

  -- 「📁 本项目」面板跟随当前工程
  sync_proj_board()

  -- Ctrl+C 复制 item/track → 自动捕获 (纯文本忽略)
  pc(watch_clipboard)

  -- 持久化防抖
  if S.dirty and os.clock() - S.last_save > 1.0 then
    S.dirty = false S.last_save = os.clock() entry_save()
  end

  if not S.visible then S.drag = nil return end

  -- ctx 生存期防御: 每帧校验并透明重建 (旧实例 ctx 被 ReaImGui 回收后不再喷错)
  if not ensure_context() then
    if not S.ctx_bad_reported then
      S.ctx_bad_reported = true
      log('[CBM] 无法创建 ReaImGui context\n')
    end
    return
  end

  -- 字体: PushFont(ctx, font, size) —— 0.10 需要三参; 失败静默退回默认字体
  local font_pushed = false
  if FONT_OK and ptr_ok(FONT, 'ImGui_Font*') then
    font_pushed = pcall(imgui.PushFont, ctx, FONT, 15)
    if not font_pushed then FONT_OK = false end
  end
  -- Fluent 主题: 控件颜色/圆角/间距 token, 计数式 push/pop 保证配对
  local nc, nv = fl.push_theme(ctx)
  local FIRST = imgui.Cond_FirstUseEver or 1
  pcall(imgui.SetNextWindowSizeConstraints, ctx, 300, 320, 900, 2400)
  imgui.SetNextWindowPos(ctx, 60, 70, FIRST)
  imgui.SetNextWindowSize(ctx, S.ui.win_w or 440, S.ui.win_h or 800, FIRST)

  local rv, open = imgui.Begin(ctx, 'Clipboard Manager###bstCBM', true)
  if open == false then S.visible = false r.SetExtState('CBM', 'visible', '0', false) end

  if rv then
    local w = select(1, imgui.GetContentRegionAvail(ctx))
    local compact = w < 330

    -- 拖出释放: 在窗口有效上下文内、且每帧输入同步后判断松开
    if S.drag then
      if S.drag.moved then
        local tip = (S.ui.drop_mode or 'cursor') == 'mouse'
          and '松开: 插入到鼠标脚下 | Shift=切片 | Ctrl=渲染导出'
          or '松开: 插入到编辑光标 | Shift=切片 | Ctrl=渲染导出'
        imgui.SetTooltip(ctx, tip)
      end
      if not imgui.IsMouseDown(ctx, 0) then
        if S.drag.moved then
          local e = find_entry(S.drag.id)
          if e then
            local pos, track
            -- drop_mode: 'cursor' 直接落在编辑光标; 'mouse' 取全局鼠标脚下的 arrange 位置
            if (S.ui.drop_mode or 'cursor') == 'mouse' and HAS_SWS then
              local window = pc(r.BR_GetMouseCursorContext)
              if window == 'arrange' then
                local mp = pc(r.BR_GetMouseCursorContext_Position)
                if mp and mp >= 0 then pos = mp end
                track = pc(r.BR_GetMouseCursorContext_Track)
              end
            end
            pos = pos or r.GetCursorPosition()
            if not track_valid(track) then track = resolve_track() end
            local mods = imgui.GetKeyMods(ctx) or 0
            local shift = (mods & (imgui.Mod_Shift or 2)) ~= 0
            local ctrl = (mods & (imgui.Mod_Ctrl or 8)) ~= 0
            if ctrl then
              -- 渲染导出: 把条目写成文件落在工程媒体目录 bst_clips/ 下
              local odir = r.GetProjectPath(''):gsub('[%/\\]+$', '') .. '/bst_clips/'
              r.RecursiveCreateDirectory(odir, 0)
              local fname = tostring(e.title or ('clip_' .. e.id))
                :gsub('[%c%/\\:%*%?"<>|]+', '_')
              local okx, msgx = exec_cmd('export', { id = tostring(e.id), path = odir .. fname })
              set_toast(okx and 'ok' or 'bad', ('渲染导出 · %s'):format(msgx or ''))
              log(('[CBM] 渲染导出: %s · %s\n'):format(odir .. fname, tostring(msgx)))
            else
              local slice = shift and 'transients'
                or (e.slice_mode ~= 'off' and e.slice_mode) or nil
              local ok_d, msg_d = paste_entry(e, pos, track, slice)
              set_toast(ok_d and 'ok' or 'bad', ('拖出 @%s · %s'):format(fmt_t(pos), msg_d or ''))
              log(('[CBM] 拖放 @%s · %s\n'):format(fmt_t(pos), msg_d))
            end
          end
        end
        S.drag = nil
      end
    end

    -- toast 反馈条 (捕获/粘贴/清空等操作结果, 数秒后自动消失)
    if S.toast and os.clock() < S.toast.exp then
      fl.infobar(ctx, S.toast.sev, S.toast.text)
      imgui.Dummy(ctx, 0, 2)
    else
      S.toast = nil
    end

    -- ===== 行 A: 面板栏 (配置文件式切换) + 类型 + 设置 =====
    imgui.PushStyleVar(ctx, imgui.StyleVar_FramePadding, 7, 2.5)
    imgui.PushStyleVar(ctx, imgui.StyleVar_ItemSpacing, 5, 3)
    do
      local ab = get_board(S.active_board) or S.boards[1]
      local abname = ab and ab.name or '?'
      if S.active_board:sub(1, 5) == 'proj:' then abname = '📁 ' .. project_name() end
      imgui.SetNextItemWidth(ctx, math.min(w * 0.36, 168))
      if imgui.BeginCombo(ctx, '##boardsel', abname .. ' (' .. #S.entries .. ')') then
        for _, b in ipairs(S.boards) do
          if imgui.Selectable(ctx, b.name .. '  (' .. #b.entries .. ')##bs_' .. b.id,
                              b.id == S.active_board) then
            switch_board(b.id)
          end
        end
        imgui.Separator(ctx)
        if imgui.Selectable(ctx, '📁 本项目 (按工程独立)##bs_proj') then
          local want = 'proj:' .. project_key()
          ensure_board(want, '📁 ' .. project_name())
          switch_board(want)
        end
        if imgui.Selectable(ctx, '＋ 新建面板…##bs_new') then
          S.renaming = 'new' S.renaming_name = ''
        end
        imgui.EndCombo(ctx)
      end
      if imgui.IsItemHovered(ctx) then
        imgui.SetTooltip(ctx, '剪贴板面板 = 按用途区分的独立历史\n复制/捕获进入当前面板')
      end
      imgui.SameLine(ctx)
      if S.renaming then
        imgui.SetNextItemWidth(ctx, 110)
        local ch_n, nv = imgui.InputTextWithHint(ctx, '##boardname', '面板名…', S.renaming_name or '')
        if ch_n then S.renaming_name = nv end
        imgui.SameLine(ctx)
        if fl.button(ctx, '✓', { accent = true }) then
          local nm = tostring(S.renaming_name or ''):gsub('^%s+', ''):gsub('%s+$', '')
          if nm ~= '' then
            if S.renaming == 'new' then
              local id = 'user_' .. tostring(os.time())
              ensure_board(id, nm)
              switch_board(id)
            else
              local b = get_board(S.active_board)
              if b then b.name = nm S.dirty = true end
            end
          end
          S.renaming = nil
        end
        imgui.SameLine(ctx)
        if fl.button(ctx, '✕', { subtle = true }) then S.renaming = nil end
      else
        local kind_lbl = '全部'
        for _, kc in ipairs(KIND_CHIPS) do if kc.id == S.kind_filter then kind_lbl = kc.label end end
        if imgui.BeginCombo(ctx, '##kindsel', kind_lbl) then
          for _, kc in ipairs(KIND_CHIPS) do
            local n = 0
            for _, e in ipairs(S.entries) do if match_kind(e, kc.id) then n = n + 1 end end
            if imgui.Selectable(ctx, kc.label .. '  (' .. n .. ')##k_' .. kc.id,
                                S.kind_filter == kc.id) then
              S.kind_filter = kc.id
            end
          end
          imgui.EndCombo(ctx)
        end
        if imgui.IsItemHovered(ctx) then imgui.SetTooltip(ctx, '类型筛选') end
        imgui.SameLine(ctx)
        if fl.button(ctx, '设置', { subtle = true }) then
          S.ff_test_msg = nil
          imgui.OpenPopup(ctx, 'settings')
        end
        if imgui.IsItemHovered(ctx) then imgui.SetTooltip(ctx, '打开设置 (含面板管理)') end
      end
    end
    imgui.PopStyleVar(ctx, 2)

    -- ===== 行 B: 搜索 (通配符/记忆) + 捕获 + 清空 =====
    imgui.PushStyleVar(ctx, imgui.StyleVar_FramePadding, 7, 2.5)
    imgui.PushStyleVar(ctx, imgui.StyleVar_ItemSpacing, 5, 3)
    do
      local cap_w, clr_w = 58, compact and 44 or 52
      local hist_w, wild_w = 26, 28
      local fw = math.max(w - cap_w - clr_w - hist_w - wild_w - 36, 60)
      imgui.SetNextItemWidth(ctx, fw)
      local ch_f, fv = imgui.InputTextWithHint(ctx, '##filter', '搜索  (* 任意一串  ? 单字符)', S.filter or '')
      if ch_f then
        if fv and fv ~= '' and imgui.IsItemFocused(ctx)
           and (imgui.IsKeyPressed(ctx, imgui.Key_Enter)
             or imgui.IsKeyPressed(ctx, imgui.Key_KeypadEnter)) then
          hist_add(fv)
        end
        S.filter = fv or ''
      end
      imgui.SameLine(ctx)
      if fl.button(ctx, '▼', { subtle = true, width = hist_w }) then
        imgui.OpenPopup(ctx, 'search_hist')
      end
      if imgui.IsItemHovered(ctx) then imgui.SetTooltip(ctx, '搜索记忆 (搜索框内按 Enter 记录)') end
      imgui.SameLine(ctx)
      if fl.button(ctx, '＊', { subtle = true, width = wild_w }) then
        imgui.OpenPopup(ctx, 'wildcards')
      end
      if imgui.IsItemHovered(ctx) then imgui.SetTooltip(ctx, '通配符快速填入') end
      imgui.SameLine(ctx)
      if fl.button(ctx, '捕获', { accent = true, width = cap_w }) then
        local ok_c, msg_c = exec_cmd('capture')
        set_toast(ok_c and 'ok' or 'warn', msg_c or '')
      end
      if imgui.IsItemHovered(ctx) then
        imgui.SetTooltip(ctx, '捕获当前选中到当前面板\nitem / 轨道 / FX 链 / 包络 / MIDI / 标记')
      end
      imgui.SameLine(ctx)
      local confirming = os.clock() < (S.confirm_clear_until or 0)
      local lbl = confirming and '确认?' or (compact and '清' or '清空')
      local clicked
      if confirming then
        clicked = fl.button(ctx, lbl, { danger = true, width = clr_w + 14 })
      else
        clicked = fl.button(ctx, lbl, { subtle = true, width = clr_w })
      end
      if clicked then
        if confirming then
          S.confirm_clear_until = 0
          local ok_x, msg_x = exec_cmd('clear')
          set_toast(ok_x and 'ok' or 'bad', msg_x or '')
        else
          S.confirm_clear_until = os.clock() + 3
          set_toast('warn', '再点一次「确认」清空当前面板', 3)
        end
      end
      if imgui.IsItemHovered(ctx) then imgui.SetTooltip(ctx, '清空当前面板全部条目 (需二次确认)') end
    end
    imgui.PopStyleVar(ctx, 2)

    -- 搜索记忆弹窗
    if imgui.BeginPopup(ctx, 'search_hist') then
      if #S.search_hist == 0 then
        imgui.TextDisabled(ctx, '(暂无记忆 — 在搜索框按 Enter 记录)')
      else
        for i, term in ipairs(S.search_hist) do
          if imgui.Selectable(ctx, term .. '##h' .. i) then S.filter = term end
        end
        imgui.Dummy(ctx, 0, 2)
        if fl.button(ctx, '清空记忆', { subtle = true, width = -1 }) then
          S.search_hist = {}
          r.SetExtState('CBM', 'search_hist', '', true)
        end
      end
      imgui.EndPopup(ctx)
    end
    -- 通配符快捷面板
    if imgui.BeginPopup(ctx, 'wildcards') then
      fl.caption(ctx, '快速筛选 (点选填入搜索框)')
      local presets = { '*.wav', '*.mid*', '*_loop*', '*_v*', 'kick*', 'sfx_*', '*.mp4' }
      for _, pr in ipairs(presets) do
        if imgui.Selectable(ctx, pr .. '##w') then S.filter = pr end
      end
      imgui.Dummy(ctx, 0, 2)
      imgui.Separator(ctx)
      fl.caption(ctx, '* = 任意一串    ? = 单个字符')
      imgui.EndPopup(ctx)
    end

    -- ===== 设置弹窗 =====
    if imgui.BeginPopupModal(ctx, 'settings', nil) then
      pcall(imgui.SetNextWindowSizeConstraints, ctx, 460, 0, 640, 1400)
      fl.subtitle(ctx, '设置')
      fl.caption(ctx, '与 bst Settings 面板实时互通, 改动立即生效')
      fl.caption(ctx, '捕获/复制进入当前面板: ' ..
        ((get_board(S.active_board) or S.boards[1]).name or '?'))
      do
        local dmodes = { { 'cursor', '编辑光标' }, { 'mouse', '鼠标脚下 (需 SWS)' } }
        local dcur = ((S.ui.drop_mode or 'cursor') == 'mouse') and 2 or 1
        if imgui.BeginCombo(ctx, '拖出落点##dropmode', dmodes[dcur][2]) then
          for i, mm in ipairs(dmodes) do
            if imgui.Selectable(ctx, mm[2], i == dcur) then
              S.ui.drop_mode = mm[1]
              r.SetExtState('CBM_UI', 'ui',
                'drop_mode=' .. mm[1] .. ';win_w=' .. (S.ui.win_w or 440)
                .. ';win_h=' .. (S.ui.win_h or 800), true)
            end
          end
          imgui.EndCombo(ctx)
        end
      end
      fl.caption(ctx, '拖出卡片: 松开=插入 · Ctrl+松开=渲染导出到 <工程>/bst_clips/')
      imgui.Dummy(ctx, 0, 2)
      imgui.Separator(ctx)
      imgui.Dummy(ctx, 0, 2)
      fl.body(ctx, '面板管理')
      do
        local ab = get_board(S.active_board) or S.boards[1]
        if fl.button(ctx, '重命名当前面板', { subtle = true }) then
          S.renaming = 'rename' S.renaming_name = ab and ab.name or ''
        end
        imgui.SameLine(ctx)
        local confirming = os.clock() < (S.del_board_until or 0)
        if fl.button(ctx, confirming and '确认删除?' or '删除当前面板',
                     confirming and { danger = true } or { subtle = true }) then
          if confirming and ab then
            if #S.boards <= 1 then
              set_toast('warn', '至少保留一个面板', 2)
            elseif ab.id == 'global' then
              set_toast('warn', '通用面板不可删除 (可清空)', 2)
            else
              for i, bb in ipairs(S.boards) do
                if bb.id == ab.id then table.remove(S.boards, i) break end
              end
              for _, e in ipairs(ab.entries) do
                if S.pv[e.id] and S.pv[e.id].src then pc(r.PCM_Source_Destroy, S.pv[e.id].src) end
              end
              S.pv = {}
              S.active_board = 'global'
              S.entries = get_board('global').entries
              S.dirty = true
              set_toast('ok', '已删除面板「' .. ab.name .. '」', 2)
            end
            S.del_board_until = 0
          else
            S.del_board_until = os.clock() + 3
          end
        end
        imgui.SameLine(ctx)
        if fl.button(ctx, '清空当前面板', { subtle = true }) then
          local ok_x, msg_x = exec_cmd('clear')
          set_toast(ok_x and 'ok' or 'bad', msg_x or '')
        end
      end
      imgui.Dummy(ctx, 0, 2)

      imgui.Dummy(ctx, 0, 4)
      fl.body(ctx, '捕获')
      imgui.SetNextItemWidth(ctx, 150)
      do
        local c1, v1 = imgui.InputInt(ctx, '历史上限##cap', S.set.cap or 64)
        if c1 then S.set.cap = math.max(v1 or 64, 8) set_save() end
      end

      imgui.Dummy(ctx, 0, 4)
      imgui.Separator(ctx)
      imgui.Dummy(ctx, 0, 2)
      fl.body(ctx, '默认切片 (拖出时未单独指定的 item 使用)')
      do
        local modes = { { 'off', '关闭' }, { 'fixed', '固定时长' },
                        { 'transients', '瞬态检测' }, { 'beats', '节拍网格' } }
        local cur = 1
        for i, mm in ipairs(modes) do if mm[1] == (S.set.slice_mode or 'off') then cur = i end end
        if imgui.BeginCombo(ctx, '模式##slicemode', modes[cur][2]) then
          for i, mm in ipairs(modes) do
            if imgui.Selectable(ctx, mm[2], S.set.slice_mode == mm[1]) then
              S.set.slice_mode = mm[1] set_save()
            end
          end
          imgui.EndCombo(ctx)
        end
        if (S.set.slice_mode or 'off') == 'fixed' then
          imgui.SetNextItemWidth(ctx, 200)
          local c4, v4 = imgui.InputDouble(ctx, '切片秒数##sf', S.set.slice_fixed or 4, 0.5, 1, '%.2f')
          if c4 then S.set.slice_fixed = math.max(v4 or 4, 0.05) set_save() end
        elseif (S.set.slice_mode or 'off') == 'transients' then
          local c3, v3 = imgui.SliderDouble(ctx, '瞬态阈值##st', S.set.slice_thresh or 0.5, 0.05, 0.95, '%.2f')
          if c3 then S.set.slice_thresh = v3 set_save() end
        end
      end

      imgui.Dummy(ctx, 0, 4)
      imgui.Separator(ctx)
      imgui.Dummy(ctx, 0, 2)
      fl.body(ctx, 'ffmpeg 缩略图 (视频 / GIF / 图片)')
      do
        imgui.SetNextItemWidth(ctx, -1)
        local c2, v2 = imgui.InputTextWithHint(ctx, '##ffpath', '留空自动探测; 可填 exe 完整路径或目录',
                                               S.set.ffmpeg or '')
        if c2 then S.set.ffmpeg = v2 or '' FFMPEG = false set_save() end
        imgui.Dummy(ctx, 0, 2)
        local fpath = ffmpeg_path()
        if fpath ~= '' then
          fl.infobar(ctx, 'ok', '已找到: ' .. fit_text(fpath, math.max(w - 60, 60)))
        else
          fl.infobar(ctx, 'warn', '未找到 ffmpeg — 视频/GIF 缩略图不可用')
        end
        imgui.Dummy(ctx, 0, 2)
        if fl.button(ctx, '测试', { subtle = true }) then
          FFMPEG = false
          local p = ffmpeg_path()
          if p ~= '' then
            probe_ffmpeg_candidate(p)
            set_toast('ok', 'ffmpeg 探测成功: ' .. basename(p), 3)
          else
            set_toast('bad', 'ffmpeg 探测失败 — 请填写完整路径后重试', 3)
          end
        end
        if imgui.IsItemHovered(ctx) then imgui.SetTooltip(ctx, '重新探测 ffmpeg (含设置里的手动路径)') end
        imgui.SameLine(ctx)
        if fl.button(ctx, '用 winget 默认路径', { subtle = true }) then
          local lap = os.getenv('LOCALAPPDATA')
          if lap then
            S.set.ffmpeg = lap .. '\\Microsoft\\WinGet\\Links\\ffmpeg.exe'
            FFMPEG = false set_save()
          end
        end
        imgui.SameLine(ctx)
        if fl.button(ctx, '清空缩略图缓存', { subtle = true }) then
          pc(os.remove, CACHE) r.RecursiveCreateDirectory(CACHE, 0)
          set_toast('ok', '缩略图缓存已清空')
        end
      end

      imgui.Dummy(ctx, 0, 6)
      imgui.Separator(ctx)
      imgui.Dummy(ctx, 0, 4)
      do
        local wq, wc = 104, 70
        imgui.SetCursorPosX(ctx, math.max(w - wq - wc - 8, 0))
        if fl.button(ctx, '彻底退出脚本', { danger = true, width = wq }) then
          imgui.CloseCurrentPopup(ctx)
          S.quit = true
        end
        imgui.SameLine(ctx)
        if fl.button(ctx, '关闭', { accent = true, width = wc }) then
          imgui.CloseCurrentPopup(ctx)
        end
      end
      imgui.EndPopup(ctx)
    end

    imgui.Dummy(ctx, 0, 2)

    -- ===== 列表 / 空状态 =====
    local n_shown = 0
    for _, e in ipairs(S.entries) do
      if match_kind(e, S.kind_filter) then n_shown = n_shown + 1 end
    end

    if #S.entries == 0 then
      imgui.Dummy(ctx, 0, 36)
      imgui.SetCursorPosX(ctx, math.max((w - 32) / 2, 0))
      fl.icon(ctx, 'copy', 28)
      imgui.Dummy(ctx, 0, 6)
      do
        local l1 = '剪贴板为空'
        local tw1 = select(1, imgui.CalcTextSize(ctx, l1))
        imgui.SetCursorPosX(ctx, math.max((w - tw1) / 2, 0))
        fl.caption(ctx, l1, T.text_pri)
      end
      imgui.Dummy(ctx, 0, 10)
      do
        local hints = {
          '选中 item/轨道/FX链/包络后点「捕获」',
          'Ctrl+C 复制 item/轨道/FX 链会自动入板',
          '媒体浏览器复制的文件路径也会自动入板',
          '拖出卡片: 松开插入 · Ctrl+松开渲染导出',
        }
        imgui.PushStyleColor(ctx, imgui.Col_Text, T.text_dis)
        for _, htxt in ipairs(hints) do
          local th_ = select(1, imgui.CalcTextSize(ctx, htxt))
          imgui.SetCursorPosX(ctx, math.max((w - th_) / 2, 0))
          imgui.Text(ctx, htxt)
          imgui.Dummy(ctx, 0, 2)
        end
        imgui.PopStyleColor(ctx)
      end
    elseif n_shown == 0 then
      imgui.Dummy(ctx, 0, 24)
      do
        local l1 = '没有匹配的条目 — 调整上方筛选或搜索词'
        local tw1 = select(1, imgui.CalcTextSize(ctx, l1))
        imgui.SetCursorPosX(ctx, math.max((w - tw1) / 2, 0))
        imgui.PushStyleColor(ctx, imgui.Col_Text, T.text_dis)
        imgui.Text(ctx, l1)
        imgui.PopStyleColor(ctx)
      end
    else
      if imgui.BeginChild(ctx, '##list') then
        -- 逐卡片 pcall 保护在 draw_card 内部 (begin_card/end_card 始终配对),
        -- 单张卡片异常不会打断 BeginChild/EndChild 配对
        for _, e in ipairs(S.entries) do
          if match_kind(e, S.kind_filter)
             and (S.filter == '' or wildcard_match((e.title or ''):lower(), S.filter:lower())) then
            draw_card(e, compact)
            imgui.Dummy(ctx, 0, 4)
          end
        end
        imgui.EndChild(ctx)
      end
    end

    -- ===== 状态条 (画在窗口 drawlist 上, 不用 child —— 规避裁剪断言坑) =====
    imgui.Dummy(ctx, 0, 2)
    do
      local dl = imgui.GetWindowDrawList(ctx)
      local x1, y1 = imgui.GetCursorScreenPos(ctx)
      local sw = select(1, imgui.GetContentRegionAvail(ctx))
      local sh = 24
      imgui.Dummy(ctx, math.max(sw, 0), sh)
      imgui.DrawList_AddRectFilled(dl, x1, y1, x1 + sw, y1 + sh, T.bg_2, 6)
      local filt_lbl
      for _, kc in ipairs(KIND_CHIPS) do
        if kc.id == S.kind_filter and kc.id ~= 'all' then filt_lbl = kc.label end
      end
      local ab2 = get_board(S.active_board)
      local stxt = string.format('%d 条目 · %s%s%s', n_shown,
        (ab2 and ab2.name) or '?',
        filt_lbl and (' · ' .. filt_lbl) or '',
        (S.filter ~= '') and ' · 搜索中' or '')
      imgui.DrawList_AddText(dl, x1 + 10, y1 + 5, T.text_tri, stxt)
      imgui.DrawList_AddCircleFilled(dl, x1 + sw - 66, y1 + sh / 2, 3, HAS_SWS and T.ok or T.bad)
      imgui.DrawList_AddText(dl, x1 + sw - 57, y1 + 5, T.text_tri, 'SWS')
      imgui.DrawList_AddCircleFilled(dl, x1 + sw - 26, y1 + sh / 2, 3, ffmpeg_path() ~= '' and T.ok or T.bad)
      imgui.DrawList_AddText(dl, x1 + sw - 17, y1 + 5, T.text_tri, 'FF')
    end

    imgui.End(ctx)  -- 必须与 Begin 配对: 仅当 Begin 返回 true 时才 End
  end
  fl.pop_theme(ctx, nc, nv)
  if font_pushed then pc(imgui.PopFont, ctx) end
end

-- ============================ 字体 & 指针工具 ============================

FONT, FONT_OK = nil, false

ptr_ok = function(p, ty)
  if not p then return false end
  if not imgui.ValidatePtr then return true end
  local ok, v1, v2 = pcall(imgui.ValidatePtr, p, ty)
  if not ok then return false end
  return (v1 == true) or (v1 == 1) or (v2 == true) or (v2 == 1)
end

-- 正文字体: CJK 字形必须来自系统中文字体 (ReaImGui 默认字体不含汉字)
load_font = function()
  for _, fp in ipairs({ 'C:/Windows/Fonts/simhei.ttf', 'C:/Windows/Fonts/Deng.ttf',
                        'C:/Windows/Fonts/msyh.ttc', 'C:/Windows/Fonts/simsun.ttc' }) do
    local ok, f = pcall(imgui.CreateFontFromFile, fp)
    if ok and f and ptr_ok(f, 'ImGui_Font*') then
      local aok = pcall(imgui.Attach, ctx, f)
      if not aok then log('[CBM] Attach 字体失败: ' .. tostring(fp) .. '\n') end
      return f, aok
    end
  end
  return nil, false
end
FONT, FONT_OK = load_font()

-- Fluent 图标字体 (Segoe Fluent Icons / MDI2 回退) + 文字角色使用 CJK UI 字体
fl.attach_fonts(ctx)
fl.set_ui_font(FONT_OK and FONT or nil)

-- 启动诊断
log(('[CBM] ImGui %s | ctx valid:%s | font:%s | icon_font:%s\n'):format(
  tostring(pc(imgui.GetVersion) or '?'),
  tostring(ptr_ok(ctx, 'ImGui_Context*')),
  tostring(FONT ~= nil),
  tostring(fl.icon_font ~= nil)))

-- ============================ 启动 ============================

-- 注意: 不在此处做 hb 单实例阻断 —— 那会让「重新运行脚本以加载新代码」失效
-- (REAPER 重新运行同一 action 会先终止旧的 defer 循环)。由 REAPER 的 defer
-- 机制保证同一 command 只保留一个循环; ctx 失效由 ensure_context 透明重建。

local _, _, _, cmdid = r.get_action_context()
if cmdid and cmdid > 0 then r.SetExtState('CBM', 'main_cmd', tostring(cmdid), true) end
r.SetExtState('CBM', 'visible', '1', false)

-- TEMP 指针文件供 CLI 定位
do
  local tmp = os.getenv('TEMP') or os.getenv('TMP') or RES
  write_file(tmp .. '/cbm_reaper_path.txt', RES .. '\n' .. IPC_DIR)
end

entry_load()

-- 剪贴板监视自测 (启动时读一次, 区分可用性)
do
  local test = cf_get_big()
  log(('[CBM] 剪贴板读取%s\n'):format(
    test and ('可用 (len='..#test..')') or '失败/为空'))
end

local function loop()
  if S.quit then
    r.SetExtState('CBM', 'hb', '0', false)
    -- 部分构建不导出 DestroyContext; pc 包装, 失败静默 (ReaImGui 会自动回收)
    if ctx and imgui.DestroyContext then pc(imgui.DestroyContext, ctx) end
    return
  end
  local ok, err = pcall(frame)
  if not ok then
    S.errs = S.errs or {}
    if not S.errs[err] then
      S.errs[err] = true
      log(('[CBM ERROR] %s\n'):format(tostring(err)))
    end
  end
  r.defer(loop)
end
loop()
