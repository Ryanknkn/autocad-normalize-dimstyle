# AutoCAD Normalize Dimstyle

一个用于 Codex 的 AutoCAD 2025 Skill，可在独立的隐藏 AutoCAD 实例中备份并标准化单个 DWG 的尺寸样式。

## 功能

- 保留并统一使用真正的 `ISO-25` 尺寸样式。
- 文字高度设为 `4`。
- 箭头大小设为 `2.5`。
- 总体比例设为 `1`。
- 尺寸线、尺寸界线和尺寸文字颜色设为 `ByLayer`。
- 线性尺寸精度固定为 `0.0`（`DIMDEC=1`）。
- 小数分隔符固定为句点 `.`。
- 尺寸使用的文字样式固定高度设为 `0`。
- 将尺寸、传统引线和形位公差对象移动到 `DIM` 图层；图层不存在时自动创建。
- 处理模型空间、布局以及非 XREF 块定义中的对象。
- 不修改外部参照文件，只在结果中报告 XREF。
- 删除除 `ISO-25` 和 XREF 依赖样式以外的其他本地尺寸样式。

除上述固定参数外，其余设置沿用目标图纸原有的 `ISO-25`。

## 安全机制

- 目标 DWG 必须已经保存并关闭。
- 检测到 `.dwl` 或 `.dwl2` 锁文件时拒绝处理。
- 修改前创建 `原文件名_修改前_yyyyMMdd_HHmmss.dwg` 备份。
- 使用文件长度和 SHA-256 校验备份。
- 先保存到同目录临时 DWG，重新打开并验证后才覆盖目标文件。
- 处理或验证失败时自动用已校验的备份恢复目标文件。
- 始终保留修改前备份。
- 使用独立的隐藏 AutoCAD 2025 实例，不连接正在使用的前台 AutoCAD。

## 环境要求

- Windows
- AutoCAD 2025，自动化对象为 `AutoCAD.Application.25`
- Windows PowerShell 5.1，使用 STA 模式
- Codex

## 安装

将本仓库克隆或复制到个人 Codex Skills 目录：

```text
%USERPROFILE%\.codex\skills\autocad-normalize-dimstyle
```

目录结构应为：

```text
autocad-normalize-dimstyle/
├── SKILL.md
├── agents/
│   └── openai.yaml
└── scripts/
    ├── normalize-dimstyle.lsp
    └── normalize-dimstyle.ps1
```

重新打开 Codex 后即可使用。

## 在 Codex 中使用

示例：

```text
使用 $autocad-normalize-dimstyle 处理 "D:\CAD\example.dwg"
```

也可以自然描述：

```text
请在后台备份并统一这张 DWG 的 ISO-25 尺寸样式。
```

Skill 每次处理一个 DWG。需要批量处理时，可让 Codex 先核对文件数量，再逐一调用此 Skill。

## 直接运行脚本

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File ".\scripts\normalize-dimstyle.ps1" `
  -Path "D:\CAD\example.dwg"
```

脚本输出 JSON 报告，包含：

- 目标文件与备份路径
- 处理的尺寸、引线和公差数量
- 删除的尺寸样式数量
- 最终尺寸参数、`0.0` 精度和 `DIM` 图层验证结果
- XREF 名称及依赖尺寸样式
- 备份和最终文件的 SHA-256
- 成功、恢复或失败状态

## 许可证

[MIT License](LICENSE)
