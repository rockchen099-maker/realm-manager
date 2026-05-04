```bash
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

# ================= 检查与基础依赖 =================
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行此脚本！${NC}"
  exit 1
fi

install_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}正在安装必要的依赖包 (jq, curl, tar)...${NC}"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y jq curl tar >/dev/null 2>&1
    fi
}

# ================= 核心功能：安装与系统优化 =================
install_realm() {
    echo -e "${CYAN}--- 开始安装 Realm 并进行极限性能优化 ---${NC}"
    install_dependencies
    
    echo -e "${YELLOW}1. 下载最新版 Realm 核心...${NC}"
    curl -L -o realm.tar.gz "[https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz](https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz)" >/dev/null 2>&1
    tar -xvf realm.tar.gz >/dev/null 2>&1
    chmod +x realm && mv realm $BIN_FILE
    rm -f realm.tar.gz

    echo -e "${YELLOW}2. 初始化基础配置...${NC}"
    mkdir -p $CONFIG_DIR
    cat > $CONFIG_FILE << EOCC
{
  "network": {
    "no_tcp_delay": true,
    "keepalive": 30
  },
  "endpoints": []
}
EOCC

    echo -e "${YELLOW}3. 写入系统守护进程 (解除最大文件连接数限制)...${NC}"
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

    echo -e "${YELLOW}4. 正在进行极限系统网络调优 (1C1G 专属榨干配置)...${NC}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf

    cat >> /etc/sysctl.conf << EOT
# Realm 优化配置
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 16384 16777216
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_syncookies=1
EOT
    sysctl -p >/dev/null 2>&1

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    systemctl restart realm
    echo -e "${GREEN}Realm 安装及优化完毕！系统潜能已拉满！${NC}"
    sleep 2
}

# ================= 核心功能：添加转发 =================
add_rule() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}尚未安装 Realm，请先选择安装！${NC}"; sleep 2; return
    fi
    echo -e "${CYAN}--- 添加新转发规则 ---${NC}"
    read -p "请输入 [本地监听端口]: " LOCAL_PORT
    read -p "请输入 [目标服务器IP]: " REMOTE_IP
    read -p "请输入 [目标端口]: " REMOTE_PORT

    if [[ -z "$LOCAL_PORT" || -z "$REMOTE_IP" || -z "$REMOTE_PORT" ]]; then
        echo -e "${RED}输入不能为空，操作取消。${NC}"; sleep 2; return
    fi

    cp $CONFIG_FILE ${CONFIG_FILE}.bak
    jq '.endpoints += [{"listen": "0.0.0.0:'$LOCAL_PORT'", "remote": "'$REMOTE_IP':'$REMOTE_PORT'"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    
    systemctl restart realm
    echo -e "${GREEN}规则已添加并生效: 0.0.0.0:$LOCAL_PORT -> $REMOTE_IP:$REMOTE_PORT${NC}"
    sleep 2
}

# ================= 核心功能：查看与删除 =================
list_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then echo -e "${RED}暂无配置！${NC}"; return; fi
    echo -e "${CYAN}--- 当前生效的转发列表 ---${NC}"
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
    echo -e "----------------------------------------"
}

delete_rule() {
    list_rules
    COUNT=$(jq '.endpoints | length' $CONFIG_FILE)
    if [ "$COUNT" -eq 0 ]; then sleep 2; return; fi

    read -p "请输入要删除的规则编号 (0-$((COUNT-1))，输入 q 取消): " IDX
    if [[ "$IDX" == "q" || "$IDX" == "Q" ]]; then return; fi

    if [[ "$IDX" =~ ^[0-9]+$ ]] && [ "$IDX" -ge 0 ] && [ "$IDX" -lt "$COUNT" ]; then
        cp $CONFIG_FILE ${CONFIG_FILE}.bak
        jq "del(.endpoints[$IDX])" $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        systemctl restart realm
        echo -e "${GREEN}编号 $IDX 的规则已成功删除并重启服务！${NC}"
    else
        echo -e "${RED}无效的编号！${NC}"
    fi
    sleep 2
}

# ================= 主菜单逻辑 =================
while true; do
    clear
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}      Realm 守护脚本 (极限提速版)    ${NC}"
    echo -e "${GREEN}=================================================${NC}"
    
    if systemctl is-active --quiet realm; then
        echo -e "  服务状态: ${GREEN}运行中 (Active)${NC}"
    else
        echo -e "  服务状态: ${RED}未安装 或 已停止${NC}"
    fi
    echo -e ""
    echo -e "  ${YELLOW}1.${NC} 安装 Realm (含系统内核提速优化)"
    echo -e "  ${YELLOW}2.${NC} 添加转发映射"
    echo -e "  ${YELLOW}3.${NC} 查看映射列表"
    echo -e "  ${YELLOW}4.${NC} 删除映射"
    echo -e "  ${YELLOW}5.${NC} 重启服务"
    echo -e "  ${YELLOW}0.${NC} 退出脚本"
    echo -e "${GREEN}=================================================${NC}"
    read -p "请输入选择 [0-5]: " OPTION

    case $OPTION in
        1) install_realm ;;
        2) add_rule ;;
        3) list_rules; echo "按回车键继续..."; read ;;
        4) delete_rule ;;
        5) systemctl restart realm; echo -e "${GREEN}服务已重启！${NC}"; sleep 1 ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效！${NC}"; sleep 1 ;;
    esac
done
