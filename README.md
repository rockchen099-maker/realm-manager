# 🚀 Realm Manager - 极简端口转发守护脚本

这是一个专为 **1核1G (1C1G) 低配云服务器** 量身定制的 [Realm](https://github.com/zhboner/realm) 交互式端口转发管理面板。

拒绝臃肿的 Web UI，拒绝多余的内存开销。本脚本采用纯 Bash 编写，结合系统级内核极限调优，将中转机的每一滴算力都用在刀刃上。

## ✨ 核心特性

* **🪶 极致轻量**：无任何网页后台或常驻 UI 进程，Realm 核心运行内存通常稳定在 10MB - 20MB 之间。
* **⚡ 内核级榨干**：安装时自动解除文件句柄限制 (LimitNOFILE)，自动开启 BBR 拥塞控制，并针对大带宽（300Mbps+）自动扩容 TCP 收发缓冲区至 16MB。
* **🛠️ 交互式管理**：全中文命令行菜单，支持**动态增删查改**、多端口独立并发转发。
* **🔄 平滑重启**：修改转发规则后自动热重载，不影响现有网络链路。
* **🇨🇳 国内机友好**：一键安装命令默认接入镜像加速，彻底解决国内中转机拉取 GitHub 脚本超时断连的痛点。

## 📥 一键安装与启动

在任意一台纯净的 Linux 服务器（推荐 **Debian 12** 或 Ubuntu 22.04）上，使用 `root` 用户登录并执行以下命令：
```bash
bash <(curl -sL [https://ghproxy.net/https://raw.githubusercontent.com/rockchen099-maker/realm-manager/main/realm.sh](https://ghproxy.net/https://raw.githubusercontent.com/rockchen099-maker/realm-manager/main/realm.sh))
