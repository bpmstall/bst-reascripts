# bst: Wwise Pipeline — Wwise WAAPI 自动化导入

> **对标**: `Audiokinetic WAAPI Pipeline`  
> **定位**: 选中 REAPER 资产一键直通 Wwise 生成层级容器与 Play Event

---

## 面板预览

![bst Wwise Pipeline](../img/wwise_pipeline.png)

---

## 1. 核心概述

现代 3A/二次元游戏音频工作流中，REAPER 负责声音设计，Wwise 负责逻辑挂接。`bst Wwise Pipeline` 允许设计师在 REAPER 中框选设计好的音效条目，直接导出符合 Wwise Tab-Delimited 标准的层级定义文件，自动在 Wwise `Actor-Mixer Hierarchy` 创建指定的 Random Container / Blend Container，并一键自动创建关联的 Play Event。

---

## 2. 参数与控件说明

- **Actor-Mixer Path**: 指定挂载到的 Wwise 目标 Work Unit 与父容器层级路径。
- **Container Type**:
  - `Random Container`: 自动将选中的多个变奏打包为随机容器（适合脚步、受击、射击）。
  - `Blend Container`: 自动将多层声音组合为混合容器（适合技能分层复合音）。
  - `Sequence Container`: 序列容器。
- **Generate Play Event**: 勾选后自动为容器在 `Events` 层级下生成同名 Play Event。
- **Event path**: Play Event 放置的目标路径。

---

## 3. 操作按钮

- **Export Wwise import list**: 一键生成 Wwise 导入清单与容器定义文件。
