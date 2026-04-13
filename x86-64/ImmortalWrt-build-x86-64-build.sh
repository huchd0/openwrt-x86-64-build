#!/bin/bash
set -e

echo "========== 开始 GitHub 极速纯净版构建 =========="

# ==========================================
# 1. 基础网络参数提取
# ==========================================
INPUT_IP=${MANAGEMENT_IP:-192.168.100.1}
IP_ADDR=$(echo "$INPUT_IP" | cut -d'/' -f1)
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}

# ==========================================
# 2. 极致优化：分区锁定与冗余镜像剔除
# ==========================================
echo ">>> 执行极致优化：砍掉所有不必要的虚拟机格式..."
sed -i '/CONFIG_TARGET_KERNEL_PARTSIZE/d' .config
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
sed -i '/CONFIG_TARGET_ROOTFS_PARTSIZE/d' .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config

# ==========================================
# 3. 预埋 OpenClash Meta 核心
# ==========================================
# OpenClash 本体将通过 ImageBuilder 原生编译
mkdir -p files/etc/openclash/core files/etc/uci-defaults

echo ">>> 正在预埋 OpenClash Meta 核心..."
META_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
wget -qO- "$META_CORE_URL" | tar -zxf - -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
chmod +x files/etc/openclash/core/clash_meta

# ==========================================
# 4. 编写开机自启脚本
# ==========================================
cat << 'EOF' > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
exec > /root/setup-network.log 2>&1
set -x

# --- 1. IP与主机名 ---
uci set network.lan.ipaddr='REPLACE_IP_ADDR'
uci set network.lan.netmask='255.255.255.0'
uci set system.@system[0].hostname='Tanxm'

# --- 2. 重构级：严格网口分配 ---
# 【粉碎重建逻辑】：暴力删除旧的设备定义
while uci -q delete network.@device[0]; do :; done

# 重新建立干净的 br-lan 桥接设备
uci set network.br_lan=device
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'

INTERFACES=$(ls /sys/class/net | grep -E '^e(th|n)' | sort)
INT_COUNT=$(echo "$INTERFACES" | wc -w)

if [ "$INT_COUNT" -gt 1 ]; then
    # 【多口模式】：WAN / WAN6 独占 eth0
    uci set network.wan=interface
    uci set network.wan.device='eth0'
    uci set network.wan.proto='dhcp'
    
    uci set network.wan6=interface
    uci set network.wan6.device='eth0'
    uci set network.wan6.proto='dhcpv6'
    
    # 将剩下的物理口，全部加入桥接
    for iface in $INTERFACES; do
        if [ "$iface" != "eth0" ]; then
            uci add_list network.br_lan.ports="$iface"
        fi
    done
else
    # 【单口模式】：删除 WAN，唯一的 eth0 归 LAN
    uci delete network.wan 2>/dev/null
    uci delete network.wan6 2>/dev/null
    uci add_list network.br_lan.ports='eth0'
fi

# 确保 LAN 接口绑定在新的 br-lan 上
uci set network.lan.device='br-lan'
uci commit network

# --- 3. sda3 智能挂载 (不强制格式化) ---
REAL_UUID=$(blkid -s UUID -o value /dev/sda3 2>/dev/null)
if [ -n "$REAL_UUID" ] && ! uci show fstab | grep -q "$REAL_UUID"; then
    echo "检测到存在 sda3，正在配置开机自动挂载..."
    uci add fstab mount
    uci set fstab.@mount[-1].uuid="$REAL_UUID"
    uci set fstab.@mount[-1].target='/mnt/sda3'
    uci set fstab.@mount[-1].enabled='1'
    uci commit fstab
fi

# --- 4. 优化：BBR, NTP 与 国内源 ---
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

uci delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='time1.cloud.tencent.com'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 路由器落地后自动替换为国内镜像源 (兼容 apk 和 opkg)
if command -v apk >/dev/null 2>&1; then
    if [ -d "/etc/apk/repositories.d" ]; then
        sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
    fi
elif command -v opkg >/dev/null 2>&1; then
    if [ -f "/etc/opkg/distfeeds.conf" ]; then
        sed -i 's/downloads.immortalwrt.org/mirrors.ustc.edu.cn\/immortalwrt/g' /etc/opkg/distfeeds.conf 2>/dev/null || true
    fi
fi

rm -f /etc/uci-defaults/99-custom-setup
/etc/init.d/network restart
exit 0
EOF

sed -i "s|REPLACE_IP_ADDR|$IP_ADDR|g" files/etc/uci-defaults/99-custom-setup
chmod +x files/etc/uci-defaults/99-custom-setup

# ==========================================
# 5. 云端加速：替换 ImageBuilder 构建源
# ==========================================
echo ">>> 正在优化 ImageBuilder 构建源为腾讯云 (加速拉取)..."
if [ -f "repositories.conf" ]; then
    sed -i 's/downloads.immortalwrt.org/mirrors.cloud.tencent.com\/immortalwrt/g' repositories.conf
fi
if [ -d "repositories.d" ]; then
    sed -i 's/downloads.immortalwrt.org/mirrors.cloud.tencent.com\/immortalwrt/g' repositories.d/*.list
fi

# ==========================================
# 6. 模块化定义软件包
# ==========================================
echo ">>> 定义软件包..."

PKG_CORE=(
    "-dnsmasq"
    "dnsmasq-full"
    "luci"
    "luci-base"
    "luci-compat"
    "luci-i18n-base-zh-cn"
    "luci-i18n-firewall-zh-cn"
    "luci-theme-argon"
    "luci-app-openclash"
    "luci-i18n-package-manager-zh-cn"
)

PKG_TOOL=(
    "bash"
    "curl"
    "coreutils-nohup"
    "unzip"
    "luci-i18n-ttyd-zh-cn"
)

PKG_DISK=(
    "blkid"
    "lsblk"
    "parted"
    "fdisk"
    "e2fsprogs"            
    "block-mount"
    "luci-i18n-diskman-zh-cn"
    "luci-i18n-filemanager-zh-cn"
)

PKG_SHARE=(
    "luci-i18n-ksmbd-zh-cn"
)

PKG_CLASH_DEPS=(
    "ip-full"
    "iptables-mod-tproxy"
    "iptables-mod-extra"
    "kmod-tun"
    "kmod-inet-diag"
    "kmod-tcp-bbr"
    "ruby"
    "ruby-yaml"
    "libcap-bin"
    "ca-certificates"
)

ALL_PKGS=(
    "${PKG_CORE[@]}"
    "${PKG_TOOL[@]}"
    "${PKG_DISK[@]}"
    "${PKG_SHARE[@]}"
    "${PKG_CLASH_DEPS[@]}"
)
PACKAGES="${ALL_PKGS[*]}"

# ==========================================
# 7. 开始打包
# ==========================================
echo ">>> 正在执行 Make Image 编译..."
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi"

echo "========== 固件构建圆满完成 =========="
