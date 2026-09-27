# bst: Takes — 多 Take 变奏工作流

> **对标**: `nvk_TAKES`
> **定位**: 游戏音效多 Take 瞬态重合对齐、多轨合并/拆解与批量变奏

---

## 1. 核心概述

制作受击声、枪击声、脚步声等高频重复的声音时，音效师常将多个变奏存储在单个 Item 的多个 Takes 中。`bst Takes` 解决了多 Take 之间起音点不一致导致切换时“打架”、以及多轨素材与 Takes 相互转换的繁琐痛点。

---

## 2. 功能详解

- **一键对齐所有 Take 起音瞬态 (Transient Alignment)**:
  - 传统手动对齐多个 Take 的击打点需反复调整 `Start Offset`。
  - 本功能逐一分析 Item 内部每个 Take 的起音 RMS 峰值，自动平移各 Take 的 `D_STARTOFFS`，使切换任何 Take 时打击瞬间完全重叠，瞬态凝聚度 100%。
- **多 Take 变奏微调 (Take Shaping)**:
  - 批量对选中 Item 内部所有 Takes 进行随机音高（±st）、随机音量增益（±dB）、随机声像偏移，一键让原本单调的变奏库更加自然生动。
- **结构转换**:
  - **合并为多 Takes (Implode)**: 将平行铺在多轨或横向选中的多个 Items 压缩进单条目的多个 Takes。
  - **拆解为独立轨 (Explode)**: 将单个条目的所有 Takes 展开为纵向平行轨道，方便单独挂效果器。
