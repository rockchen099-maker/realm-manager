#!/bin/bash

# ================= 颜色定义 =================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_DIR="/etc/realm"
CONFIG_FILE="$CONFIG_DIR/config.json"
BIN_FILE="/usr/local/bin/realm"

# ================= 1. 权限与基础环境检查 =================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本！${NC}"
    exit 1
fi

check_and_fix_env() {
    echo -e "${YELLOW}---> 正在检测系统环境及必备依赖...${NC}"
    
    # 自动识别系统包管理器 (支持 Alpine, Debian, Ubuntu, CentOS)
    if command -v apk >/dev/null 2>&1; then
        INSTALL_CMD="apk add --no-cache"
        # Alpine 国内源优化 (清华源)
        sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories 2>/dev/null
    elif command -v apt-get >/dev/null 2>&1; then
        INSTALL_CMD="apt-get install -y"
        apt-get update -y >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        INSTALL_CMD="yum install -y"
        yum install -y epel-release >/dev/null 2>&1
    else
        echo -e "${RED}无法识别的系统包管理器，尝试继续...${NC}"
    fi

    # 安装基础依赖
    for cmd in jq curl tar wget; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${CYAN}正在安装缺失依赖: $cmd...${NC}"
            $INSTALL_CMD $cmd >/dev/null 2>&1
        fi
    done
    echo -e "${GREEN}---> 环境检测通过！${NC}"
}

# ================= 2. 核心功能：安装与系统优化 =================
install_realm() {
    echo -e "\n${CYAN}=================================================${NC}"
    echo -e "${CYAN}       开始安装 Realm 核心并进行极致中转优化       ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    
    mkdir -p $CONFIG_DIR
    
    echo -e "${YELLOW}---> 正在寻找国内最快镜像源下载 Realm 核心...${NC}"
    
    # Realm 官方最新版的下载路径
    OFFICIAL_URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    
    # 针对国内机器的镜像源列表（经过筛选，成功率高）
    MIRRORS=(
        "https://mirror.ghproxy.com/$OFFICIAL_URL"
        "https://gh-proxy.com/$OFFICIAL_URL"
        "https://github.moeyy.xyz/$OFFICIAL_URL"
        "https://fastly.jsdelivr.net/gh/zhboner/realm@master/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz" # jsdelivr加速
    )

    SUCCESS=false
    for URL in "${MIRRORS[@]}"; do
        echo -e "${CYAN}尝试连接: ${URL:0:30}...${NC}"
        # 强制使用 IPv4 下载，设置超时时间防止卡死
        curl -4 -L -o realm.tar.gz "$URL" --connect-timeout 5 --max-time 30
        
        # 严格校验文件：必须存在，且大小必须大于 1MB (防止下到 404 报错页面)
        if [ -f "realm.tar.gz" ] && [ $(stat -c%s "realm.tar.gz" 2>/dev/null || stat -f%s "realm.tar.gz" 2>/dev/null) -gt 1000000 ]; then
            SUCCESS=true
            echo -e "${GREEN}---> 下载成功！${NC}"
            break
        else
            echo -e "${RED}---> 下载失败或文件损坏，尝试下一个镜像...${NC}"
            rm -f realm.tar.gz
        fi
    done

    if [ "$SUCCESS" = false ]; then
        echo -e "${RED}❌ 致命错误：所有镜像站均无法连接！${NC}"
        echo -e "${YELLOW}请检查您的国内机是否能正常连接外网，或稍后再试。${NC}"
        read -p "按回车键返回主菜单..."
        return
    fi
    
    # 解压并安装
    echo -e "${YELLOW}---> 正在解压并配置 Realm...${NC}"
    tar -xvf realm.tar.gz >/dev/null 2>&1
    chmod +x realm && mv realm $BIN_FILE
    rm -f realm.tar.gz

    # 初始化配置结构 (确保 JSON 格式合法)
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > $CONFIG_FILE << EOCC
{
  "network": {
    "no_tcp_delay": true,
    "keepalive": 30
  },
  "endpoints": []
}
EOCC
    fi

    # 写入系统服务守护进程 (针对 Systemd 系统)
    if command -v systemctl >/dev/null 2>&1; then
        echo -e "${YELLOW}---> 正在配置 Systemd 守护进程...${NC}"
        cat > /etc/systemd/system/realm.service << EOSS
[Unit]
Description=Realm Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_FILE -c $CONFIG_FILE
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOSS
        systemctl daemon-reload
        systemctl enable realm >/dev/null 2>&1
    fi

    # 极致中转内核优化 (BBR + 链路参数)
    echo -e "${YELLOW}---> 正在注入中转机专属内核参数...${NC}"
    if [ -w /etc/sysctl.conf ]; then
        # 先清理可能存在的旧配置，防止重复
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
        # 写入新配置
        cat >> /etc/sysctl.conf << EOT
# Realm 中转加速调优
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
EOT
        sysctl -p >/dev/null 2>&1
    fi

    # 解锁系统文件句柄限制 (提升高并发性能)
    mkdir -p /etc/security/limits.d/
    echo "* soft nofile 1048576" > /etc/security/limits.d/realm.conf
    echo "* hard nofile 1048576" >> /etc/security/limits.d/realm.conf

    echo -e "${GREEN}✅ Realm 安装及国内机链路调优全部完成！${NC}"
    read -p "按回车键返回主菜单..."
}

# ================= 3. 启停控制辅助函数 =================
restart_realm_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart realm
    else
        killall realm 2>/dev/null
        nohup $BIN_FILE -c $CONFIG_FILE >/dev/null 2>&1 &
    fi
}

stop_realm_service() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop realm
        systemctl disable realm >/dev/null 2>&1
    else
        killall realm 2>/dev/null
    fi
}

check_realm_status() {
    if pgrep -x "realm" >/dev/null || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet realm); then
        echo -e "  服务状态: ${GREEN}● 运行中 (Running)${NC}"
    else
        echo -e "  服务状态: ${RED}○ 未运行 (或无规则配置)${NC}"
    fi
}

# ================= 4. 转发管理逻辑 =================
add_rule() {
    if [ ! -f "$BIN_FILE" ]; then 
        echo -e "${RED}错误：请先在主菜单选择 1 安装 Realm！${NC}"
        sleep 2
        return
    fi
    
    echo -e "\n${CYAN}--- 添加新转发规则 ---${NC}"
    read -p "请输入 [本地监听端口] (例如: 11943): " LOCAL_PORT
    read -p "请输入 [目标落地机IP] (例如: 114.42.x.x): " REMOTE_IP
    read -p "请输入 [目标落地机端口] (例如: 443): " REMOTE_PORT

    if [[ -z "$LOCAL_PORT" || -z "$REMOTE_IP" || -z "$REMOTE_PORT" ]]; then
        echo -e "${RED}输入不能为空，操作取消。${NC}"; sleep 2; return
    fi

    # 使用 jq 原子化更新配置，避免破坏 JSON 结构
    cp $CONFIG_FILE ${CONFIG_FILE}.bak
    jq '.endpoints += [{"listen": "0.0.0.0:'$LOCAL_PORT'", "remote": "'$REMOTE_IP':'$REMOTE_PORT'"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    
    restart_realm_service
    echo -e "${GREEN}✅ 规则添加成功，服务已重启生效！${NC}"
    sleep 2
}

list_rules() {
    echo -e "\n${CYAN}--- 当前生效的转发列表 ---${NC}"
    if [ ! -f "$CONFIG_FILE" ]; then 
        echo -e "${YELLOW}暂无配置，请先添加规则。${NC}"
        return
    fi
    
    COUNT=$(jq '.endpoints | length' $CONFIG_FILE)
    if [ "$COUNT" -eq 0 ]; then
        echo -e "${YELLOW}当前没有配置任何转发规则。${NC}"
    else
        for ((i=0; i<$COUNT; i++)); do
            LISTEN=$(jq -r ".endpoints[$i].listen" $CONFIG_FILE)
            REMOTE=$(jq -r ".endpoints[$i].remote" $CONFIG_FILE)
            echo -e " [${GREEN}$i${NC}] 本机 $LISTEN  ==>  目标 $REMOTE"
        done
    fi
}

delete_rule() {
    list_rules
    if [ ! -f "$CONFIG_FILE" ]; then sleep 2; return; fi
    COUNT=$(jq '.endpoints | length' $CONFIG_FILE)
    if [[ "$COUNT" -eq 0 ]]; then sleep 2; return; fi

    echo -e ""
    read -p "请输入要删除的规则编号 (输入 q 取消): " IDX
    if [[ "$IDX" == "q" || "$IDX" == "Q" ]]; then return; fi

    # 校验输入是否为合法数字
    if [[ "$IDX" =~ ^[0-9]+$ ]] && [ "$IDX" -ge 0 ] && [ "$IDX" -lt "$COUNT" ]; then
        cp $CONFIG_FILE ${CONFIG_FILE}.bak
        jq "del(.endpoints[$IDX])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        restart_realm_service
        echo -e "${GREEN}✅ 规则已成功删除并生效！${NC}"
    else
        echo -e "${RED}输入编号无效！${NC}"
    fi
    sleep 2
}

uninstall_realm() {
    echo -e "\n${RED}=================================================${NC}"
    read -p "⚠️  警告：确定要彻底卸载 Realm 吗？(y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        stop_realm_service
        rm -rf /usr/local/bin/realm /etc/realm /etc/systemd/system/realm.service
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload
        fi
        echo -e "${GREEN}✅ Realm 已彻底卸载！${NC}"
        exit 0
    else
        echo -e "${CYAN}已取消卸载。${NC}"
        sleep 1
    fi
}

# ================= 5. 主循环入口 =================
check_and_fix_env

while true; do
    clear
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}      Realm 智能中转管理脚本 (国内机全能版 V4.0)   ${NC}"
    echo -e "${GREEN}=================================================${NC}"
    check_realm_status
    echo -e "-------------------------------------------------"
    echo -e "  ${YELLOW}1.${NC} 🚀 安装/更新 Realm (国内防404+内核优化)"
    echo -e "  ${YELLOW}2.${NC} ➕ 添加端口转发映射"
    echo -e "  ${YELLOW}3.${NC} 📋 查看当前映射列表"
    echo -e "  ${YELLOW}4.${NC} 🗑️  删除指定映射规则"
    echo -e "  ${YELLOW}5.${NC} 🔄 手动重启 Realm 服务"
    echo -e "  ${YELLOW}6.${NC} 🧨 彻底卸载 Realm"
    echo -e "  ${YELLOW}0.${NC} 🚪 退出脚本"
    echo -e "${GREEN}=================================================${NC}"
    read -p "请选择操作 [0-6]: " OPTION

    case $OPTION in
        1) install_realm ;;
        2) add_rule ;;
        3) list_rules; echo -e "\n按回车键返回主菜单..."; read ;;
        4) delete_rule ;;
        5) restart_realm_service; echo -e "${GREEN}服务已重启！${NC}"; sleep 1 ;;
        6) uninstall_realm ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择！${NC}"; sleep 1 ;;
    esac
done
