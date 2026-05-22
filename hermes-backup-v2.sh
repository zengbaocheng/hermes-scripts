#!/bin/bash
#==============================================================
# Hermes 备份与恢复管理脚本 v1.0
# 基于官方文档：https://hermes-agent.nousresearch.com/docs/
# 功能：自动备份 / 手动备份 / 选择恢复 / Gateway 管理 / 健康检查
#==============================================================
set -euo pipefail

#---------------- 配置区 ----------------
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
BACKUP_DIR="${HERMES_HOME}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
KEEP_COUNT=10
PID_FILE="${HERMES_HOME}/gateway.pid"

# 加载模型管理模块
MODEL_MODULE="$(dirname "$(readlink -f "$0")")/hermes-model-manager.sh"
[[ -f "$MODEL_MODULE" ]] && source "$MODEL_MODULE" || log_info "模型管理模块未安装"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

#---------------- 工具函数 ----------------
log_info()  { echo "[INFO] $1"; }
log_ok()    { echo "[OK] $1"; }
log_warn()  { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1"; }
log_step()  { echo "[STEP] $1"; }
log_bold()  { echo "**$1**"; }

# 获取 Gateway PID（gateway.pid 是 JSON 格式）
get_gateway_pid() {
    if [[ -f "$PID_FILE" ]]; then
        grep -o '"pid": *[0-9]*' "$PID_FILE" 2>/dev/null | grep -o '[0-9]*' || echo ""
    else
        echo ""
    fi
}

# 检查进程是否存在
is_running() {
    local pid=$1
    kill -0 "$pid" 2>/dev/null
}

#---------------- Gateway 管理 ----------------
gateway_status() {
    local pid=$(get_gateway_pid)
    echo ""
    echo "===== Hermes Gateway 状态 ====="
    if [[ -n "$pid" ]] && is_running "$pid"; then
        log_ok "Gateway 运行中 (PID: $pid)"
        if command -v ps &>/dev/null; then
            ps -p "$pid" -o pid,ppid,etime,cmd --no-headers 2>/dev/null | while read line; do
                echo "  $line"
            done
        fi
    else
        log_warn "Gateway 未运行"
    fi

    echo ""
    echo "===== Systemd 服务 ====="
    if command -v systemctl &>/dev/null; then
        if systemctl --user is-active --quiet hermes-gateway 2>/dev/null; then
            log_ok "hermes-gateway.service 活跃"
        else
            log_warn "hermes-gateway.service 未活跃"
        fi
    fi

    echo ""
    echo "===== Hermes 相关进程 ====="
    if command -v ps &>/dev/null; then
        ps aux 2>/dev/null | grep -E 'hermes|gateway' | grep -v grep | while read line; do
            echo "  $line"
        done || log_warn "无法获取进程列表"
    fi
    echo ""
 log_ok "Gateway 状态检查完成"
}

gateway_start() {
    log_step "启动 Hermes Gateway..."
    if systemctl --user start hermes-gateway 2>/dev/null; then
        log_ok "Gateway 已启动 (systemd)"
    else
        log_warn "systemd 启动失败，尝试直接启动..."
        nohup hermes gateway run > "${HERMES_HOME}/logs/gateway.log" 2>&1 &
        sleep 2
        if is_running "$(get_gateway_pid)"; then
            log_ok "Gateway 已启动 (PID: $(get_gateway_pid))"
        else
            log_error "Gateway 启动失败，请检查日志"
        fi
    fi
}

gateway_stop() {
    log_step "停止 Hermes Gateway..."
    local pid=$(get_gateway_pid)
    if [[ -n "$pid" ]] && is_running "$pid"; then
        # 先尝试 systemctl（带超时）
        if command -v systemctl &>/dev/null; then
            timeout 5 systemctl --user stop hermes-gateway 2>/dev/null && log_ok "Gateway 已停止 (systemd)" || {
                log_warn "systemd 停止超时，尝试直接 kill..."
                kill "$pid" 2>/dev/null && log_ok "Gateway 已停止 (PID: $pid)"
            }
        else
            kill "$pid" 2>/dev/null && log_ok "Gateway 已停止 (PID: $pid)"
        fi
        sleep 1
    else
        log_warn "Gateway 未运行"
    fi
}

gateway_restart() {
    log_step "重启 Hermes Gateway..."
    gateway_stop
    sleep 2
    gateway_start
}

#---------------- 备份核心 ----------------
do_backup() {
    local label="${1:-}"
    local backup_name="hermes_backup_${TIMESTAMP}${label:+_${label}}"
    local backup_path="${BACKUP_DIR}/${backup_name}"

    log_step "开始备份: ${backup_name}"

    # 创建备份目录
    mkdir -p "$backup_path"

    # 备份项定义（基于官方 Key Paths）
    declare -A BACKUP_ITEMS=(
        ["config.yaml"]="${HERMES_HOME}/config.yaml"
        [".env"]="${HERMES_HOME}/.env"
        ["auth.json"]="${HERMES_HOME}/auth.json"
        ["gateway_state.json"]="${HERMES_HOME}/gateway_state.json"
        ["vendor_models.json"]="${HERMES_HOME}/vendor_models.json"
        ["channel_directory.json"]="${HERMES_HOME}/channel_directory.json"
        ["version_history.json"]="${HERMES_HOME}/version_history.json"
    )

    # 备份配置文件
    local backup_count=0
    for name in "${!BACKUP_ITEMS[@]}"; do
        local src="${BACKUP_ITEMS[$name]}"
        if [[ -f "$src" ]]; then
            cp -p "$src" "${backup_path}/${name}"
            ((backup_count++)) || true
            log_info "  ✓ $name"
        fi
    done

    # 备份目录
    declare -A BACKUP_DIRS=(
        ["skills"]="${HERMES_HOME}/skills"
        ["cron"]="${HERMES_HOME}/cron"
        ["memories"]="${HERMES_HOME}/memories"
        ["scripts"]="${HERMES_HOME}/scripts"
        ["plugins"]="${HERMES_HOME}/plugins"
        ["profiles"]="${HERMES_HOME}/profiles"
    )

    for name in "${!BACKUP_DIRS[@]}"; do
        local src="${BACKUP_DIRS[$name]}"
        if [[ -d "$src" ]]; then
            cp -rp "$src" "${backup_path}/${name}"
            ((backup_count++)) || true
            log_info "  ✓ $name/ (目录)"
        fi
    done

    # 备份快照状态（不含大文件）
    if [[ -d "${HERMES_HOME}/state-snapshots" ]]; then
        # 只备份快照索引，不备份快照内容（太大）
        if [[ -f "${HERMES_HOME}/state-snapshots/index.json" ]]; then
            cp -p "${HERMES_HOME}/state-snapshots/index.json" "${backup_path}/state-snapshots-index.json"
            log_info "  ✓ state-snapshots/index.json"
        fi
    fi

    # 创建备份清单
    cat > "${backup_path}/MANIFEST.txt" << EOF
Hermes Backup Manifest
======================
Backup Time: $(date '+%Y-%m-%d %H:%M:%S')
Hermes Home: $HERMES_HOME
Hostname: $(hostname)
Hermes Version: $(hermes --version 2>/dev/null || echo "unknown")

Included Items:
$(ls -la "$backup_path" 2>/dev/null | tail -n +2 || echo "  (empty)")

Excluded (auto-rebuilt or too large):
  - state-snapshots/ (内容太大，保留索引)
  - sessions/ (自动重建)
  - logs/ (自动重建)
  - cache/ (自动重建)
  - state.db (自动重建)
EOF

    # 计算备份大小
    local size=$(du -sh "$backup_path" 2>/dev/null | cut -f1 || echo "unknown")
    log_ok "备份完成: ${backup_path}"
    log_info "备份大小: ${size}"
    log_info "包含 ${backup_count} 个项目"

    # 自动清理旧备份（保留最近 KEEP_COUNT 个）
    cleanup_old_backups
}

# 清理旧备份
cleanup_old_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then return; fi

    local count=$(ls -1d "${BACKUP_DIR}"/hermes_backup_* 2>/dev/null | wc -l || echo 0)
    if [[ "$count" -gt "$KEEP_COUNT" ]]; then
        log_info "清理旧备份（保留 ${KEEP_COUNT} 个）..."
        ls -1dt "${BACKUP_DIR}"/hermes_backup_* 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) | while read old_backup; do
            rm -rf "$old_backup" && log_info "  已删除: $(basename "$old_backup")"
        done
    fi
}

#---------------- 恢复核心 ----------------
do_restore() {
    local backup_path="$1"
    local auto="${2:-false}"

    # 验证备份
    if [[ ! -d "$backup_path" ]]; then
        log_error "备份不存在: $backup_path"
        return 1
    fi

    # 显示备份信息
    echo ""
    echo -e "${BOLD}========== 备份信息 ==========${RESET}"
    if [[ -f "${backup_path}/MANIFEST.txt" ]]; then
        cat "${backup_path}/MANIFEST.txt"
    fi
    echo ""
    echo -e "${BOLD}备份内容:${RESET}"
    ls -la "$backup_path" | tail -n +2
    echo ""

    # 确认恢复
    if [[ "$auto" != "true" ]]; then
        echo -e "${YELLOW}⚠️  警告：恢复将覆盖当前配置！${RESET}"
        read -rp "确认恢复？输入 YES 继续: " confirm
        if [[ "$confirm" != "YES" ]]; then
            log_warn "已取消恢复"
            return 0
        fi
    fi

    # 停止 Hermes
    log_step "停止 Hermes..."
    gateway_stop
    sleep 2

    # 恢复配置文件
    log_step "恢复配置文件..."
    for file in config.yaml .env auth.json gateway_state.json vendor_models.json channel_directory.json version_history.json; do
        if [[ -f "${backup_path}/${file}" ]]; then
            cp -p "${backup_path}/${file}" "${HERMES_HOME}/${file}"
            log_info "  ✓ $file"
        fi
    done

    # 恢复目录
    log_step "恢复目录..."
    for dir in skills cron memories scripts plugins profiles; do
        if [[ -d "${backup_path}/${dir}" ]]; then
            # 备份现有目录
            if [[ -d "${HERMES_HOME}/${dir}" ]]; then
                mv "${HERMES_HOME}/${dir}" "${HERMES_HOME}/${dir}.bak.${TIMESTAMP}"
            fi
            cp -rp "${backup_path}/${dir}" "${HERMES_HOME}/${dir}"
            log_info "  ✓ $dir/"
        fi
    done

    # 恢复快照索引
    if [[ -f "${backup_path}/state-snapshots-index.json" ]]; then
        mkdir -p "${HERMES_HOME}/state-snapshots"
        cp -p "${backup_path}/state-snapshots-index.json" "${HERMES_HOME}/state-snapshots/index.json"
        log_info "  ✓ state-snapshots/index.json"
    fi

    log_ok "恢复完成！"

    # 重启 Hermes
    log_step "重启 Hermes Gateway..."
    sleep 2
    gateway_start
}

#---------------- 主菜单 ----------------
show_menu() {
    echo ""
    echo -e "${BOLD}================================================${RESET}"
    echo -e "${BOLD}    Hermes 备份与恢复管理脚本 v1.0${RESET}"
    echo -e "${BOLD}    官方文档: hermes-agent.nousresearch.com${RESET}"
    echo -e "${BOLD}================================================${RESET}"
    echo ""
    echo -e "${CYAN}  [1]${RESET} 备份当前配置"
    echo -e "${CYAN}  [2]${RESET} 列出所有备份"
    echo -e "${CYAN}  [3]${RESET} 选择备份恢复"
    echo -e "${CYAN}  [4]${RESET} 删除旧备份"
    echo -e "${CYAN}  [5]${RESET} Gateway 状态"
    echo -e "${CYAN}  [6]${RESET} 重启 Gateway"
    echo -e "${CYAN}  [7]${RESET} 启动 Gateway"
    echo -e "${CYAN}  [8]${RESET} 停止 Gateway"
    echo -e "${CYAN}  [9]${RESET} 健康检查 (hermes doctor)"
    echo -e "${CYAN}  [a]${RESET} 导出 Profile (hermes profile export)"
    echo -e "${CYAN}  [i]${RESET} 导入 Profile (hermes profile import)"
    echo -e "${CYAN}  [s]${RESET} 备份技能库 (curator backup)"
    echo -e "${CYAN}  [e]${RESET} 导出会话 (sessions export)"
    echo -e "${CYAN}  [m]${RESET} 模型管理 (查看/测试/切换)"
    echo -e "${CYAN}  [0]${RESET} 退出"
    echo ""
}

#---------------- 主程序 ----------------
main() {
    # 确保备份目录存在
    mkdir -p "$BACKUP_DIR"

    case "${1:-menu}" in
        backup|1)
            do_backup
            ;;
        list|2)
            echo ""
            echo -e "${BOLD}========== 所有备份 ==========${RESET}"
            if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
                log_warn "暂无备份"
            else
                ls -laht "$BACKUP_DIR" | grep hermes_backup | while read line; do
                    echo "  $line"
                done
            fi
            echo ""
            ;;
        restore|3)
            echo ""
            echo -e "${BOLD}========== 选择要恢复的备份 ==========${RESET}"
            local backups=($(ls -dt "${BACKUP_DIR}"/hermes_backup_* 2>/dev/null))
            if [[ ${#backups[@]} -eq 0 ]]; then
                log_warn "暂无备份"
                return
            fi
            echo "选择备份:"
            for i in "${!backups[@]}"; do
                local name=$(basename "${backups[$i]}")
                local size=$(du -sh "${backups[$i]}" 2>/dev/null | cut -f1 || echo "?")
                local date=$(ls -la "${backups[$i]}" 2>/dev/null | awk '{print $6,$7,$8}' | head -1)
                echo -e "  ${CYAN}[$i]${RESET} ${name} (${size}, ${date})"
            done
            echo ""
            read -rp "请输入编号 [0-${#backups[@]}]: " idx || true
            if [[ -z "$idx" ]]; then
                log_warn "已取消"
                return 0
            elif [[ "$idx" -ge 0 ]] && [[ "$idx" -lt "${#backups[@]}" ]]; then
                do_restore "${backups[$idx]}"
            else
                log_error "无效选择"
            fi
            ;;
        delete|4)
            echo ""
            echo -e "${BOLD}========== 删除旧备份 ==========${RESET}"
            local backups=($(ls -dt "${BACKUP_DIR}"/hermes_backup_* 2>/dev/null))
            if [[ ${#backups[@]} -eq 0 ]]; then
                log_warn "暂无备份"
                return
            fi
            echo "选择要删除的备份（保留最近 ${KEEP_COUNT} 个）:"
            for i in "${!backups[@]}"; do
                local name=$(basename "${backups[$i]}")
                local size=$(du -sh "${backups[$i]}" 2>/dev/null | cut -f1 || echo "?")
                local date=$(ls -la "${backups[$i]}" 2>/dev/null | awk '{print $6,$7,$8}' | head -1)
                echo -e "  ${CYAN}[$i]${RESET} ${name} (${size}, ${date})"
            done
            echo ""
            read -rp "请输入要删除的编号（逗号分隔，如 0,2,3），或直接回车退出: " idx || true
            if [[ -z "$idx" ]]; then
                log_warn "已取消"
                return 0
            fi
            IFS=',' read -ra idxs <<< "$idx"
            for id in "${idxs[@]}"; do
                id=$(echo "$id" | tr -d ' ')
                if [[ -n "$id" ]] && [[ "$id" -ge 0 ]] && [[ "$id" -lt "${#backups[@]}" ]]; then
                    rm -rf "${backups[$id]}" && log_ok "已删除: $(basename "${backups[$id]}")"
                fi
            done
            ;;
        status|gs|5)
            gateway_status
            ;;
        rg|restart|6)
            gateway_restart
            ;;
        gstart|start|7)
            gateway_start
            ;;
        gstop|stop|8)
            gateway_stop
            ;;
        doctor|9)
            log_step "运行 hermes doctor..."
            hermes doctor
            ;;
        profile-export|a)
            echo ""
            echo -e "${BOLD}========== 导出 Profile ==========${RESET}"
            echo "可用 Profile:"
            hermes profile list 2>/dev/null || log_error "无法获取 Profile 列表"
            echo ""
            read -rp "输入要导出的 Profile 名称: " profile_name
            if [[ -n "$profile_name" ]]; then
                local export_file="${HERMES_HOME}/backups/${profile_name}_$(date +%Y%m%d).tar.gz"
                hermes profile export "$profile_name" "$export_file" 2>/dev/null && \
                    log_ok "已导出: $export_file" || log_error "导出失败"
            fi
            ;;
        profile-import|i)
            echo ""
            echo -e "${BOLD}========== 导入 Profile ==========${RESET}"
            local tar_files=($(ls -t "${HERMES_HOME}"/backups/*.tar.gz 2>/dev/null))
            if [[ ${#tar_files[@]} -eq 0 ]]; then
                log_warn "没有找到 .tar.gz 备份文件"
                return
            fi
            echo "可用 Profile 备份:"
            for i in "${!tar_files[@]}"; do
                echo -e "  ${CYAN}[$i]${RESET} $(basename "${tar_files[$i]}")"
            done
            echo ""
            read -rp "选择文件编号: " idx
            if [[ -n "$idx" ]] && [[ "$idx" -ge 0 ]] && [[ "$idx" -lt "${#tar_files[@]}" ]]; then
                hermes profile import "${tar_files[$idx]}" 2>/dev/null && \
                    log_ok "已导入" || log_error "导入失败"
            fi
            ;;
        skill-backup|s)
            log_step "备份技能库..."
            if command -v hermes &>/dev/null; then
                hermes curator backup 2>/dev/null && log_ok "技能库备份完成" || log_warn "curator backup 不可用"
            else
                log_error "hermes 命令不可用"
            fi
            ;;
        session-export|e)
            echo ""
            echo -e "${BOLD}========== 导出会话 ==========${RESET}"
            local export_file="${HERMES_HOME}/backups/sessions_export_$(date +%Y%m%d_%H%M%S).jsonl"
            timeout 30 hermes sessions export "$export_file" 2>/dev/null && \
                log_ok "已导出: $export_file" || log_error "导出失败（超时或无会话）"
            ;;
        model|m)
            model_submenu
            ;;
        help|h|0)
            echo ""
            echo -e "${BOLD}Hermes 备份与恢复管理脚本 v1.0${RESET}"
            echo ""
            echo "用法: $0 <命令>"
            echo ""
            echo -e "${BOLD}备份与恢复:${RESET}"
            echo "  backup          立即备份"
            echo "  list            列出所有备份"
            echo "  restore         选择备份恢复（交互式）"
            echo "  delete          删除备份"
            echo ""
            echo -e "${BOLD}Gateway 管理:${RESET}"
            echo "  gs / status     Gateway 状态"
            echo "  rg / restart     重启 Gateway"
            echo "  start / gstart  启动 Gateway"
            echo "  stop / gstop    停止 Gateway"
            echo ""
            echo -e "${BOLD}系统工具:${RESET}"
            echo "  doctor          健康检查"
            echo "  profile-export  导出 Profile"
            echo "  profile-import  导入 Profile"
            echo "  skill-backup    备份技能库"
            echo "  session-export  导出会话"
            echo ""
            echo -e "${BOLD}模型管理:${RESET}"
            echo "  model           模型管理子菜单（查看/测试/切换）"
            echo ""
            echo "直接运行脚本 $0 进入交互菜单"
            echo ""
            ;;
        menu)
            while true; do
                show_menu
                read -rp "请选择操作 [0-9]: " choice || { echo ""; echo "输入结束"; break; }
                echo ""
                if [[ -z "$choice" ]]; then
                    echo "[WARN] 请输入选项编号"
                    continue
                fi
                case "$choice" in
 0) echo "再见!"; break ;;
 *) main "$choice"
    echo ""
    read -rp "按回车键继续..." _dummy
    ;;
 esac
            done
            ;;
        *)
            log_error "未知命令: $1"
            echo "使用 $0 help 查看帮助"
            ;;
    esac
}

main "$@"