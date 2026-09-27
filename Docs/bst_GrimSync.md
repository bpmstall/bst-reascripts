# bst: GrimSync — 游戏音频增量镜像同步

> **对标**: `LKC GrimSync`  
> **定位**: 游戏音效资产从 REAPER 渲染目录向游戏工程 / Wwise 目标目录无感知镜像同步

---

## 面板预览

![bst GrimSync](../img/grimsync.png)

---

## 1. 核心概述

在游戏音频交付阶段，音效师每修改一个声音都需要重新导出并手动拷贝覆盖到游戏工程目录（如 Unreal Content 目录、Unity Assets 目录或 Wwise 导入文件夹），繁琐且极易漏掉变奏。`bst GrimSync` 自动扫描渲染源目录与目标工程目录，基于文件差异比对（新增/更新/一致），一键增量同步覆盖，带覆盖前自动备份保护。

---

## 2. 参数与控件说明

- **Source Directory (REAPER Render)**: REAPER 渲染输出源目录。
- **Target Directory (Game Engine / Wwise)**: 游戏引擎或 Wwise 音频目标目录。
- **Backup overwritten files**: 覆盖前自动备份已有旧音频文件。

---

## 3. 操作按钮

- **Compare diff**: 极速比对两端目录，列出待新增（绿色）与待覆盖更新（蓝色）的音频资产。
- **Mirror & Sync**: 仅增量拷贝有改动的文件，跳过未修改文件，毫秒级无感知同步交付。
