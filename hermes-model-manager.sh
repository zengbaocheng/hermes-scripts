#=================================================================
# 模型管理模块 - 查看/测试/切换模型配置
#=================================================================

CONFIG_FILE="${HERMES_HOME}/config.yaml"
VENDOR_FILE="${HERMES_HOME}/vendor_models.json"

# 从 config.yaml 获取值
get_cfg_val() {
    grep "^$1:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*: *//' | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//"
}

# 模型配置概览
model_overview() {
    echo ""
    echo -e "${BOLD}========== 模型配置概览 ==========${RESET}"
    echo ""
    
    local main_model=$(get_cfg_val "  default")
    local main_provider=$(get_cfg_val "  provider")
    local main_base=$(get_cfg_val "  base_url")
    local vision_provider=$(grep -A5 "vision:" "$CONFIG_FILE" 2>/dev/null | grep "provider:" | head -1 | awk '{print $2}')
    local vision_model=$(grep -A5 "vision:" "$CONFIG_FILE" 2>/dev/null | grep "model:" | head -1 | awk '{print $2}')
    
    echo -e "${CYAN}■ 主模型:${RESET} $main_model"
    echo -e "${CYAN}  供应商:${RESET} $main_provider"
    echo -e "${CYAN}  接口:${RESET} $main_base"
    echo ""
    echo -e "${CYAN}■ 视觉模型:${RESET} $vision_model"
    echo -e "${CYAN}  供应商:${RESET} $vision_provider"
    echo ""
    
    # 备用模型链
    echo -e "${CYAN}■ 备用模型链:${RESET}"
    local fallback_list=$(hermes fallback list 2>/dev/null || echo "无")
    if [[ "$fallback_list" == "无" ]] || [[ -z "$fallback_list" ]]; then
        log_info "  未配置备用模型"
    else
        echo "$fallback_list" | while read line; do
            echo "  $line"
        done
    fi
    echo ""
    
    # 供应商信息
    echo -e "${CYAN}■ 已认证供应商:${RESET}"
    if command -v hermes &>/dev/null; then
        hermes auth list 2>/dev/null | head -10 || echo "  暂无"
    fi
    echo ""
    
    log_ok "模型配置概览完成"
}

# 角色模型列表（vendor_models.json）
model_role_list() {
    echo ""
    echo -e "${BOLD}========== 角色模型配置 ==========${RESET}"
    echo ""
    
    if [[ ! -f "$VENDOR_FILE" ]]; then
        log_warn "未找到 vendor_models.json"
        return
    fi
    
    local roles=$(python3 -c "
import json, sys
with open('$VENDOR_FILE') as f:
    d = json.load(f)
for k,v in d.items():
    if k.startswith('_'): continue
    cur = v.get('current','?')
    pri = v.get('primary',{}).get('model','?')
    falls = [fb.get('model','?') for fb in v.get('fallbacks',[])]
    av = '\033[0;32m✓\033[0m' if v.get('primary',{}).get('available',False) else '\033[0;31m✗\033[0m'
    falls_str = ', '.join(falls) if falls else '无'
    print(f'{k}:')
    print(f'  主选: {pri} {av}')
    print(f'  当前: {cur}')
    print(f'  备用: {falls_str}')
    print()
" 2>/dev/null) || {
        log_error "解析 vendor_models.json 失败"
        return
    }
    
    echo -e "$roles"
    
    local check_time=$(python3 -c "
import json
with open('$VENDOR_FILE') as f:
    d = json.load(f)
print(d.get('_last_check','未知'))
" 2>/dev/null)
    
    echo -e "${CYAN}最后检测时间:${RESET} $check_time"
    echo ""
    log_ok "角色模型列表读取完成"
}

# 测试API连通性（通用）
model_test_api() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"
    local label="$4"
    
    echo -n "  ${label}..."
    
    # 提取 base URL（去掉 /v1, /chat/completions 等）
    local endpoint="${base_url%/}"
    [[ "$endpoint" != *"/chat/completions" ]] && endpoint="${endpoint}/chat/completions"
    
    local response
    response=$(curl -s -w "\n%{http_code}" --max-time 15 \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -d '{"model":"'"$model"'","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}' \
        "$endpoint" 2>/dev/null) || true
    
    local http_code=$(echo "$response" | tail -1)
    local body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        local ok_msg=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:30])" 2>/dev/null || echo "API正常")
        echo -e "\r  ${GREEN}${label}: ✓ $ok_msg${RESET}"
        return 0
    else
        local err_msg=$(echo "$body" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message','unknown'))" 2>/dev/null || echo "HTTP $http_code")
        echo -e "\r  ${RED}${label}: ✗ $err_msg${RESET}"
        return 1
    fi
}

# 测试主模型
model_test_main() {
    echo ""
    echo -e "${BOLD}========== 测试主模型 ==========${RESET}"
    
    local model=$(get_cfg_val "  default")
    local provider=$(get_cfg_val "  provider")
    local base_url=$(get_cfg_val "  base_url")
    local api_key=$(get_cfg_val "  api_key")
    
    # 从.env获取API KEY（如果config没有）
    if [[ -z "$api_key" ]]; then
        local provider_upper=$(echo "$provider" | tr '[:lower:]-' '[:upper:]_')
        api_key="${provider_upper}_API_KEY"
        api_key="${!api_key:-}"
    fi
    
    if [[ -z "$api_key" ]]; then
        log_warn "未找到 API Key（尝试从 .env 读取）"
        # 尝试从 .env 文件读取
        if [[ -f "${HERMES_HOME}/.env" ]]; then
            api_key=$(grep -o 'API_KEY=[^[:space:]]*' "${HERMES_HOME}/.env" | head -1 | cut -d= -f2- || true)
        fi
    fi
    
    if [[ -z "$model" ]] || [[ -z "$base_url" ]]; then
        log_error "模型配置不完整"
        return
    fi
    
    echo -e "${CYAN}模型:${RESET} $model"
    echo -e "${CYAN}供应商:${RESET} $provider"
    echo -e "${CYAN}接口:${RESET} $base_url"
    [[ -n "$api_key" ]] && echo -e "${CYAN}API Key:${RESET} ${api_key:0:8}..."
    echo ""
    
    log_step "发送测试请求..."
    model_test_api "$base_url" "$api_key" "$model" "主模型"
    
    echo ""
    log_ok "主模型测试完成"
}

# 测试视觉模型
model_test_vision() {
    echo ""
    echo -e "${BOLD}========== 测试视觉模型 ==========${RESET}"
    
    local vision_provider=$(grep -A5 "vision:" "$CONFIG_FILE" 2>/dev/null | grep "provider:" | head -1 | awk '{print $2}')
    local vision_model=$(grep -A5 "vision:" "$CONFIG_FILE" 2>/dev/null | grep "model:" | head -1 | awk '{print $2}')
    local vision_base=$(grep -A5 "vision:" "$CONFIG_FILE" 2>/dev/null | grep "base_url:" | head -1 | awk '{print $2}' | sed "s/^'//;s/'$//" | sed 's/^"//;s/"$//')
    
    if [[ -z "$vision_model" ]]; then
        log_warn "未配置视觉模型"
        return
    fi
    
    echo -e "${CYAN}模型:${RESET} $vision_model"
    echo -e "${CYAN}供应商:${RESET} $vision_provider"
    echo -e "${CYAN}接口:${RESET} ${vision_base:-OpenRouter默认}"
    echo ""
    
    log_step "发送测试请求..."
    
    # 视觉模型通常走 OpenRouter
    local api_url="${vision_base:-https://openrouter.ai/api/v1/chat/completions}"
    local api_key="${OPENROUTER_API_KEY:-}"
    
    if [[ -z "$api_key" ]] && [[ -f "${HERMES_HOME}/.env" ]]; then
        api_key=$(grep 'OPENROUTER_API_KEY' "${HERMES_HOME}/.env" | head -1 | cut -d= -f2- || true)
    fi
    
    if [[ -z "$api_key" ]]; then
        log_error "未找到 OpenRouter API Key"
        return
    fi
    
    model_test_api "$api_url" "$api_key" "$vision_model" "视觉模型"
    echo ""
    log_ok "视觉模型测试完成"
}

# 测试所有角色模型
model_test_all_roles() {
    echo ""
    echo -e "${BOLD}========== 测试所有角色模型 ==========${RESET}"
    echo ""
    
    if [[ ! -f "$VENDOR_FILE" ]]; then
        log_warn "未找到 vendor_models.json"
        return
    fi
    
    # 获取 OpenRouter API Key
    local api_key="${OPENROUTER_API_KEY:-}"
    if [[ -z "$api_key" ]] && [[ -f "${HERMES_HOME}/.env" ]]; then
        api_key=$(grep 'OPENROUTER_API_KEY' "${HERMES_HOME}/.env" | head -1 | cut -d= -f2- || true)
    fi
    
    if [[ -z "$api_key" ]]; then
        log_error "未找到 OpenRouter API Key，无法测试角色模型"
        return
    fi
    
    local api_url="https://openrouter.ai/api/v1/chat/completions"
    local tested=0
    local passed=0
    
    python3 -c "
import json
with open('$VENDOR_FILE') as f:
    d = json.load(f)
roles = [(k, v) for k, v in d.items() if not k.startswith('_')]
for name, cfg in roles:
    primary = cfg.get('primary', {}).get('model', '')
    current = cfg.get('current', '')
    print(f'{name}|{primary}|{current}')
" 2>/dev/null | while IFS='|' read -r role primary current; do
    # 测试当前使用的模型
    local test_model="${current:-$primary}"
    [[ -z "$test_model" ]] && { log_warn "  跳过 $role: 无模型配置"; return; }
    
    echo -e "  ${CYAN}[$role]${RESET} 测试: $test_model"
    model_test_api "$api_url" "$api_key" "$test_model" "  → $role"
    echo ""
done || true
    
    echo ""
    log_ok "角色模型测试完成"
}

# 模型切换向导
model_switch_wizard() {
    echo ""
    echo -e "${BOLD}========== 切换模型/供应商 ==========${RESET}"
    echo ""
    echo -e "${YELLOW}⚠️  注意：修改会立即生效！${RESET}"
    echo ""
    
    # 显示当前
    local cur_model=$(get_cfg_val "  default")
    local cur_provider=$(get_cfg_val "  provider")
    echo -e "当前配置: ${CYAN}$cur_model${RESET} (${CYAN}$cur_provider${RESET})"
    echo ""
    
    # 提供商选择
    echo "选择供应商："
    echo "  [1] OpenRouter (通用)"
    echo "  [2] NVIDIA (nvidia)"
    echo "  [3] Token.sensenova.cn (当前)"
    echo "  [4] OpenAI"
    echo "  [5] 自定义"
    echo "  [0] 取消"
    echo ""
    read -rp "请选择 [0-5]: " prov_choice || return
    
    local new_provider new_base
    case "$prov_choice" in
        1) new_provider="openrouter"; new_base="https://openrouter.ai/api/v1" ;;
        2) new_provider="nvidia"; new_base="https://integrate.api.nvidia.com/v1" ;;
        3) new_provider="custom"; new_base="https://token.sensenova.cn/v1" ;;
        4) new_provider="openai"; new_base="https://api.openai.com/v1" ;;
        5) 
            read -rp "自定义供应商名称: " new_provider
            read -rp "Base URL: " new_base
            ;;
        0|*) log_warn "已取消"; return ;;
    esac
    
    read -rp "模型名称 (如 gpt-4o, deepseek-v4-flash): " new_model
    [[ -z "$new_model" ]] && { log_error "模型名称不能为空"; return; }
    
    # 确认
    echo ""
    echo -e "${YELLOW}即将修改:${RESET}"
    echo "  供应商: $cur_provider → $new_provider"
    echo "  模型:   $cur_model → $new_model"
    echo "  Base:   $cur_base → $new_base"
    echo ""
    read -rp "确认？输入 YES 继续: " confirm
    [[ "$confirm" != "YES" ]] && { log_warn "已取消"; return; }
    
    # 应用配置（使用 hermes config set）
    log_step "应用新配置..."
    if command -v hermes &>/dev/null; then
        hermes config set model.default "$new_model" 2>/dev/null
        hermes config set model.provider "$new_provider" 2>/dev/null
        hermes config set model.base_url "$new_base" 2>/dev/null
        log_ok "配置已更新（通过 hermes config set）"
        echo ""
        echo -e "${YELLOW}提示: 如需要修改 API Key，请编辑 ~/.hermes/.env 文件${RESET}"
    else
        log_error "hermes 命令不可用，无法修改配置"
    fi
    
    echo ""
    log_ok "模型切换完成"
}

#=================================================================
# 供应商模型管理 - 新增/编辑/删除角色模型
#=================================================================

# 新增角色模型
model_role_add() {
    echo ""
    echo -e "${BOLD}========== 新增角色模型 ==========${RESET}"
    
    if [[ ! -f "$VENDOR_FILE" ]]; then
        log_warn "vendor_models.json 不存在，将创建新文件"
        echo '{}' > "$VENDOR_FILE"
    fi
    
    # 显示现有角色
    python3 -c "
import json
with open('$VENDOR_FILE') as f:
    d = json.load(f)
roles = [k for k in d if not k.startswith('_')]
if roles:
    print('当前已有角色:')
    for r in roles:
        print(f'  • {r}')
else:
    print('当前无角色')
print()
" 2>/dev/null
    
    read -rp "输入新的角色名称 (如 翻译助手): " role_name
    [[ -z "$role_name" ]] && { log_error "角色名称不能为空"; return; }
    
    # 检查是否已存在
    local exists=$(python3 -c "
import json
with open('$VENDOR_FILE') as f:
    d = json.load(f)
print('yes' if '$role_name' in d else 'no')
" 2>/dev/null)
    
    if [[ "$exists" == "yes" ]]; then
        log_warn "角色 '$role_name' 已存在"
        read -rp "是否覆盖？(YES/NO): " overwrite
        [[ "$overwrite" != "YES" ]] && { log_warn "已取消"; return; }
    fi
    
    echo ""
    log_step "配置主模型..."
    read -rp "主模型名称 (如 gpt-4o, deepseek-chat): " primary_model
    [[ -z "$primary_model" ]] && { log_error "主模型不能为空"; return; }
    
    echo ""
    log_step "配置备用模型（可选，直接回车跳过）"
    read -rp "备用模型名称（多个用逗号分隔）: " fallback_input
    
    local fallback_list="[]"
    if [[ -n "$fallback_input" ]]; then
        fallback_list=$(python3 << PYEOF
import json
models = [m.strip() for m in "$fallback_input".split(',') if m.strip()]
items = [{'model': m, 'available': True, 'fail_count': 0} for m in models]
print(json.dumps(items))
PYEOF
)
    fi
    
    echo ""
    echo -e "${YELLOW}即将添加:${RESET}"
    echo "  角色:   $role_name"
    echo "  主模型: $primary_model"
    [[ -n "$fallback_input" ]] && echo "  备用:   $fallback_input"
    echo ""
    read -rp "确认添加？输入 YES 继续: " confirm
    [[ "$confirm" != "YES" ]] && { log_warn "已取消"; return; }
    
    # 写入 vendor_models.json
    VENDOR_FILE="$VENDOR_FILE" ROLE_NAME="$role_name" PRIMARY_MODEL="$primary_model" FALLBACK_LIST="$fallback_list" python3 << 'PYEOF' 2>/dev/null || { log_error "写入失败"; return; }
import json, datetime, os
vendor_file = os.environ['VENDOR_FILE']
role_name = os.environ['ROLE_NAME']
primary_model = os.environ['PRIMARY_MODEL']
fallback_list = json.loads(os.environ['FALLBACK_LIST'])

with open(vendor_file) as f:
    d = json.load(f)

d[role_name] = {
    'primary': {
        'model': primary_model,
        'available': True,
        'fail_count': 0
    },
    'fallbacks': fallback_list,
    'current': primary_model
}
d['_last_check'] = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

with open(vendor_file, 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print('OK')
PYEOF
    
    log_ok "角色 '$role_name' 添加成功！"
}

# 编辑角色模型
model_role_edit() {
    echo ""
    echo -e "${BOLD}========== 编辑角色模型 ==========${RESET}"
    
    if [[ ! -f "$VENDOR_FILE" ]]; then
        log_error "vendor_models.json 不存在"
        return
    fi
    
    # 列出角色供选择
    local roles_json=$(python3 -c "
import json
with open('$VENDOR_FILE') as f:
    d = json.load(f)
roles = [k for k in d if not k.startswith('_')]
for i, r in enumerate(roles):
    pri = d[r].get('primary', {}).get('model', '?')
    cur = d[r].get('current', '?')
    print(f'{i}|{r}|{pri}|{cur}')
" 2>/dev/null)
    
    if [[ -z "$roles_json" ]]; then
        log_warn "暂无角色模型"
        return
    fi
    
    echo "选择要编辑的角色:"
    echo ""
    local idx=0
    local -a role_names
    local -a role_primaries
    
    while IFS='|' read -r i name pri cur; do
        role_names[$i]="$name"
        role_primaries[$i]="$pri"
        echo -e "  ${CYAN}[$i]${RESET} $name (主: $pri, 当前: $cur)"
    done <<< "$roles_json"
    
    echo ""
    read -rp "输入编号 [0-${#role_names[@]}] 选择角色: " sel_idx
    
    # 验证输入
    if [[ -z "$sel_idx" ]] || ! [[ "$sel_idx" =~ ^[0-9]+$ ]] || [[ "$sel_idx" -ge "${#role_names[@]}" ]]; then
        log_warn "无效选择"
        return
    fi
    
    local target_role="${role_names[$sel_idx]}"
    
    echo ""
    echo -e "${BOLD}当前配置 [$target_role]:${RESET}"
    
    python3 -c "
import json
with open('$VENDOR_FILE') as f:
    d = json.load(f)
r = d.get('$target_role', {})
pri = r.get('primary', {}).get('model', '?')
pri_avail = '✓' if r.get('primary', {}).get('available', False) else '✗'
cur = r.get('current', '?')
falls = r.get('fallbacks', [])
print(f'  主模型: {pri} [{pri_avail}]')
print(f'  当前:   {cur}')
for i, fb in enumerate(falls):
    print(f'  备用[{i}]: {fb.get(\"model\", \"?\")}')
if not falls:
    print('  备用:   无')
" 2>/dev/null
    
    echo ""
    echo "编辑选项："
    echo "  [1] 修改主模型"
    echo "  [2] 修改当前使用模型"
    echo "  [3] 添加备用模型"
    echo "  [4] 删除指定备用模型"
    echo "  [5] 切换主模型可用状态"
    echo "  [0] 取消"
    echo ""
    read -rp "请选择 [0-5]: " edit_choice
    
    case "$edit_choice" in
        1)
            read -rp "新的主模型名称: " new_primary
            [[ -z "$new_primary" ]] && { log_warn "已取消"; return; }
            python3 -c "
import json, datetime
with open('$VENDOR_FILE') as f:
    d = json.load(f)
d['$target_role']['primary']['model'] = '$new_primary'
d['_last_check'] = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with open('$VENDOR_FILE', 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print('OK')
" 2>/dev/null
            log_ok "主模型已更新为: $new_primary"
            ;;
        2)
            read -rp "新的当前模型名称: " new_current
            [[ -z "$new_current" ]] && { log_warn "已取消"; return; }
            python3 -c "
import json, datetime
with open('$VENDOR_FILE') as f:
    d = json.load(f)
d['$target_role']['current'] = '$new_current'
d['_last_check'] = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with open('$VENDOR_FILE', 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print('OK')
" 2>/dev/null
            log_ok "当前模型已更新为: $new_current"
            ;;
        3)
            read -rp "要添加的备用模型名称: " new_fallback
            [[ -z "$new_fallback" ]] && { log_warn "已取消"; return; }
            python3 -c "
import json, datetime
with open('$VENDOR_FILE') as f:
    d = json.load(f)
d['$target_role'].setdefault('fallbacks', []).append({
    'model': '$new_fallback',
    'available': True,
    'fail_count': 0
})
d['_last_check'] = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with open('$VENDOR_FILE', 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print('OK')
" 2>/dev/null
            log_ok "已添加备用模型: $new_fallback"
            ;;
        4)
            read -rp "要删除的备用模型编号: " fb_idx
            python3 -c "
import json, datetime
with open('$VENDOR_FILE') as f:
    d = json.load(f)
falls = d['$target_role'].get('fallbacks', [])
idx = int('$fb_idx')
if 0 <= idx < len(falls):
    removed = falls.pop(idx)
    d['$target_role']['fallbacks'] = falls
    d['_last_check'] = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with open('$VENDOR_FILE', 'w') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    print(f'OK|{removed.get(\"model\",\"\")}')
else:
    print('ERR|越界')
" 2>/dev/null | while IFS='|' read -r status name; do
                [[ "$status" == "OK" ]] && log_ok "已删除备用模型: $name" || log_error "无效编号"
            done
            ;;
        5)
            # 切换可用状态
            python3 -c "
import json, datetime
with open('$VENDOR_FILE') as f:
    d = json.load(f)
old = d['$target_role']['primary']['available']
d['$target_role']['primary']['available'] = not old
d['_last_check'] = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with open('$VENDOR_FILE', 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
status = '启用' if not old else '禁用'
print(f'OK|{status}')
" 2>/dev/null | while IFS='|' read -r status name; do
                [[ "$status" == "OK" ]] && log_ok "主模型已${name}"
            done
            ;;
        0|*) log_warn "已取消" ;;
    esac
}

# 删除角色模型
model_role_delete() {
    echo ""
    echo -e "${BOLD}========== 删除角色模型 ==========${RESET}"
    
    if [[ ! -f "$VENDOR_FILE" ]]; then
        log_error "vendor_models.json 不存在"
        return
    fi
    
    local roles_json=$(python3 -c "
import json
with open('$VENDOR_FILE') as f:
    d = json.load(f)
roles = [k for k in d if not k.startswith('_')]
for i, r in enumerate(roles):
    pri = d[r].get('primary', {}).get('model', '?')
    print(f'{i}|{r}|{pri}')
" 2>/dev/null)
    
    if [[ -z "$roles_json" ]]; then
        log_warn "暂无角色模型可删除"
        return
    fi
    
    echo "选择要删除的角色:"
    echo ""
    local -a delete_roles
    while IFS='|' read -r i name pri; do
        delete_roles[$i]="$name"
        echo -e "  ${RED}[$i]${RESET} $name (主: $pri)"
    done <<< "$roles_json"
    
    echo ""
    read -rp "输入要删除的编号: " del_idx
    
    if [[ -z "$del_idx" ]] || ! [[ "$del_idx" =~ ^[0-9]+$ ]] || [[ "$del_idx" -ge "${#delete_roles[@]}" ]]; then
        log_warn "无效选择"
        return
    fi
    
    local del_name="${delete_roles[$del_idx]}"
    echo ""
    echo -e "${RED}⚠️  确认删除角色: $del_name ?${RESET}"
    read -rp "输入 YES 确认删除: " confirm
    [[ "$confirm" != "YES" ]] && { log_warn "已取消"; return; }
    
    python3 -c "
import json, datetime
with open('$VENDOR_FILE') as f:
    d = json.load(f)
if '$del_name' in d:
    del d['$del_name']
d['_last_check'] = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
with open('$VENDOR_FILE', 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
print('OK')
" 2>/dev/null || { log_error "删除失败"; return; }
    
    log_ok "已删除角色: $del_name"
}

# 模型管理子菜单
model_submenu() {
    while true; do
        echo ""
        echo -e "${BOLD}================================================${RESET}"
        echo -e "${BOLD}        模型管理工具${RESET}"
        echo -e "${BOLD}================================================${RESET}"
        echo ""
        echo -e "${CYAN}  [1]${RESET} 查看模型配置概览"
        echo -e "${CYAN}  [2]${RESET} 查看角色模型配置"
        echo -e "${CYAN}  [3]${RESET} 测试主模型连通性"
        echo -e "${CYAN}  [4]${RESET} 测试视觉模型"
        echo -e "${CYAN}  [5]${RESET} 测试所有角色模型"
        echo -e "${CYAN}  [6]${RESET} 切换主模型/供应商"
        echo -e "${CYAN}  [7]${RESET} 新增角色模型"
        echo -e "${CYAN}  [8]${RESET} 编辑角色模型"
        echo -e "${CYAN}  [9]${RESET} 删除角色模型"
        echo -e "${CYAN}  [0]${RESET} 返回主菜单"
        echo ""
        read -rp "请选择 [0-9]: " m_choice
        echo ""
        
        case "$m_choice" in
            1) model_overview ;;
            2) model_role_list ;;
            3) model_test_main ;;
            4) model_test_vision ;;
            5) model_test_all_roles ;;
            6) model_switch_wizard ;;
            7) model_role_add ;;
            8) model_role_edit ;;
            9) model_role_delete ;;
            0|"") echo "返回主菜单"; break ;;
            *) log_warn "无效选择"; continue ;;
        esac
        
        echo ""
        read -rp "按回车键继续..." _dummy
    done
}