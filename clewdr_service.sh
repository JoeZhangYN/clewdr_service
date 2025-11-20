#!/bin/bash
# ClewdR & SillyTavern 完整管理工具
# 使用: curl -O -C - https://raw.githubusercontent.com/JoeZhangYN/clewdr_service/main/clewdr_service.sh && chmod +x clewdr_service.sh && ./clewdr_service.sh

# ========== 配置 ==========
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEWDR_DIR="$SCRIPT_DIR/clewdr"
ST_DIR="$SCRIPT_DIR/SillyTavern"
CONFIG="$CLEWDR_DIR/clewdr.toml"

# ========== 日志 ==========
log() { echo "[$1] $2"; }
info() { log "INFO" "$@"; }
success() { log "OK" "$@"; }
error() { log "ERROR" "$@"; read -n1 -p "按任意键继续..."; return 1; }

# ========== 检查Root权限 ==========
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请以root用户运行此脚本"
        return 1
    fi
    return 0
}

# ========== 依赖检查 ==========
check_deps() {
    info "检查系统依赖..."
    local deps=(curl git npm node unzip)
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -ne 0 ]]; then
        error "缺少依赖: ${missing[*]}"
        return 1
    fi
    success "依赖检查通过"
    return 0
}

# ========== 架构检测 ==========
detect_arch() {
    [[ "${PREFIX:-}" == *termux* ]] && echo "android-aarch64" && return
    case "$(uname -m)" in
        x86_64|amd64) echo "musllinux-x86_64" ;;
        aarch64|arm64) echo "musllinux-aarch64" ;;
        *) error "不支持的架构: $(uname -m)"; return 1 ;;
    esac
}

# ========== 获取最新版本 ==========
get_latest_version() {
    curl -s "https://api.github.com/repos/$1/releases/latest" | grep '"tag_name"' | cut -d'"' -f4
}

# ========== 获取本地版本 ==========
get_local_version() {
    if [[ -f "$CLEWDR_DIR/version.txt" ]]; then
        cat "$CLEWDR_DIR/version.txt"
    else
        echo "未安装"
    fi
}

# ========== 安装 ClewdR ==========
install_clewdr() {
    info "开始安装 ClewdR..."
    
    local version=$(get_latest_version "Xerxes-2/clewdr")
    if [[ -z "$version" ]]; then
        error "无法获取版本信息"
        return 1
    fi
    
    local local_version=$(get_local_version)
    info "本地版本: $local_version"
    info "最新版本: $version"
    
    if [[ "$local_version" == "$version" ]]; then
        read -p "已是最新版本，是否重新安装？(y/N): " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { info "取消安装"; return 0; }
    fi
    
    # 检查服务状态并停止
    if systemctl is-active --quiet clewdr.service 2>/dev/null; then
        info "检测到服务运行中，正在停止..."
        systemctl stop clewdr.service
        sleep 2
    fi
    
    local arch=$(detect_arch) || return 1
    info "目标平台: $arch"
    
    # 备份配置文件
    if [[ -f "$CONFIG" ]]; then
        info "备份配置文件..."
        cp "$CONFIG" "$CONFIG.bak"
    fi
    
    mkdir -p "$CLEWDR_DIR"
    cd "$CLEWDR_DIR" || return 1
    
    local url="https://github.com/Xerxes-2/clewdr/releases/download/${version}/clewdr-${arch}.zip"
    info "下载: clewdr-${arch}.zip"
    
    if ! curl -fL "$url" -o clewdr.zip 2>/dev/null; then
        error "下载失败"
        return 1
    fi
    
    if ! unzip -qt clewdr.zip &>/dev/null; then
        rm -f clewdr.zip
        error "文件损坏"
        return 1
    fi
    
    info "解压安装包..."
    unzip -oq clewdr.zip
    rm clewdr.zip
    chmod +x clewdr
    
    # 保存版本信息
    echo "$version" > version.txt
    
    # 恢复配置文件
    if [[ -f "$CONFIG.bak" ]]; then
        info "恢复配置文件..."
        cp "$CONFIG.bak" "$CONFIG"
    fi
    
    success "ClewdR 安装完成 (版本: $version)"
    
    # 询问是否重启服务
    if systemctl list-unit-files | grep -q "clewdr.service"; then
        read -p "是否重启服务？(y/N): " restart
        if [[ "$restart" =~ ^[Yy]$ ]]; then
            systemctl start clewdr.service
            sleep 2
            systemctl status clewdr.service --no-pager
        fi
    fi
    
    return 0
}

# ========== 安装 SillyTavern ==========
install_st() {
    info "开始安装 SillyTavern..."
    
    if [[ -d "$ST_DIR/.git" ]]; then
        info "更新现有安装..."
        cd "$ST_DIR" && git pull
        if [ $? -ne 0 ]; then
            error "更新失败"
            return 1
        fi
    else
        info "克隆仓库..."
        if ! git clone --depth 1 --branch release \
            "https://github.com/SillyTavern/SillyTavern" "$ST_DIR"; then
            error "克隆失败"
            return 1
        fi
    fi
    
    info "安装依赖..."
    cd "$ST_DIR"
    if ! npm install --omit=dev --loglevel=error; then
        error "依赖安装失败"
        return 1
    fi
    
    success "SillyTavern 安装完成"
    return 0
}

# ========== 升级 Node.js ==========
upgrade_nodejs() {
    info "开始升级 Node.js..."
    echo ""
    
    # 显示当前版本
    echo "当前 Node.js 版本: $(node -v 2>/dev/null || echo '未安装')"
    echo "当前 npm 版本: $(npm -v 2>/dev/null || echo '未安装')"
    echo ""
    
    # 检测系统
    local os_type=""
    local os_version=""
    local glibc_version=""
    
    if [ -f /etc/redhat-release ]; then
        os_type="centos"
        os_version=$(rpm -q --queryformat '%{VERSION}' centos-release 2>/dev/null || echo "unknown")
    elif [ -f /etc/debian_version ]; then
        os_type="debian"
        os_version=$(cat /etc/debian_version)
    else
        error "不支持的系统类型"
        return 1
    fi
    
    # 获取 glibc 版本
    glibc_version=$(ldd --version 2>/dev/null | head -n1 | grep -oP '\d+\.\d+' || echo "unknown")
    
    info "系统信息: $os_type $os_version"
    info "glibc 版本: $glibc_version"
    echo ""
    
    # 系统兼容性提示
    echo "==========================================="
    echo "       Node.js 版本兼容性说明"
    echo "==========================================="
    echo ""
    
    if [ "$os_type" = "centos" ] && [ "$os_version" = "7" ]; then
        echo "您的系统: CentOS 7 (glibc $glibc_version)"
        echo ""
        echo "版本支持情况:"
        echo "  Node.js 16  [推荐] 最后完全支持的版本"
        echo "  Node.js 18  [可用] LTS 版本，稳定性好"
        echo "  Node.js 20  [警告] 部分功能可能受限"
        echo "  Node.js 22  [失败] 需要 glibc 2.28+，无法安装"
        echo ""
        echo "说明: CentOS 7 的 glibc 版本为 2.17，过新的"
        echo "      Node.js 版本会因系统库过旧而无法运行"
    else
        echo "您的系统: $os_type $os_version (glibc $glibc_version)"
        echo ""
        echo "版本支持情况:"
        echo "  Node.js 16  [旧版] 仅用于兼容性需求"
        echo "  Node.js 18  [稳定] LTS 版本"
        echo "  Node.js 20  [推荐] LTS 版本，功能完整"
        echo "  Node.js 22  [最新] 最新特性，推荐使用"
        echo ""
        echo "说明: 您的系统支持所有版本，推荐安装 20 或 22"
    fi
    
    echo "==========================================="
    echo ""
    
    # 选择版本
    echo "请选择要安装的 Node.js 版本:"
    
    if [ "$os_type" = "centos" ] && [ "$os_version" = "7" ]; then
        # CentOS 7 专用菜单
        echo "1) Node.js 16 LTS (推荐 - 最稳定)"
        echo "2) Node.js 18 LTS (次选 - 功能更多)"
        echo "3) Node.js 20 LTS (需测试 - 可能有问题)"
        echo "4) Node.js 22    (不推荐 - 大概率失败)"
        echo ""
        echo "5) 使用 NVM 管理版本 (推荐方式)"
        echo "6) 恢复/重装指定版本"
        echo "0) 返回主菜单"
    else
        # 新系统菜单
        echo "1) Node.js 16 LTS (旧版 - 仅兼容需求)"
        echo "2) Node.js 18 LTS (稳定)"
        echo "3) Node.js 20 LTS (推荐)"
        echo "4) Node.js 22    (最新)"
        echo ""
        echo "5) 使用 NVM 管理版本"
        echo "6) 恢复/重装指定版本"
        echo "0) 返回主菜单"
    fi
    
    echo ""
    read -p "请选择 [0-6]: " node_choice
    
    case $node_choice in
        1|2|3|4)
            # 版本映射
            local node_version=""
            case $node_choice in
                1) node_version="16" ;;
                2) node_version="18" ;;
                3) node_version="20" ;;
                4) node_version="22" ;;
            esac
            
            # CentOS 7 额外警告
            if [ "$os_type" = "centos" ] && [ "$os_version" = "7" ]; then
                if [ "$node_version" = "22" ]; then
                    echo ""
                    warn "警告: Node.js 22 在 CentOS 7 上无法运行！"
                    read -p "您确定要继续吗? (输入 yes 继续): " confirm
                    if [ "$confirm" != "yes" ]; then
                        info "已取消安装"
                        return 0
                    fi
                elif [ "$node_version" = "20" ]; then
                    echo ""
                    warn "警告: Node.js 20 在 CentOS 7 上可能不稳定"
                    read -p "是否继续? (y/N): " confirm
                    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                        info "已取消安装"
                        return 0
                    fi
                fi
            fi
            
            echo ""
            info "准备安装 Node.js $node_version..."
            
            # 备份当前版本信息
            local old_node_version=$(node -v 2>/dev/null || echo "未安装")
            local old_npm_version=$(npm -v 2>/dev/null || echo "未安装")
            
            if [ "$os_type" = "centos" ]; then
                info "移除旧版本..."
                yum remove -y nodejs npm 2>/dev/null || true
                
                info "添加 NodeSource 仓库..."
                if ! curl -fsSL https://rpm.nodesource.com/setup_${node_version}.x | bash -; then
                    error "添加仓库失败"
                    return 1
                fi
                
                info "安装 Node.js $node_version..."
                if ! yum install -y nodejs; then
                    error "安装失败！"
                    echo ""
                    
                    # 自动降级建议
                    if [ "$os_version" = "7" ]; then
                        if [ "$node_version" = "22" ] || [ "$node_version" = "20" ]; then
                            warn "检测到 CentOS 7 系统"
                            echo ""
                            echo "自动降级选项:"
                            echo "1) 安装 Node.js 18 LTS"
                            echo "2) 安装 Node.js 16 LTS (最安全)"
                            echo "0) 放弃安装"
                            read -p "请选择 [0-2]: " fallback
                            
                            case $fallback in
                                1)
                                    info "尝试安装 Node.js 18..."
                                    yum remove -y nodejs npm 2>/dev/null || true
                                    curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
                                    yum install -y nodejs
                                    ;;
                                2)
                                    info "尝试安装 Node.js 16..."
                                    yum remove -y nodejs npm 2>/dev/null || true
                                    curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
                                    yum install -y nodejs
                                    ;;
                                *)
                                    return 1
                                    ;;
                            esac
                        fi
                    else
                        return 1
                    fi
                fi
                
                info "安装构建工具..."
                yum install -y gcc-c++ make 2>/dev/null || true
                
            else
                info "移除旧版本..."
                apt-get remove -y nodejs npm 2>/dev/null || true
                apt-get autoremove -y
                
                info "添加 NodeSource 仓库..."
                if ! curl -fsSL https://deb.nodesource.com/setup_${node_version}.x | bash -; then
                    error "添加仓库失败"
                    return 1
                fi
                
                info "安装 Node.js..."
                if ! apt-get install -y nodejs; then
                    error "安装失败"
                    return 1
                fi
                
                info "安装构建工具..."
                apt-get install -y build-essential 2>/dev/null || true
            fi
            
            # 验证安装
            echo ""
            echo "==========================================="
            local new_node_version=$(node -v 2>/dev/null)
            local new_npm_version=$(npm -v 2>/dev/null)
            
            if [ -z "$new_node_version" ]; then
                error "Node.js 安装验证失败！"
                echo ""
                echo "旧版本: $old_node_version"
                echo ""
                echo "建议操作:"
                echo "  1. 选择选项 5 使用 NVM 方式安装"
                echo "  2. 选择选项 6 手动恢复到旧版本"
                if [ "$os_type" = "centos" ] && [ "$os_version" = "7" ]; then
                    echo "  3. 安装 Node.js 16 (最安全)"
                fi
                return 1
            fi
            
            success "Node.js 安装完成！"
            echo "==========================================="
            echo "旧版本: Node.js $old_node_version | npm $old_npm_version"
            echo "新版本: Node.js $new_node_version | npm $new_npm_version"
            echo "==========================================="
            ;;
            
        5)
            echo ""
            info "使用 NVM 安装 Node.js..."
            echo ""
            echo "NVM 优势:"
            echo "  - 可安装多个版本并随时切换"
            echo "  - 不受系统库限制"
            echo "  - 用户级安装，无需 root"
            echo ""
            
            # 检查是否已安装 NVM
            if [ -d "$HOME/.nvm" ]; then
                info "NVM 已安装"
            else
                info "安装 NVM..."
                if ! curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash; then
                    error "NVM 安装失败"
                    return 1
                fi
                
                success "NVM 安装完成"
            fi
            
            # 加载 NVM
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            
            echo ""
            echo "选择要安装的版本:"
            echo "1) Node.js 16 LTS"
            echo "2) Node.js 18 LTS"
            echo "3) Node.js 20 LTS"
            echo "4) Node.js 22"
            read -p "请选择 [1-4]: " nvm_choice
            
            local nvm_version=""
            case $nvm_choice in
                1) nvm_version="16" ;;
                2) nvm_version="18" ;;
                3) nvm_version="20" ;;
                4) nvm_version="22" ;;
                *) error "无效选项"; return 1 ;;
            esac
            
            info "安装 Node.js $nvm_version..."
            if ! nvm install $nvm_version; then
                error "安装失败"
                return 1
            fi
            
            nvm use $nvm_version
            nvm alias default $nvm_version
            
            # 添加到 bashrc
            if ! grep -q "NVM_DIR" ~/.bashrc; then
                cat >> ~/.bashrc <<'EOF'

# NVM 配置
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF
                info "已添加到 ~/.bashrc"
            fi
            
            echo ""
            success "Node.js 安装完成！"
            echo "Node.js 版本: $(node -v)"
            echo "npm 版本: $(npm -v)"
            echo ""
            echo "==========================================="
            echo "NVM 常用命令:"
            echo "  nvm list           - 查看已安装版本"
            echo "  nvm install 18     - 安装 Node.js 18"
            echo "  nvm use 18         - 切换到 Node.js 18"
            echo "  nvm alias default 18 - 设置默认版本"
            echo "==========================================="
            echo ""
            echo "重要: 如果命令不生效，请运行: source ~/.bashrc"
            ;;
            
        6)
            echo ""
            info "恢复/重装指定版本..."
            echo ""
            echo "可选版本: 16, 18, 20, 22"
            
            if [ "$os_type" = "centos" ] && [ "$os_version" = "7" ]; then
                echo "您的系统 (CentOS 7) 推荐: 16 或 18"
            fi
            
            echo ""
            read -p "输入要安装的版本号: " recover_version
            
            if [[ ! "$recover_version" =~ ^(16|18|20|22)$ ]]; then
                error "无效版本号，仅支持: 16, 18, 20, 22"
                return 1
            fi
            
            # CentOS 7 警告
            if [ "$os_type" = "centos" ] && [ "$os_version" = "7" ] && [ "$recover_version" = "22" ]; then
                warn "Node.js 22 无法在 CentOS 7 上运行！"
                read -p "确定继续? (输入 yes): " confirm
                if [ "$confirm" != "yes" ]; then
                    info "已取消"
                    return 0
                fi
            fi
            
            if [ "$os_type" = "centos" ]; then
                yum remove -y nodejs npm 2>/dev/null || true
                curl -fsSL https://rpm.nodesource.com/setup_${recover_version}.x | bash -
                yum install -y nodejs
                yum install -y gcc-c++ make 2>/dev/null || true
            else
                apt-get remove -y nodejs npm 2>/dev/null || true
                apt-get autoremove -y
                curl -fsSL https://deb.nodesource.com/setup_${recover_version}.x | bash -
                apt-get install -y nodejs
                apt-get install -y build-essential 2>/dev/null || true
            fi
            
            if command -v node &>/dev/null; then
                success "恢复完成！"
                echo "Node.js 版本: $(node -v)"
                echo "npm 版本: $(npm -v)"
            else
                error "恢复失败"
                return 1
            fi
            ;;
            
        0)
            info "返回主菜单"
            return 0
            ;;
            
        *)
            error "无效选项"
            return 1
            ;;
    esac
    
    return 0
}

# ========== 配置管理 ==========
config_set() {
    if [[ ! -f "$CONFIG" ]]; then
        error "配置文件不存在，请先运行 ClewdR 生成配置"
        return 1
    fi
    
    case "$1" in
        public)
            sed -i 's/127\.0\.0\.1/0.0.0.0/' "$CONFIG"
            success "已开放公网访问 (0.0.0.0)"
            ;;
        port)
            read -p "输入端口号 [1-65535]: " port
            if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
                error "无效端口"
                return 1
            fi
            sed -i -E "s/^(#?\s*port\s*=).*/port = $port/" "$CONFIG"
            success "端口设置为: $port"
            ;;
    esac
    return 0
}

# ========== 直接启动 ==========
start_direct() {
    local name=$1 dir=$2 cmd=$3
    if [[ ! -d "$dir" ]]; then
        error "$name 未安装"
        return 1
    fi
    info "启动 $name..."
    cd "$dir" && eval "$cmd"
}

# ========== 创建服务 ==========
create_service() {
    check_root || return 1
    
    if [[ ! -x "$CLEWDR_DIR/clewdr" ]]; then
        error "ClewdR 未安装，请先安装"
        return 1
    fi
    
    info "创建 systemd 服务文件..."
    
    cat > /etc/systemd/system/clewdr.service <<EOF
[Unit]
Description=ClewdR Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CLEWDR_DIR
ExecStart=$CLEWDR_DIR/clewdr
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 /etc/systemd/system/clewdr.service
    systemctl daemon-reload
    success "服务文件已创建"
    
    echo ""
    echo "服务管理命令:"
    echo "  启动服务: systemctl start clewdr"
    echo "  停止服务: systemctl stop clewdr"
    echo "  开机启动: systemctl enable clewdr"
    echo "  查看状态: systemctl status clewdr"
    return 0
}

# ========== 启动服务 ==========
start_service() {
    check_root || return 1
    
    info "正在启动服务..."
    systemctl start clewdr.service
    
    sleep 2
    
    if systemctl is-active --quiet clewdr.service; then
        success "服务已启动"
        echo ""
        systemctl status clewdr.service --no-pager -l
    else
        error "服务启动失败"
        echo ""
        echo "查看详细日志: journalctl -u clewdr.service -n 50"
        return 1
    fi
    return 0
}

# ========== 停止服务 ==========
stop_service() {
    check_root || return 1
    
    info "正在停止服务..."
    systemctl stop clewdr.service
    
    sleep 1
    
    if systemctl is-active --quiet clewdr.service; then
        error "服务停止失败"
        return 1
    else
        success "服务已停止"
    fi
    return 0
}

# ========== 重启服务 ==========
restart_service() {
    check_root || return 1
    
    info "正在重启服务..."
    systemctl restart clewdr.service
    
    sleep 2
    
    if systemctl is-active --quiet clewdr.service; then
        success "服务已重启"
        echo ""
        systemctl status clewdr.service --no-pager -l
    else
        error "服务重启失败"
        echo ""
        echo "查看详细日志: journalctl -u clewdr.service -n 50"
        return 1
    fi
    return 0
}

# ========== 查看服务状态 ==========
status_service() {
    echo "=========================================="
    echo "服务状态:"
    echo "=========================================="
    systemctl status clewdr.service --no-pager -l
    echo ""
    echo "=========================================="
    echo "最近日志:"
    echo "=========================================="
    journalctl -u clewdr.service -n 20 --no-pager
    return 0
}

# ========== 启用开机自启 ==========
enable_service() {
    check_root || return 1
    
    systemctl enable clewdr.service
    if [ $? -eq 0 ]; then
        success "服务已设置为开机自启"
    else
        error "设置失败"
        return 1
    fi
    return 0
}

# ========== 禁用开机自启 ==========
disable_service() {
    check_root || return 1
    
    systemctl disable clewdr.service
    if [ $? -eq 0 ]; then
        success "服务已禁用开机自启"
    else
        error "禁用失败"
        return 1
    fi
    return 0
}

# ========== 卸载服务 ==========
remove_service() {
    check_root || return 1
    
    info "正在卸载服务..."
    systemctl stop clewdr.service 2>/dev/null
    systemctl disable clewdr.service 2>/dev/null
    rm -f /etc/systemd/system/clewdr.service
    systemctl daemon-reload
    success "服务已卸载"
    return 0
}

# ========== 显示菜单 ==========
show_menu() {
    clear
    echo "==========================================="
    echo "     ClewdR & SillyTavern 管理工具     "
    echo "==========================================="
    
    # 显示状态
    local cr_st="未安装"
    local st_st="未安装"
    local service_st="未安装"
    
    if [[ -x "$CLEWDR_DIR/clewdr" ]]; then
        local version=$(get_local_version)
        cr_st="已安装 ($version)"
    fi
    
    if [[ -d "$ST_DIR" ]]; then
        st_st="已安装"
    fi
    
    if systemctl list-unit-files | grep -q "clewdr.service"; then
        if systemctl is-active --quiet clewdr.service; then
            service_st="运行中"
        else
            service_st="已停止"
        fi
    fi
    
    echo "ClewdR: $cr_st"
    echo "SillyTavern: $st_st"
    echo "服务状态: $service_st"
    
    # 显示 Node.js 版本
    local node_ver=$(node -v 2>/dev/null || echo "未安装")
    local npm_ver=$(npm -v 2>/dev/null || echo "未安装")
    echo "Node.js: $node_ver | npm: $npm_ver"
    echo ""
    
    echo "[安装管理]"
    echo "1) 安装/更新 ClewdR"
    echo "2) 安装/更新 SillyTavern"
    echo "3) 升级 Node.js 版本"
    echo ""
    echo "[直接启动]"
    echo "4) 启动 ClewdR (前台运行)"
    echo "5) 启动 SillyTavern (前台运行)"
    echo ""
    echo "[服务管理]"
    echo "6) 安装服务"
    echo "7) 启动服务"
    echo "8) 停止服务"
    echo "9) 重启服务"
    echo "10) 查看服务状态"
    echo "11) 启用开机自启"
    echo "12) 禁用开机自启"
    echo "13) 卸载服务"
    echo ""
    echo "[配置管理]"
    echo "14) 开放公网访问"
    echo "15) 设置端口号"
    echo ""
    echo "0) 退出"
    echo "==========================================="
}

# ========== 主循环 ==========
main_menu() {
    show_menu
    
    read -rp "请选择操作 [0-15]: " choice
    echo
    
    case $choice in
        1)
            check_deps && install_clewdr
            ;;
        2)
            check_deps && install_st
            ;;
        3)
            upgrade_nodejs
            ;;
        4)
            start_direct "ClewdR" "$CLEWDR_DIR" "./clewdr"
            ;;
        5)
            start_direct "SillyTavern" "$ST_DIR" "node server.js"
            ;;
        6)
            create_service
            ;;
        7)
            start_service
            ;;
        8)
            stop_service
            ;;
        9)
            restart_service
            ;;
        10)
            status_service
            ;;
        11)
            enable_service
            ;;
        12)
            disable_service
            ;;
        13)
            remove_service
            ;;
        14)
            config_set public
            ;;
        15)
            config_set port
            ;;
        0)
            echo "退出脚本。"
            return 1
            ;;
        *)
            error "无效选项，请重新选择。"
            ;;
    esac
    
    echo
    read -n1 -rp "按任意键继续..." key
    return 0
}

# ========== 主函数 ==========
main() {
    # 检查root权限
    check_root || exit 1
    
    # 主循环
    while true; do
        main_menu
        [ $? -ne 0 ] && break
    done
    
    echo "服务管理脚本执行完毕。"
    exit 0
}

# ========== 脚本入口 ==========
main "$@"