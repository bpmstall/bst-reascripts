> **Chinese** | [English](README.md)

# bst-reascripts

面向游戏音频和声音设计的 REAPER 脚本集，Fluent 2 风格界面。

灵感来自 nvk、LKC、X-Raym、Sexan 等工作流。

## 安装

### 通过 ReaPack 安装（推荐）

1. 打开 REAPER
2. 菜单 **Extensions → ReaPack → Import repositories**
3. 粘贴这个地址：

```
https://raw.githubusercontent.com/bpmstall/bst-reascripts/main/index.xml
```

4. 点 OK，然后 **Extensions → ReaPack → Browse packages**
5. 搜索 "bst" 安装需要的脚本
6. **注意**：先装 `bst_lib.lua` 和 `bst_fluent.lua`，其他脚本依赖它们
7. 在 REAPER 动作列表里搜 "bst" 就能找到

### 连不上？

- 确认用的是上面 **raw.githubusercontent.com** 开头的地址，不是 github.com 页面地址
- 国内网络可能需要代理才能访问 raw.githubusercontent.com
- 也可以试 Extensions → ReaPack → Manage repositories → Add 手动添加

### 环境要求

- REAPER 7+
- [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) v0.10+（通过 ReaPack 默认仓库安装）

## 脚本一览

### 分层设计与生成
- **bst Create** — 多层声音设计，素材库搜索 + 瞬态对齐 + 批量变奏
- **bst Whoosh** — 破空/挥砍音效生成，自动写 pitch bend + 声像横扫

### 工程管理
- **bst Subproject** — 打包轨道为子工程，自动标记 =START/=END
- **bst Folder Items** — 文件夹轨容器 Item，级联重命名
- **bst Takes** — 多 Take 瞬态对齐，合并/拆分转换

### 编辑与对齐
- **bst Align** — 水平等间距排布 / 跨轨瞬态垂直对齐
- **bst Propagate** — 从母版一键同步淡变、音量、声像、音高到所有目标
- **bst Elastic Warp** — 在瞬态位置自动打 Stretch Markers

### 处理与切片
- **bst Slicer** — 按瞬态阈值自动切片，去静音，加微淡化
- **bst PolyGlue** — 跨轨多层素材一键胶合为单个 Item
- **bst Loopmaker** — 零交叉 + 交叉淡化，生成无缝循环
- **bst Variations** — 批量随机化音高、音量、声像

### 游戏音频管线
- **bst GrimSync** — 渲染目录与引擎/Wwise 目录增量同步
- **bst Wwise Pipeline** — 生成 Wwise 导入清单、容器和 Play Event
- **bst UCS Renamer** — UCS 8.2 标准分类批量重命名

### 实用工具
- **bst Search Palette** — 全局命令面板，模糊搜索轨道/Item/标记/FX/脚本
- **bst SD Toolbox** — 声音设计一体化面板
- **bst Clipboard Manager** — 可视化剪贴板，波形预览 + 拖出粘贴
- **bst Render Blocks** — 渲染块管理，状态追踪与尾音控制
- **bst Auto Doppler** — 根据 RMS 峰值自动写多普勒自动化

## 文档

每个脚本的详细说明和截图在 [`Docs/`](Docs/) 目录。

## 截图

| bst Create | bst Subproject |
|:---:|:---:|
| ![](img/create.png) | ![](img/subproject.png) |

| bst Whoosh | bst Align |
|:---:|:---:|
| ![](img/whoosh.png) | ![](img/align.png) |

| bst GrimSync | bst Wwise Pipeline |
|:---:|:---:|
| ![](img/grimsync.png) | ![](img/wwise_pipeline.png) |

## 反馈

问题反馈：[GitHub Issues](https://github.com/bpmstall/bst-reascripts/issues)

REAPER 论坛：[Cockos REAPER Forums](https://forum.cockos.com)
