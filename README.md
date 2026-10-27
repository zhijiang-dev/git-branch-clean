# git-branch-clean

剪掉远程已经删除、本地还留着的 Git 分支。

在一个目录下找出多个 Git 仓库，勾选要处理的仓库后，只删除跟踪状态为 `gone` 的本地分支。当前分支，以及 `main`、`master`、`develop` 会跳过。没有设置过上游的本地分支不会动。

需要 Windows、PowerShell 5.1 和 Git。

## 从 VS Code 运行

在资源管理器的 **NPM SCRIPTS** 里运行 `gitclean`。终端会询问扫描目录：

- 直接回车：使用本工具所在目录的上一级。
- 输入路径：扫描该目录，例如 `E:\work`。

然后用键盘选择仓库：

| 按键 | 作用 |
| --- | --- |
| 上 / 下 | 移动当前行 |
| 空格 | 勾选或取消 |
| 回车 | 清理已勾选的仓库 |
| Esc | 取消，不删除任何分支 |

一个仓库都没勾选就按回车，也会直接退出。

## 从终端运行

在任意目录清理当前目录往下 3 层：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\gitclean.ps1
```

指定目录、查找层数，并额外跳过 `release`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\gitclean.ps1 -Root D:\work,E:\repos -Depth 2 -Keep release
```

`-Root` 可以写多个目录。`-Depth` 默认是 `3`。`-Keep` 追加保护分支，默认的 `main`、`master`、`develop` 仍然保留。

只运行一次安装脚本，就能在新的 PowerShell 窗口里直接输入 `gitclean`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

安装脚本把命令写进当前用户的 PowerShell 配置文件，不修改系统环境变量。已有同名函数时不会重复追加。

## 清理规则

对每个勾选的仓库执行 `git fetch -p`，再从 `git branch -vv` 里找出带 `: gone]` 的本地分支并执行 `git branch -D`。

这些分支会留下：

- 当前检出的分支
- `main`、`master`、`develop`
- `-Keep` 里追加的分支
- 从未设置上游的本地分支

某个仓库拉取失败，或某个分支删除失败时，会记下错误并继续处理其余仓库。结束时输出选中仓库数、命中分支数、已删除数、跳过数和失败数。

路径中包含 `node_modules` 的目录不会被当成待扫描仓库。

## 文件

| 文件 | 作用 |
| --- | --- |
| `package.json` | VS Code NPM 脚本入口 |
| `gitclean-npm.ps1` | 询问扫描目录后启动清理 |
| `gitclean.ps1` | 命令行入口 |
| `GitClean.psm1` | 查找仓库、勾选和删除分支 |
| `Install.ps1` | 把 `gitclean` 写入 PowerShell 配置文件 |
