# Hermes 管理脚本集

> Hermes Agent 系统管理的 Bash 脚本套件

## 文件清单

| 文件 | 说明 |
|:---|:---|
| `hermes-backup-v2.sh` | 主脚本 — 备份/恢复/Gateway 管理/健康检查/模型管理 |
| `hermes-model-manager.sh` | 模型管理模块 — 查看/测试/切换/新增/编辑/删除供应商模型 |

## 使用方法

```bash
# 交互式菜单
bash hermes-backup-v2.sh

# 命令行模式
bash hermes-backup-v2.sh backup    # 立即备份
bash hermes-backup-v2.sh list      # 查看备份列表
bash hermes-backup-v2.sh restore   # 恢复备份
bash hermes-backup-v2.sh gs        # Gateway 状态
bash hermes-backup-v2.sh rg        # 重启 Gateway
bash hermes-backup-v2.sh doctor    # 健康检查
bash hermes-backup-v2.sh model     # 模型管理

# 独立运行模型管理
bash hermes-model-manager.sh
```

## 功能特性

- 一键备份/恢复 Hermes 配置（config.yaml, .env, skills, cron, memories 等 13 项）
- Gateway 状态监控、启动、停止、重启
- 系统健康检查（`hermes doctor`）
- 模型配置概览、API 连通性测试、供应商切换
- 角色模型管理（新增/编辑/删除供应商模型）
- 自动保留最近 10 个备份
