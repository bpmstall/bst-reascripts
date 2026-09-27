# bst ReaScripts

游戏音频 / 专业音效设计向的 REAPER 脚本套件 (前缀 `bst`)，基于 Fluent 2 设计风格 (ReaImGui 0.10+)，全面复刻与超越社区顶级商业音效设计工具链 (nvk 全套系列、LKC 系列、X-Raym 系列、Sexan 系列)，支持通过 **ReaPack** 一键安装与持续更新。

---

## 精选面板预览

| bst Create (nvk_CREATE 式分层生成) | bst Subproject (nvk_SUBPROJECT 式工作流) |
| :---: | :---: |
| ![bst Create](img/create.png) | ![bst Subproject](img/subproject.png) |

| bst Whoosh (动作挥砍与破空生成) | bst Align (音效对齐与等间距排版) |
| :---: | :---: |
| ![bst Whoosh](img/whoosh.png) | ![bst Align](img/align.png) |

| bst GrimSync (游戏音频增量镜像同步) | bst Wwise Pipeline (Wwise 直通工作台) |
| :---: | :---: |
| ![bst GrimSync](img/grimsync.png) | ![bst Wwise Pipeline](img/wwise_pipeline.png) |

---

## 核心工具矩阵与独立技术文档

| 工具名称 | 对标商业原作 | 核心功能定位 | 详细使用文档 |
| --- | --- | --- | --- |
| **`bst Create`** | `nvk_CREATE` | 关键词素材库搜索 + 4 层声音设计 + 瞬态 RMS 对齐 + 批量变奏 + 就地换选 | [查看文档](Docs/bst_Create.md) |
| **`bst Subproject`** | `nvk_SUBPROJECT` | 一键打包分层轨为子工程 + 自动精准标定 `=START`/`=END` 标记 + 代理静默更新 | [查看文档](Docs/bst_Subproject.md) |
| **`bst Folder Items`**| `nvk_FOLDER_ITEMS` | 父折叠轨母控 Item 容器 + 子轨素材聚类识别 + 移动/缩放联动 + 级联智能重命名 | [查看文档](Docs/bst_Folder_Items.md) |
| **`bst Takes`** | `nvk_TAKES` | 多 Take 瞬态起音精准吸附重合（防切换打架）+ Implode/Explode 转换 + 批量微调 | [查看文档](Docs/bst_Takes.md) |
| **`bst Propagate`** | `nvk_PROPAGATE` | 变奏属性广播同步：淡变曲线/音量/声像/音高/长度从母版一键同步到批处理目标 | [查看文档](Docs/bst_Propagate.md) |
| **`bst Whoosh`** | 动作音效必备 | 动作挥砍破空设计：自动音高俯冲抬升包络 (Pitch Bend) + Apex 能量汇聚 + 声像横扫 | [查看文档](Docs/bst_Whoosh.md) |
| **`bst Align`** | 排版对齐必备 | 类似平面设计的对齐面板：水平等间距分布 (按自定义 Gap) + 跨轨瞬态垂直精准吸附 | [查看文档](Docs/bst_Align.md) |
| **`bst UCS Renamer`** | 工业交付标准 | 遵循全球 UCS 8.2 标准规范的游戏音效快速分类与批量自增重命名 | [查看文档](Docs/bst_UCS_Renamer.md) |
| **`bst GrimSync`** | `LKC GrimSync` (~$40) | 游戏音频增量镜像同步：REAPER 渲染目录与 Wwise/引擎目录双向比对与一键交付 | [查看文档](Docs/bst_GrimSync.md) |
| **`bst Wwise Pipeline`**| `WAAPI Pipeline` | Wwise WAAPI 自动化直通：选中音频直达 Wwise 层级 + 自动建容器 + 生成 Play Event | [查看文档](Docs/bst_Wwise_Pipeline.md) |
| **`bst PolyGlue`** | `LKC PolyGlue` (~$30) | 跨轨多层智能胶合：自动捕获起落边界并合并为复合条目 (无需反复建轨) | [查看文档](Docs/bst_PolyGlue.md) |
| **`bst Slicer`** | `X-Raym Split` (~$50) | 瞬态智能批量切片：录音长采样无破音切割 + 去静音 + 自动设吸附点与防爆音淡化 | [查看文档](Docs/bst_Slicer.md) |
| **`bst Elastic Warp`**| `Sexan Warp` | 弹性音频瞬态对齐：瞬态自动打 Stretch Markers 手柄 + 贴合视频打击帧与节奏点 | [查看文档](Docs/bst_Elastic_Warp.md) |
| **`bst Auto Doppler`**| `nvk_AUTODOPPLER` | 分析 Item RMS 峰值时刻，自动吸附并为配套 JSFX / 第三方多普勒写路径自动化 | [查看文档](Docs/bst_Auto_Doppler.md) |
| **`bst Loopmaker`** | `nvk_LOOPMAKER` | 零交叉对齐 + 头尾交叉淡化，批量产出无缝循环音频并自动开启循环源 | [查看文档](Docs/bst_Loopmaker.md) |
| **`bst Variations`** | `nvk_VARIATIONS` | 瞬时批量音效变奏工作台 (音高/音量/声像/内容平移) 与 4 档免 GUI 动作 | [查看文档](Docs/bst_Variations.md) |
| **`bst Search Palette`**| `nvk_SEARCH` | 键盘流全局命令面板：轨道(t)/条目(i)/标记(m)/FX(f)/脚本(s) 极速直达 | [查看文档](Docs/bst_Search_Palette.md) |
| **`bst SD Toolbox`** | 一体化工作台 | 声音设计工具箱：变奏/淡变/归一化/重命名/渲染一体化 Fluent 面板 | [查看文档](Docs/bst_SD_Toolbox.md) |
| **`bst Render Blocks`**| `LKC RenderBlocks` | 渲染块管理：音效资产区块化命名、相对尾音与已渲染状态着色管理 | [查看文档](Docs/bst_Render_Blocks.md) |
| **`bst Clipboard (CBM)`**| 智能剪贴板 | 捕获 Item/轨道/标记/包络/MIDI → 波形预览选区切片 → 鼠标拖出粘贴 | [查看文档](Docs/bst_Clipboard_Manager.md) |

---

## 通过 ReaPack 安装

1. REAPER 菜单 `Extensions > ReaPack > Manage repositories…`
2. 点 `Add`，填入本仓库索引地址：

   ```
   https://github.com/bpmstall/bst-reascripts/raw/main/index.xml
   ```
   (国内网络若拉不到 raw.githubusercontent.com，可用上面的 github.com/raw 形式，二者等价)

3. `Extensions > ReaPack > Browse packages`，按分类整组安装 (`BST Sound Tools` 内的 `bst_lib` / `bst_fluent` 是必需依赖)。
4. 安装后在 REAPER 动作列表搜 `bst:` 或 `Custom: bst` 即可。

## 环境要求

- REAPER 7+
- [ReaImGui](https://reapack.com) 扩展 (v0.10+)
- SWS 扩展 (可选，提升拖出与部分时间线计算性能)
- 全局设置持久化存于 ExtState 段 `OxTools`
