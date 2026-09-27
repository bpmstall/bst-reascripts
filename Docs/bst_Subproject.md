# bst: Subproject — 子工程工作流助手

> **对标**: `nvk_SUBPROJECT`  
> **定位**: 复杂分层音效打包隔离、渲染边界自动化校准与代理静默更新

---

## 面板预览

![bst Subproject](../img/subproject.png)

---

## 1. 核心概述

现代游戏音频项目中，单个音效动辄包含数十轨素材、包络与效果器链。若全部散落在主工程中，会导致工程卡顿、视线混乱且难于协同。`bst Subproject` 实现了主工程与子工程（Subproject / `.rpp`）之间的极速打包、无损迁移、边界自动标定与静默代理更新。

---

## 2. 参数与控件说明

### 2.1 状态感应
- **Active: Main Project**: 面板自动显示打包操作，可选择将「选中的轨道/文件夹」或「选中的 Items 所在轨道」一键收纳进子工程。
- **Active: Subproject Tab**: 当用户在子工程标签页时，面板自动感应环境，提供一键对齐标记与代理渲染。

### 2.2 渲染边界自动标定 (=START / =END)
REAPER 渲染 Subproject 时依据 `=START` 和 `=END` 标记判定范围。音效师经常在修改子工程后由于尾音变化导致代理被截断或留白过长。
- **Head (s)**: 给音效起始留出安全缓冲（默认 0s）。
- **Tail (s)**: 为残响/延迟尾音留出缓冲（默认 0.5s，可调至 5.0s）。
- **Auto-save & render RPP-PROX**: 校准标记后自动静默保存工程并生成 `.rpp-prox` 代理。

---

## 3. 操作按钮

- **Sync markers**: 扫描子工程所有未静音的 Items 边界，精确写入 `=START` 与 `=END` 标记并更新代理。
- **Pack selected tracks**: 将选中轨道及分层一键迁移到独立子工程，主工程原位替换为轻量代理条目。
- **Pack selected items' tracks**: 将选中 Items 所在轨道打包为子工程。
