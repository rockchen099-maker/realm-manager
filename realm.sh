#!/bin/bash

# ================= 设置颜色 =================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_DIR="/etc/realm"
CONFIG_FILE="$CONFIG_DIR/config.json"
BIN_FILE="/usr/local/bin/realm"

# ================= 权限与基础环境检查 =================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行此脚本！${NC}"
    exit 1
fi

check_and_fix_env() {
    if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}检测到必要工具缺失，正在安装依赖...${NC}"
        if command -v apt-get &> /dev/null; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y jq curl tar >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y epel-release >/dev/null 2>&1
            yum install -y jq curl tar >/dev/null 2>&1
        fi
    fi
}

# ================= 核心功能：安装与系统优化 =================
install_realm() {
    echo -e "${CYAN}--- 开始安装 Realm 并进行极致中转优化 ---${NC}"
    
    echo -e "${YELLOW}1. 下载 Realm 核心 (多源自动切换)...${NC}"
    # 备选镜像站列表
    MIRRORS=(
        "https://mirror.ghproxy.com/https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
        "https://kkgithub.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
        "https://github.moeyy.xyz/https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    )

    SUCCESS=false
    for URL in "${MIRRORS[@]}"; do
        echo -e "${CYAN}尝试从镜像源下载: $URL ${NC}"
        curl -L -o realm.tar.gz "$URL" --connect-timeout 10 --max-time 60
        
        # 校验文件大小，Realm 核心通常 > 1MB (1048576 字节)
        if [ -f "realm.tar.gz" ] && [ $(stat -c%s "realm.tar.gz") -gt 1000000 ]; then
            SUCCESS=true
            break
        else
            echo -e "${RED}当前源下载失败或文件损坏，切换下一个...${NC}"
            rm -f realm.tar.gz
        fi
    done

    if [ "$SUCCESS" = false ]; then
        echo -e "${RED}❌ 所有镜像站均无法连接，请手动下载并放置在当前目录后重试！${NC}"
        return
    fi
    
    tar -xvf realm.tar.gz >/dev/null 2>&1
    chmod +x realm && mv realm $BIN_FILE
    rm -f realm.tar.gz

    echo -e "${YELLOW}2. 初始化基础配置 (注入空占位符防止服务停止)...${NC}"
    mkdir -p $CONFIG_DIR
    # 如果配置文件不存在，初始化一个包含基础结构的 JSON
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

    echo -e "${YELLOW}3. 写入系统守护进程...${NC}"
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

    echo -e "${YELLOW}4. 正在注入中转机专属内核参数 (BBR+链路调优)...${NC}"
    sed -i '/net.core/d' /etc/sysctl.conf
    sed -i '/net.ipv4/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf << EOT
# Realm 极致优化参数
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=15
net.ipv4.ip_local_port_range=1024 65535
EOT
    sysctl -p >/dev/null 2>&1

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    systemctl restart realm
    echo -e "${GREEN}✅ Realm 安装及优化完毕！${NC}"
    sleep 2
}

add_rule() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}请先选 1 安装！${NC}"; sleep 2; return; fi
    echo -e "${CYAN}--- 添加新转发规则 ---${NC}"
    read -p "请输入 [本地监听端口]: " LOCAL_PORT
    read -p "请输入 [目标落地机IP]: " REMOTE_IP
    read -p "请输入 [目标落地机端口]: " REMOTE_PORT

    if [[ -z "$LOCAL_PORT" || -z "$REMOTE_IP" || -z "$REMOTE_PORT" ]]; then
        echo -e "${RED}输入不能为空。${NC}"; sleep 2; return
    fi

    cp $CONFIG_FILE ${CONFIG_FILE}.bak
    jq '.endpoints += [{"listen": "0.0.0.0:'$LOCAL_PORT'", "remote": "'$REMOTE_IP':'$REMOTE_PORT'"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    
    systemctl restart realm
    echo -e "${GREEN}✅ 规则已添加并重启生效！${NC}"
    sleep 2
}

list_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}暂无配置！${NC}"; return; fi
    echo -e "${CYAN}--- 当前生效的转发列表 ---${NC}"
    if ! command -v jq &> /dev/null; then echo -e "${RED}缺少 jq 工具${NC}"; return; fi
    
    COUNT=$(jq '.endpoints | length' $CONFIG_FILE)
    if [ "$COUNT" -eq 0 ]; then
        echo -e "${YELLOW}当前没有转发规则，服务可能显示为 Inactive。${NC}"
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
    if [ ! -f "$CONFIG_FILE" ]; then return; fi
    COUNT=$(jq '.endpoints | length' $CONFIG_FILE)
    if [ "$COUNT" -eq 0 ]; then sleep 2; return; fi

    read -p "请输入要删除的规则编号 (q 取消): " IDX
    if [[ "$IDX" == "q" || "$IDX" == "Q" ]]; then return; fi

    if [[ "$IDX" =~ ^[0-9]+$ ]] && [ "$IDX" -ge 0 ] && [ "$IDX" -lt "$COUNT" ]; then
        cp $CONFIG_FILE ${CONFIG_FILE}.bak
        jq "del(.endpoints[$IDX])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        systemctl restart realm
        echo -e "${GREEN}规则已删除！${NC}"
    else
        echo -e "${RED}编号无效！${NC}"
    fi
    sleep 2
}

# ================= 主循环 =================
check_and_fix_env
while true; do
    clear
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}      Realm 守护脚本 (中转加速 V3.4)      ${NC}"
    echo -e "${GREEN}=================================================${NC}"
    
    # 获取详细状态
    if systemctl is-active --quiet realm; then
        echo -e "  服务状态: ${GREEN}运行中 (Active)${NC}"
    else
        echo -e "  服务状态: ${RED}已停止 (或无配置)${NC}"
        echo -e "  ${YELLOW}提示: Realm 需要至少 1 条映射规则才能保持运行状态${NC}"
    fi
    echo -e ""
    echo -e "  ${YELLOW}1.${NC} 安装/更新 Realm (含链路调优)"
    echo -e "  ${YELLOW}2.${NC} 添加转发映射"
    echo -e "  ${YELLOW}3.${NC} 查看映射列表"
    echo -e "  ${YELLOW}4.${NC} 删除映射"
    echo -e "  ${YELLOW}5.${NC} 重启服务"
    echo -e "  ${YELLOW}0.${NC} 退出脚本"
    echo -e "${GREEN}=================================================${NC}"
    read -p "请选择 [0-5]: " OPTION

    case $OPTION in
        1) install_realm ;;
        2) add_rule ;;
        3) list_rules; echo "按回车键继续..."; read ;;
        4) delete_rule ;;
        5) systemctl restart realm; echo -e "${GREEN}服务已重启！${NC}"; sleep 1 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入！${NC}"; sleep 1 ;;
    esac
done
