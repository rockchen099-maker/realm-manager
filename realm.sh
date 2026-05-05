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

# ================= 1. 环境检测与依赖安装 =================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行此脚本！${NC}"
    exit 1
fi

check_and_fix_env() {
    echo -e "${YELLOW}正在检测系统环境及依赖...${NC}"
    # 自动识别安装命令
    if command -v apk >/dev/null 2>&1; then
        INSTALL_CMD="apk add --no-cache"
    elif command -v apt-get >/dev/null 2>&1; then
        INSTALL_CMD="apt-get install -y"
        apt-get update -y >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        INSTALL_CMD="yum install -y"
        yum install -y epel-release >/dev/null 2>&1
    fi

    # 安装基础依赖
    for cmd in jq curl tar; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${CYAN}安装依赖: $cmd...${NC}"
            $INSTALL_CMD $cmd >/dev/null 2>&1
        fi
    done
}

# ================= 2. 智能网络源选择 =================
get_download_url() {
    # 官方源
    OFFICIAL_URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    # 镜像源列表
    MIRRORS=(
        "https://mirror.ghproxy.com/$OFFICIAL_URL"
        "https://ghproxy.net/$OFFICIAL_URL"
        "https://github.moeyy.xyz/$OFFICIAL_URL"
    )

    # 测试直连 GitHub 速度
    if curl -Is --connect-timeout 3 https://github.com >/dev/null 2>&1; then
        echo "$OFFICIAL_URL"
    else
        # 依次返回镜像源
        for url in "${MIRRORS[@]}"; do
            echo "$url"
        done
    fi
}

# ================= 3. 核心功能：安装与系统优化 =================
install_realm() {
    echo -e "${CYAN}--- 开始安装 Realm 及其链路优化 ---${NC}"
    
    mkdir -p $CONFIG_DIR
    
    # 尝试多源下载
    SUCCESS=false
    URLS=$(get_download_url)
    for URL in $URLS; do
        echo -e "${YELLOW}尝试下载自: $URL${NC}"
        curl -L -o realm.tar.gz "$URL" --connect-timeout 10 --max-time 120
        
        if [ -f "realm.tar.gz" ] && [ $(stat -c%s "realm.tar.gz") -gt 500000 ]; then
            SUCCESS=true
            break
        else
            rm -f realm.tar.gz
        fi
    done

    if [ "$SUCCESS" = false ]; then
        echo -e "${RED}❌ 无法从任何源下载 Realm，请检查网络！${NC}"
        return
    fi
    
    tar -xvf realm.tar.gz >/dev/null 2>&1
    chmod +x realm && mv realm $BIN_FILE
    rm -f realm.tar.gz

    # 初始化配置
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

    # 写入 Systemd (仅限支持 systemd 的系统，如 Debian/Ubuntu/CentOS)
    if command -v systemctl >/dev/null 2>&1; then
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
        systemctl restart realm
    fi

    # 4. 内核极致优化 (BBR + 链路)[cite: 1]
    echo -e "${YELLOW}正在注入中转机专属内核参数...${NC}"
    if [ -w /etc/sysctl.conf ]; then
        sed -i '/net.core/d' /etc/sysctl.conf
        sed -i '/net.ipv4/d' /etc/sysctl.conf
        cat >> /etc/sysctl.conf << EOT
# Realm 中转优化
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

    echo -e "${GREEN}✅ Realm 安装及链路调优完毕！${NC}"
    sleep 2
}

# ================= 4. 规则管理逻辑 =================
add_rule() {
    if [ ! -f "$BIN_FILE" ]; then echo -e "${RED}请先执行安装！${NC}"; sleep 2; return; fi
    echo -e "${CYAN}--- 添加新转发规则 ---${NC}"
    read -p "请输入 [本地监听端口]: " LOCAL_PORT
    read -p "请输入 [目标落地机IP]: " REMOTE_IP
    read -p "请输入 [目标落地机端口]: " REMOTE_PORT

    if [[ -z "$LOCAL_PORT" || -z "$REMOTE_IP" || -z "$REMOTE_PORT" ]]; then
        echo -e "${RED}输入不能为空。${NC}"; sleep 2; return
    fi

    jq '.endpoints += [{"listen": "0.0.0.0:'$LOCAL_PORT'", "remote": "'$REMOTE_IP':'$REMOTE_PORT'"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart realm
    else
        killall realm 2>/dev/null
        nohup $BIN_FILE -c $CONFIG_FILE >/dev/null 2>&1 &
    fi
    echo -e "${GREEN}✅ 规则已生效！${NC}"
    sleep 2
}

list_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}暂无配置！${NC}"; return; fi
    echo -e "${CYAN}--- 当前生效的转发列表 ---${NC}"
    COUNT=$(jq '.endpoints | length' $CONFIG_FILE)
    if [ "$COUNT" -eq 0 ]; then
        echo -e "${YELLOW}当前没有规则。${NC}"
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
    COUNT=$(jq '.endpoints | length' $CONFIG_FILE)
    if [[ "$COUNT" -eq 0 ]]; then sleep 2; return; fi

    read -p "请输入要删除的规则编号 (q 取消): " IDX
    if [[ "$IDX" == "q" ]]; then return; fi

    if [[ "$IDX" =~ ^[0-9]+$ ]] && [ "$IDX" -lt "$COUNT" ]; then
        jq "del(.endpoints[$IDX])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart realm
        else
            killall realm 2>/dev/null
            nohup $BIN_FILE -c $CONFIG_FILE >/dev/null 2>&1 &
        fi
        echo -e "${GREEN}✅ 规则已删除！${NC}"
    fi
    sleep 2
}

# ================= 5. 主循环入口 =================
check_and_fix_env

while true; do
    clear
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}      Realm 智能管理脚本 (国内/外通用 V3.5)      ${NC}"
    echo -e "${GREEN}=================================================${NC}"
    
    if pgrep -x "realm" >/dev/null; then
        echo -e "  服务状态: ${GREEN}运行中 (Running)${NC}"
    else
        echo -e "  服务状态: ${RED}未运行${NC}"
    fi
    echo -e ""
    echo -e "  ${YELLOW}1.${NC} 安装/更新 Realm (含链路调优)"
    echo -e "  ${YELLOW}2.${NC} 添加转发映射"
    echo -e "  ${YELLOW}3.${NC} 查看/导出映射列表"
    echo -e "  ${YELLOW}4.${NC} 删除映射"
    echo -e "  ${YELLOW}5.${NC} 重启服务"
    echo -e "  ${YELLOW}0.${NC} 退出脚本"
    echo -e "${GREEN}=================================================${NC}"
    read -p "请选择 [0-5]: " OPTION

    case $OPTION in
        1) install_realm ;;
        2) add_rule ;;
        3) list_rules; echo -e "\n按回车键继续..."; read ;;
        4) delete_rule ;;
        5) if command -v systemctl >/dev/null 2>&1; then systemctl restart realm; else killall realm; nohup $BIN_FILE -c $CONFIG_FILE >/dev/null 2>&1 & fi; echo -e "${GREEN}服务已重启！${NC}"; sleep 1 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入！${NC}"; sleep 1 ;;
    esac
done
