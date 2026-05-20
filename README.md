# AI Bridge Tools

这一仓库保存 `AI_Bridge` 的外部运维脚本，不和桥本体放在同一个仓库里。

## 包含内容

- `update_bridge.ps1`：从 GitHub 拉取最新桥版本，先备份桌面桥，再覆盖到最新版本。
- `upload_bridge.ps1`：把桌面桥当前变更上传到 GitHub，自动打版本标签并生成报告。
- `launchers/更新.bat`：桌面入口，调用更新脚本。
- `launchers/上传.bat`：桌面入口，调用上传脚本。
- `launchers/同步.bat`：桌面入口，等同于上传。

## 设计原则

- 工具放在桥仓库外，避免更新桥时把脚本自己覆盖掉。
- 每次更新和上传前先备份到桌面 `Backup/AI_Bridge`。
- 每次运行都会生成报告到 `Backup/AI_Bridge/reports`。

## 建议目录

把本仓库放在桌面：

`C:\Users\你的用户名\Desktop\BridgeTools`

## 首次使用

1. 克隆本仓库到桌面，并命名为 `BridgeTools`。
2. 把 `launchers` 目录里的三个 `.bat` 文件复制到桌面。
3. 确保桌面已有 `AI_Bridge` 仓库，且系统 `PATH` 里有 `git`。

## 常用方式

- 更新桥：运行 `更新.bat`
- 上传桥：运行 `上传.bat`
- 同步桥：运行 `同步.bat`

## 版本规则

- 默认上传按补丁号递增，例如 `1.1 -> 1.1.1 -> 1.1.2`
- 只有明确要求升小版本时，才进入 `1.2`

## 依赖

- Windows PowerShell 5.1+
- Git
- Robocopy