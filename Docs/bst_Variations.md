# bst: Variations — 变奏生成器与快捷动作

> **对标**: `nvk_VARIATIONS` / `LKC Variator`
> **定位**: 瞬时生成批量音效变奏（音高/音量/声像/内容窗口平移），含 4 档快捷预设

---

## 1. 核心概述

游戏音效极忌“同音重复”（Machine Gun Effect）。本套件提供可视化完整工作台（`bst Variation generator.lua`）及 4 个一键独立免 GUI 动作（可绑定快捷键）：
- `bst Variations Light`: 微变奏（微小 pitch 与 vol 浮动，适合脚步、UI）
- `bst Variations Medium`: 中度变奏（适合打击、枪击）
- `bst Variations Heavy`: 剧烈变奏（大幅度 pitch、随机内容窗口滑移，适合怪物咆哮、爆炸碎片）
- `bst Variations Studio`: 严谨高保真变奏

---

## 2. 核心参数

- **音高抖动 (pitch_st)**: 随机半音偏差，保留算法开启。
- **音量抖动 (vol_db)**: 随机 dB 衰减或增益。
- **内容窗口滑移 (content_pct)**: 在源文件可动范围内平移起始点，产生不同的采样质感。
- **淡变抖动 (fade_max_ms)**: 随机化起落淡化。
