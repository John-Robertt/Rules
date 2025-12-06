#!/bin/bash
# Codex配置脚本(macOS&Linux)

set -e

# 输出的颜色函数
print_info() {
    echo -e "\033[34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[32m[SUCCESS]\033[0m $1"
}

print_warning() {
    echo -e "\033[33m[WARNING]\033[0m $1"
}

print_error() {
    echo -e "\033[31m[ERROR]\033[0m $1"
}

# 检测 Codex 是否已安装
check_codex() {
    if command -v codex &> /dev/null; then
        local version=$(codex --version 2>/dev/null || echo "unknown")
        print_success "Codex is already installed: $version"
        return 0
    else
        return 1
    fi
}

# 检测 Node.js 是否已安装
check_nodejs() {
    if command -v node &> /dev/null; then
        local version=$(node --version 2>/dev/null || echo "unknown")
        # 检查版本是否 >= 18
        if [[ "$version" =~ ^v?([0-9]+) ]]; then
            local major_version="${BASH_REMATCH[1]}"
            if [ "$major_version" -ge 18 ]; then
                print_success "Node.js is installed: $version"
                return 0
            else
                print_warning "Node.js version is too old: $version (requires >= 18.0.0)"
                return 1
            fi
        fi
    fi
    return 1
}

# 安装 Node.js
install_nodejs() {
    print_info "Installing Node.js..."

    # 检测操作系统
    local os_type="$(uname -s)"

    if [ "$os_type" = "Darwin" ]; then
        # macOS
        if command -v brew &> /dev/null; then
            print_info "Installing Node.js using Homebrew..."
            brew install node
            return $?
        else
            print_warning "Homebrew not found. Please install Node.js manually from: https://nodejs.org/"
            return 1
        fi
    elif [ "$os_type" = "Linux" ]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            # Debian/Ubuntu
            print_info "Installing Node.js using apt..."
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo apt-get install -y nodejs
            return $?
        elif command -v yum &> /dev/null; then
            # RHEL/CentOS
            print_info "Installing Node.js using yum..."
            curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
            sudo yum install -y nodejs
            return $?
        else
            print_warning "Package manager not found. Please install Node.js manually from: https://nodejs.org/"
            return 1
        fi
    else
        print_warning "Unsupported OS. Please install Node.js manually from: https://nodejs.org/"
        return 1
    fi
}

# 安装 Codex
install_codex() {
    print_info "Installing Codex CLI..."

    # 检查 npm 是否可用
    if ! command -v npm &> /dev/null; then
        print_error "npm is not available. Please restart your terminal after Node.js installation."
        return 1
    fi

    local npm_version=$(npm --version 2>/dev/null || echo "unknown")
    print_info "npm version: $npm_version"

    # 安装 Codex
    print_info "Running: npm install -g @openai/codex"
    npm install -g @openai/codex

    if [ $? -eq 0 ]; then
        # 验证安装
        if command -v codex &> /dev/null; then
            local version=$(codex --version 2>/dev/null || echo "unknown")
            print_success "Codex installed successfully: $version"
            return 0
        else
            print_warning "Codex was installed but cannot be verified. You may need to restart your terminal."
            return 0
        fi
    else
        print_error "Failed to install Codex"
        return 1
    fi
}

# 确保 Codex 已安装
ensure_codex() {
    print_info "Checking Codex installation..."

    # 检测 Codex 是否已安装
    if check_codex; then
        return 0
    fi

    print_warning "Codex is not installed"

    # 检测 Node.js 是否已安装
    if ! check_nodejs; then
        # 尝试安装 Node.js
        if ! install_nodejs; then
            print_warning "Failed to install Node.js automatically"
            return 1
        fi
    fi

    # 安装 Codex
    if install_codex; then
        return 0
    else
        print_warning "Failed to install Codex automatically"
        return 1
    fi
}

# 默认值
DEFAULT_BASE_URL="http://localhost:8080"
BASE_URL=""
API_KEY=""
CONTEXT7_KEY=""
SHOW_SETTINGS=false

# 显示帮助的函数
show_help() {
    cat << EOF
Codex Configuration Script

Usage: $0 [OPTIONS]

Options:
  --url URL        Set the base URL (default: $DEFAULT_BASE_URL)
  --key KEY        Set the API key
  --ctx7 KEY  Set Context7 MCP server API key
  --show           Show current settings and exit
  --help           Show this help message

Examples:
  $0 --url https://your-domain.tld --key your-api-key-here
  $0 --url https://your-domain.tld --key your-api-key-here --ctx7 your-context7-api-key
  $0 --show

Interactive mode (no arguments):
  $0
EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --url)
            BASE_URL="$2"
            shift 2
            ;;
        --key)
            API_KEY="$2"
            shift 2
            ;;
        --ctx7)
            CONTEXT7_KEY="$2"
            shift 2
            ;;
        --show)
            SHOW_SETTINGS=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# 备份现有配置的函数
backup_config() {
    if [ -f "$HOME/.codex/config.toml" ]; then
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local backup_file="$HOME/.codex/config.toml.backup.$timestamp"
        local backup_auth_file="$HOME/.codex/auth.json.backup.$timestamp"
        cp "$HOME/.codex/config.toml" "$backup_file"
        if [ -f "$HOME/.codex/auth.json" ]; then
            cp "$HOME/.codex/auth.json" "$backup_auth_file"
            print_info "Backed up existing auth file to: $backup_auth_file"
        fi
        print_info "Backed up existing configuration to: $backup_file"
    fi
}

# 创建Codex配置的函数
create_codex_config() {
    local base_url="$1"
    local api_key="$2"
    local context7_block=""
    
    if [ -n "$CONTEXT7_KEY" ]; then
        context7_block=$(cat << 'EOF2'

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
http_headers = { "CONTEXT7_API_KEY" = "$CONTEXT7_API_KEY" }
EOF2
)
    fi
    
    # 如果配置目录不存在则创建
    mkdir -p "$HOME/.codex"
    
    # 创建config.toml
    cat > "$HOME/.codex/config.toml" << EOF
model_provider = "codex"
model = "gpt-5.1-codex-max"
model_reasoning_effort = "high"
disable_response_storage = true

[model_providers.codex]
name = "codex"
base_url = "${base_url}/v1"
wire_api = "responses"
env_key = "CODEX_API_KEY"

[features]
web_search_request = true
${context7_block}
EOF

#     cat > "$HOME/.codex/auth.json" << EOF
# {
#   "OPENAI_API_KEY": "$api_key"
# }
# EOF

    cat > "$HOME/.codex/auth.json" << EOF
{}
EOF
    
    print_success "Codex configuration written to: $HOME/.codex/config.toml"
    print_success "Codex auth file written to: $HOME/.codex/auth.json"
    return 0
}

# 设置环境变量的函数
set_environment_variable() {
    local api_key="$1"
    local ctx7_key="$2"

    # 为当前会话导出
    export CODEX_API_KEY="$api_key"
    if [ -n "$ctx7_key" ]; then
        export CONTEXT7_API_KEY="$ctx7_key"
    fi

    # 检测shell并添加到相应的配置文件
    local shell_config=""
    local shell_name=""
    
    # 首先检查$SHELL以确定用户的默认shell
    if [ -n "$SHELL" ]; then
        shell_name=$(basename "$SHELL")
        case "$shell_name" in
            bash)
                shell_config="$HOME/.bashrc"
                [ -f "$HOME/.bash_profile" ] && shell_config="$HOME/.bash_profile"
                ;;
            zsh)
                shell_config="$HOME/.zshrc"
                ;;
            fish)
                shell_config="$HOME/.config/fish/config.fish"
                ;;
            *)
                shell_config="$HOME/.profile"
                ;;
        esac
    # 如果$SHELL未设置，回退到检查版本变量
    elif [ -n "$BASH_VERSION" ]; then
        shell_config="$HOME/.bashrc"
        [ -f "$HOME/.bash_profile" ] && shell_config="$HOME/.bash_profile"
    elif [ -n "$ZSH_VERSION" ]; then
        shell_config="$HOME/.zshrc"
    elif [ -n "$FISH_VERSION" ]; then
        shell_config="$HOME/.config/fish/config.fish"
    else
        shell_config="$HOME/.profile"
    fi
    
    print_info "Detected shell: ${shell_name:-$(basename $SHELL 2>/dev/null || echo 'unknown')}"
    print_info "Using config file: $shell_config"
    
    # 以不同方式处理Fish shell（使用'set -x'代替'export'）
    if [ "$shell_name" = "fish" ] || [[ "$shell_config" == *"fish"* ]]; then
        # Fish shell语法
        if [ -f "$shell_config" ] && grep -q "set -x CODEX_API_KEY" "$shell_config"; then
            # 更新现有设置
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/set -x CODEX_API_KEY.*/set -x CODEX_API_KEY \"$api_key\"/" "$shell_config"
            else
                sed -i "s/set -x CODEX_API_KEY.*/set -x CODEX_API_KEY \"$api_key\"/" "$shell_config"
            fi
            print_info "Updated CODEX_API_KEY in $shell_config"
        else
            # 添加新设置
            mkdir -p "$(dirname "$shell_config")"
            echo "" >> "$shell_config"
            echo "# Codex的API密钥" >> "$shell_config"
            echo "set -x CODEX_API_KEY \"$api_key\"" >> "$shell_config"
            print_info "Added CODEX_API_KEY to $shell_config"
        fi

        if [ -n "$ctx7_key" ]; then
            if [ -f "$shell_config" ] && grep -q "set -x CONTEXT7_API_KEY" "$shell_config"; then
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    sed -i '' "s/set -x CONTEXT7_API_KEY.*/set -x CONTEXT7_API_KEY \"$ctx7_key\"/" "$shell_config"
                else
                    sed -i "s/set -x CONTEXT7_API_KEY.*/set -x CONTEXT7_API_KEY \"$ctx7_key\"/" "$shell_config"
                fi
                print_info "Updated CONTEXT7_API_KEY in $shell_config"
            else
                echo "" >> "$shell_config"
                echo "# Context7 的API密钥" >> "$shell_config"
                echo "set -x CONTEXT7_API_KEY \"$ctx7_key\"" >> "$shell_config"
                print_info "Added CONTEXT7_API_KEY to $shell_config"
            fi
        fi
    else
        # Bash/Zsh/sh语法
        if [ -f "$shell_config" ] && grep -q "export CODEX_API_KEY=" "$shell_config"; then
            # 更新现有设置
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS系统
                sed -i '' "s/export CODEX_API_KEY=.*/export CODEX_API_KEY=\"$api_key\"/" "$shell_config"
            else
                # Linux系统
                sed -i "s/export CODEX_API_KEY=.*/export CODEX_API_KEY=\"$api_key\"/" "$shell_config"
            fi
            print_info "Updated CODEX_API_KEY in $shell_config"
        else
            # 添加新设置
            echo "" >> "$shell_config"
            echo "# Codex的API密钥" >> "$shell_config"
            echo "export CODEX_API_KEY=\"$api_key\"" >> "$shell_config"
            print_info "Added CODEX_API_KEY to $shell_config"
        fi

        if [ -n "$ctx7_key" ]; then
            if [ -f "$shell_config" ] && grep -q "export CONTEXT7_API_KEY=" "$shell_config"; then
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    sed -i '' "s/export CONTEXT7_API_KEY=.*/export CONTEXT7_API_KEY=\"$ctx7_key\"/" "$shell_config"
                else
                    sed -i "s/export CONTEXT7_API_KEY=.*/export CONTEXT7_API_KEY=\"$ctx7_key\"/" "$shell_config"
                fi
                print_info "Updated CONTEXT7_API_KEY in $shell_config"
            else
                echo "" >> "$shell_config"
                echo "# Context7 的API密钥" >> "$shell_config"
                echo "export CONTEXT7_API_KEY=\"$ctx7_key\"" >> "$shell_config"
                print_info "Added CONTEXT7_API_KEY to $shell_config"
            fi
        fi
    fi
    
    return 0
}

# 显示当前设置的函数
show_current_settings() {
    print_info "Current Codex settings:"
    echo "----------------------------------------"
    
    if [ -f "$HOME/.codex/config.toml" ]; then
        print_info "Configuration file: $HOME/.codex/config.toml"
        echo ""
        cat "$HOME/.codex/config.toml"
        echo ""
    else
        print_info "No configuration file found at $HOME/.codex/config.toml"
    fi
    
    echo "----------------------------------------"
    print_info "Environment variable:"
    
    if [ ! -z "$CODEX_API_KEY" ]; then
        local masked_key="${CODEX_API_KEY:0:8}...${CODEX_API_KEY: -4}"
        print_info "CODEX_API_KEY: $masked_key"
    else
        print_info "CODEX_API_KEY: (not set)"
    fi

    if [ ! -z "$CONTEXT7_API_KEY" ]; then
        local masked_ctx7="${CONTEXT7_API_KEY:0:8}...${CONTEXT7_API_KEY: -4}"
        print_info "CONTEXT7_API_KEY: $masked_ctx7"
    else
        print_info "CONTEXT7_API_KEY: (not set)"
    fi
    
    echo "----------------------------------------"
}

# 主函数
main() {
    print_info "Codex Configuration Script"
    echo "======================================="
    echo ""

    # 尝试安装 Codex（除非只是显示）
    if [ "$SHOW_SETTINGS" = false ]; then
        ensure_codex || true
        echo
    fi
    
    # 如果要求则显示当前设置并退出
    if [ "$SHOW_SETTINGS" = true ]; then
        show_current_settings
        exit 0
    fi
    
    # 如果未提供URL或密钥则进入交互模式
    if [ -z "$BASE_URL" ] && [ -z "$API_KEY" ]; then
        print_info "Interactive setup mode"
        echo ""
        
        # 获取基础URL
        read -p "Enter Base URL [$DEFAULT_BASE_URL]: " input_url
        BASE_URL="${input_url:-$DEFAULT_BASE_URL}"
        
        # 获取API密钥
        while [ -z "$API_KEY" ]; do
            read -p "Enter your API key: " API_KEY
            if [ -z "$API_KEY" ]; then
                print_warning "API key is required"
            fi
        done

        # 获取可选的 Context7 密钥
        if [ -z "$CONTEXT7_KEY" ]; then
            read -p "Enter your Context7 API key (optional): " CONTEXT7_KEY
        fi
    fi
    
    # 验证输入
    if [ -z "$BASE_URL" ] || [ -z "$API_KEY" ]; then
        print_error "Both URL and API key are required"
        print_info "Use --help for usage information"
        exit 1
    fi
    
    # 移除URL末尾的斜杠
    BASE_URL="${BASE_URL%/}"
    
    print_info "Configuration:"
    print_info "  Base URL: $BASE_URL"
    
    # 隐藏API密钥用于显示
    if [ ${#API_KEY} -gt 12 ]; then
        masked_key="${API_KEY:0:8}...${API_KEY: -4}"
    else
        masked_key="${API_KEY:0:4}..."
    fi
    print_info "  API Key: $masked_key"

    if [ -n "$CONTEXT7_KEY" ]; then
        if [ ${#CONTEXT7_KEY} -gt 12 ]; then
            masked_ctx7="${CONTEXT7_KEY:0:8}...${CONTEXT7_KEY: -4}"
        else
            masked_ctx7="${CONTEXT7_KEY:0:4}..."
        fi
        print_info "  Context7 API Key: $masked_ctx7"
    else
        print_info "  Context7 API Key: (not provided)"
    fi
    echo ""
    
    # 备份现有配置
    backup_config
    
    # 创建Codex配置
    if ! create_codex_config "$BASE_URL" "$API_KEY"; then
        print_error "Failed to create Codex configuration"
        exit 1
    fi
    
    # 设置环境变量
    if ! set_environment_variable "$API_KEY" "$CONTEXT7_KEY"; then
        print_warning "Failed to set environment variable automatically"
        print_info "Please set manually: export CODEX_API_KEY=\"$API_KEY\""
        if [ -n "$CONTEXT7_KEY" ]; then
            print_info "And: export CONTEXT7_API_KEY=\"$CONTEXT7_KEY\""
        fi
    fi
    
    echo ""
    print_success "Configuration has been saved successfully!"
    print_info "Configuration file: $HOME/.codex/config.toml"
    echo

    # 检查 Codex 是否已安装并给出相应提示
    if command -v codex &> /dev/null; then
        print_success "Codex is installed and ready to use!"
        print_info "Run 'codex --version' to verify"
    else
        print_warning "Codex not installed. To install manually:"
        print_info "1. Install Node.js from https://nodejs.org/"
        print_info "2. Run: npm install -g @openai/codex"
    fi

    echo
    print_info "To apply the environment variable in your current session, run:"
    
    # 根据检测到的shell提供正确的命令
    local current_shell=$(basename "$SHELL" 2>/dev/null || echo "bash")
    if [ "$current_shell" = "fish" ]; then
        print_info "  set -x CODEX_API_KEY \"$API_KEY\""
        if [ -n "$CONTEXT7_KEY" ]; then
            print_info "  set -x CONTEXT7_API_KEY \"$CONTEXT7_KEY\""
        fi
    else
        print_info "  export CODEX_API_KEY=\"$API_KEY\""
        if [ -n "$CONTEXT7_KEY" ]; then
            print_info "  export CONTEXT7_API_KEY=\"$CONTEXT7_KEY\""
        fi
    fi
    print_info "Or restart your terminal."
    
    # 显示当前设置
    echo ""
    show_current_settings
}

# 运行主函数
main
