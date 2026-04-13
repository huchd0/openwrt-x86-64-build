#!/bin/bash
set -e

# 接收环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

echo ">>> 1. 固件参数配置 <<<"
{
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64"
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE"
    echo "CONFIG_TARGET_ROOTFS_EXT4FS=n"
    echo "CONFIG_TARGET_ROOTFS_TARGZ=n"
    echo "CONFIG_GRUB_IMAGES=n"
} >> .config

echo ">>> 2. 准备组件与内核核心 <<<"
mkdir -p files/etc/uci-defaults files/etc/init.d files/etc/openclash/core

# 预载 OpenClash Meta 内核 (美国机房直连秒下)
wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta

echo ">>> 3. 创建持久化后台安装脚本 <<<"
cat << 'EOF' > files/etc/auto_install.sh
#!/bin/sh

check_net() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1
}

sleep 15 # 等待拨号

if check_net; then
    echo "开始增量安装..."
    apk update
    
    # 将原本沉重的包全部移到这里
    apk add luci-app-openclash \
            luci-i18n-homeproxy-zh-cn \
            luci-i18n-samba4-zh-cn \
            luci-i18n-package-manager-zh-cn \
            luci-app-argon-config \
            dockerd docker-compose luci-app-dockerman \
            kmod-mt7925e kmod-mt7925-firmware kmod-btusb wpad-openssl \
            kmod-fs-vfat kmod-fs-ntfs3
    
    if [ $? -eq 0 ]; then
        # 挂载分区并迁移 Docker
        mkdir -p /mnt/sda3/docker
        uci set dockerd.globals.data_root='/mnt/sda3/docker'
        uci commit dockerd
        
        # 激活 Argon 主题 (以防万一)
        uci set luci.main.mediaurlbase='/luci-static/argon'
        uci commit luci

        /etc/init.d/auto_install disable
        rm -f /etc/init.d/auto_install
        rm -f /etc/auto_install.sh
    fi
fi
EOF
chmod +x files/etc/auto_install.sh

cat << 'EOF' > files/etc/init.d/auto_install
#!/bin/sh /etc/rc.common
START=99
start() {
    /etc/auto_install.sh &
}
EOF
chmod +x files/etc/init.d/auto_install

echo ">>> 4. 编写基础初始化 <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='Tanxm'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 基础磁盘分区
if ! lsblk | grep -q sda3; then
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 2
    mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
fi

# 启用后台安装
/etc/init.d/auto_install enable
rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF

echo ">>> 5. 构建软件包列表 (极限精简) <<<"
# 仅保留生存必需包：Luci基础界面 + Argon主题 + 基本网络工具 + J4125网卡驱动
# 手动剔除几乎所有多余驱动，压缩包数量
PACKAGES="base-files libc libgcc apk-openssl block-mount fdisk e2fsprogs kmod-fs-ext4 \
bash curl jq htop luci-theme-argon luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-ttyd-zh-cn \
kmod-igc kmod-r8125 kmod-r8169 kmod-usb-net-rtl8152-vendor \
-kmod-amazon-ena -kmod-bnx2 -kmod-forcedeth -kmod-i40e -kmod-ixgbe -kmod-ixgbevf -kmod-tg3 -kmod-8139cp -kmod-8139too"

# 构建加速配置
if [ -f "repositories.conf" ]; then
    sed -i 's/https:\/\//http:\/\//g' repositories.conf
    echo "104.21.75.148 downloads.immortalwrt.org" >> /etc/hosts
fi
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true

echo ">>> 6. 开始多核打包 <<<"
make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-J4125"

echo ">>> 7. 提取固件 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete
