# bst ReaScripts

游戏音频 / 音效设计向的 REAPER 脚本套件(前缀 `bst`),Fluent 2 风格 UI,支持通过
**ReaPack** 一键安装与更新。

两组脚本:

| 分类 | 内容 |
| --- | --- |
| BST Sound Tools | 声音设计工具箱、搜索面板、零交叉裁剪循环、变奏工作台、渲染块、批量渲染、归一化、take 重命名等 11 个文件(含共享库 `bst_lib.lua` / `bst_fluent.lua`) |
| BST Clipboard | 剪贴板管理器:捕获 item/轨道/标记/包络/MIDI → 波形预览选区切片 → 拖出粘贴,共 11 个文件 |

## 通过 ReaPack 安装

1. REAPER 菜单 `Extensions > ReaPack > Manage repositories…`
2. 点 `Add`,填入本仓库索引地址:

   ```
   https://raw.githubusercontent.com/YOUR_USERNAME/bst-reascripts/main/index.xml
   ```

3. `Extensions > ReaPack > Browse packages`,按分类整组安装
   (BST Sound Tools 内的 `bst_lib` / `bst_fluent` 是必需依赖)。
4. 安装后动作列表搜 `bst:` 即可;建议手动把 **bst: 智能复制** 绑到 Ctrl+C。

> 把上面 URL 与 index.xml 里的 `YOUR_USERNAME` 替换成实际 GitHub 用户名。
> 一键替换:`sed -i 's/YOUR_USERNAME/<你的用户名>/g' index.xml`

## 本地开发

- 真源码目录:`%APPDATA%\REAPER\Scripts\bst`(工具)与 `%APPDATA%\REAPER\Scripts\CBM`(剪贴板)
- 本仓库内容与其保持一致;改动后重新拷贝并提交即可
- 回归测试:`oxtools_testing/run_tests.sh`(126 断言)+ `run_cbm_tests.sh`(32 断言)

## 发布新版本

1. 改完脚本后,在 `index.xml` 对应 `<reapack>` 里追加一个更高版本号的
   `<version>` 块(URL 不变),ReaPack 会自动提示用户升级
2. `git add -A && git commit -m "..." && git push`

## 兼容性说明

- 需要 REAPER 7+、[ReaImGui](https://reapack.com) 扩展;SWS 可选(拖出落点跟随鼠标需要)
- 设置存于 ExtState 段 `OxTools`(工具)与 `CBM` / `CBM_UI`(剪贴板),从旧版 OxTools 升级无需重配
