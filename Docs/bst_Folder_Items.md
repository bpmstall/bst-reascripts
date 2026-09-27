# bst: Folder Items — 折叠轨容器管理

> **对标**: `nvk_FOLDER_ITEMS`
> **定位**: 父折叠轨总控 Item 容器、子轨素材联动与级联重命名

---

## 1. 核心概述

在 REAPER 中，子轨道的素材虽归属于父折叠轨（Folder Track），但移动、复制、重命名父轨时子轨素材无法直观联动。`bst Folder Items` 通过在父折叠轨上智能分析子轨音频片段并创建等宽的“母控容器条目”（Folder Items），让多层音效作为一个整体被管理。

---

## 2. 功能详解

- **自动识别并生成 Folder Items**:
  - 自动检测折叠轨下方所有子轨道的 Item 分布，将时间紧密或重叠的子轨素材聚类为一个声音事件块。
  - 在父折叠轨对应时间区间自动建立母控条目。
- **左右余量 (Padding ms)**: 为母控条目提供前后安全时间边缘。
- **色彩同步 (Color Sync)**: 自动将折叠轨的配色同步赋予生成的 Folder Item。
- **自动群组绑定 (Auto Group)**: 生成时自动将 Folder Item 与其包含的所有子轨 Items 绑定为同一 Group，移动母块即同步移动所有子层。
- **级联重命名 (Cascade Naming)**: 选中折叠轨上的 Folder Item（如命为 `SFX_Skill_Cast`），点击级联重命名，所有子轨对应素材自动命名为 `SFX_Skill_Cast_轨道名`。
- **联动选中**: 选中 Folder Item 点击按钮可瞬时点选所有隶属的子轨素材。
