#!/bin/bash
set -e

echo "========== 开始 GitHub 高速构建 (适配国内运行+官方源) =========="

# 1. 变量配置
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}
[[ ! "$MANAGEMENT_IP" == *"/"* ]] && MANAGEMENT_IP="${MANAGEMENT_IP}/24"

# 强制内核分区为 64MB
sed -i '/CONFIG_TARGET_KERNEL_PARTSIZE/d' .config
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
sed -i '/CONFIG_TARGET_ROOTFS_PARTSIZE/d' .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

# 2. 预准备阶段 (GitHub 海外环境高速拉取)
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

echo ">>> [GitHub 云端] 正在拉取插件包与核心..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$OC_URL" ] && wget -qO files/root/luci-app-openclash.ipk "$OC_URL"

AG_URL=$(curl -s https://api.github.com/repos/jerrykuku/luci-theme-argon/releases | grep -m 1 "browser_download_url.*\.ipk" | cut -d '"' -f 4)
[ -n "$AG_URL" ] && wget -qO files/root/luci-theme-argon.ipk "$AG_URL"

# 预置核心，防止国内环境下载失败导致 OpenClash 无法运行
META_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
wget -qO- "$META_CORE_URL" | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
chmod +x files/etc/openclash/core/clash_meta

# 3. 编写初始化脚本
cat << 'EOF' > files/etc/uci-defaults/99-custom-setup
#!/bin/sh

# --- 1. IP 与 主机名 ---
sed -i "s|192.168.100.1/24|$MANAGEMENT_IP|g" /etc/config/network 2>/dev/null || uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='Tanxm'

# --- 2. 国内 NTP 时间同步 ---
uci delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# --- 3. 智能网口分配 (eth0 为 WAN，其余 LAN) ---
INTERFACES=$(ls /sys/class/net | grep -E '^e(th|n)' | sort)
INT_COUNT=$(echo "$INTERFACES" | wc -w)
if [ "$INT_COUNT" -gt 1 ]; then
    uci set network.wan=interface
    uci set network.wan.device='eth0'
    uci set network.wan.proto='dhcp'
    uci set network.lan.device='br-lan'
    for iface in $INTERFACES; do
        [ "$iface" != "eth0" ] && uci add_list network.@device[0].ports="$iface"
    done
else
    uci delete network.wan
    uci delete network.wan6
    uci set network.lan.device='br-lan'
    uci add_list network.@device[0].ports='eth0'
fi
uci commit network

# --- 4. sda3 磁盘幂等处理 ---
if ! ls /dev/sda3 >/dev/null 2>&1; then
    echo ">>> 首次运行：正在创建 sda3 分区..."
    (echo n; echo 3; echo; echo; echo w) | fdisk /dev/sda
    sync && mkfs.ext4 /dev/sda3
fi
REAL_UUID=$(blkid -s UUID -o value /dev/sda3)
if [ -n "$REAL_UUID" ] && ! uci show fstab | grep -q "$REAL_UUID"; then
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# --- 5. 网络拥塞控制 (BBR) ---
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# --- 6. 软件源策略 (使用官方源 + 稳定性优化) ---
# 这里不修改为镜像站，保持官方 downloads.immortalwrt.org
# 但可以增加尝试次数和超时时间，应对国内连接波动
echo "option check_signature" >> /etc/opkg.conf
echo "option download_retries 3" >> /etc/opkg.conf
echo "option timeout 30" >> /etc/opkg.conf

# --- 7. 安装预置插件 ---
opkg update
# 强制安装本地 IPK，跳过部分可能存在的官方库版本冲突
opkg install /root/*.ipk
rm -rf /root/*.ipk /etc/uci-defaults/99-custom-setup
exit 0
EOF

# 变量注入
sed -i "s|\$MANAGEMENT_IP|$MANAGEMENT_IP|g" files/etc/uci-defaults/99-custom-setup
chmod +x files/etc/uci-defaults/99-custom-setup

# 4. 软件包清单
echo ">>> 定义软件包..."
PACKAGES="-dnsmasq dnsmasq-full luci luci-base luci-compat luci-i18n-base-zh-cn \
luci-i18n-firewall-zh-cn luci-app-ttyd luci-i18n-ttyd-zh-cn luci-app-ksmbd \
block-mount blkid lsblk parted fdisk e2fsprogs coreutils-nohup bash curl ca-bundle \
ip-full iptables-mod-tproxy iptables-mod-extra ruby ruby-yaml kmod-tun unzip iwinfo \
libcap-bin ca-certificates kmod-inet-diag kmod-tcp-bbr"

# 5. 执行编译
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files"

echo "========== 固件构建完成 =========="
