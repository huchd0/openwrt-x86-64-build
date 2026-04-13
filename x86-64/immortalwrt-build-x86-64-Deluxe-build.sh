#!/bin/bash
set -e

# 接收环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

echo ">>> 1. 固件底层参数配置 <<<"
{
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64"
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE"
    echo "CONFIG_TARGET_ROOTFS_EXT4FS=n"
    echo "CONFIG_TARGET_ROOTFS_TARGZ=n"
    echo "CONFIG_GRUB_IMAGES=n"
} >> .config

echo ">>> 2. 准备组件目录与核心内核 (仅 OpenClash Meta) <<<"
mkdir -p files/etc/uci-defaults files/etc/init.d files/etc/openclash/core files/lib/firmware/mediatek/mt7925

# 仅预下载 OpenClash Meta 内核，因为它是第三方库不带的
echo "正在预载 OpenClash 核心..."
wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz" | tar xOvz > files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta

echo ">>> 3. 创建持久化后台安装脚本 (直到装完为止) <<<"
cat << 'EOF' > files/etc/auto_install.sh
#!/bin/sh

# 检查网络连接
check_net() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1
}

sleep 15 # 等待拨号就绪

if check_net; then
    echo "网络通畅，开始增量安装大插件..."
    apk update
    
    # 在线安装：Docker, OpenClash, Wi-Fi 7驱动, 以及你要求的 HomeProxy
    apk add luci-app-openclash \
            luci-i18n-homeproxy-zh-cn \
            dockerd docker-compose luci-app-dockerman \
            kmod-mt7925e kmod-mt7925-firmware kmod-btusb wpad-openssl \
            kmod-fs-vfat kmod-fs-ntfs3
    
    if [ $? -eq 0 ]; then
        echo "安装成功，执行收尾工作..."
        # 自动挂载大分区并迁移 Docker 路径
        mkdir -p /mnt/sda3/docker
        uci set dockerd.globals.data_root='/mnt/sda3/docker'
        uci commit dockerd
        
        # 卸载自启动任务
        /etc/init.d/auto_install disable
        rm -f /etc/init.d/auto_install
        rm -f /etc/auto_install.sh
    fi
else
    echo "当前无网络，等待下次开机尝试..."
fi
EOF
chmod +x files/etc/auto_install.sh

# 注册自启动服务
cat << 'EOF' > files/etc/init.d/auto_install
#!/bin/sh /etc/rc.common
START=99
start() {
    /etc/auto_install.sh &
}
EOF
chmod +x files/etc/init.d/auto_install

echo ">>> 4. 编写基础初始化 (UCI 设置) <<<"
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='Tanxm'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 自动建立 sda3 扩展分区
if ! lsblk | grep -q sda3; then
    echo -e "n\n3\n\n\nw" | fdisk /dev/sda >/dev/null 2>&1
    partprobe /dev/sda >/dev/null 2>&1 || true
    sleep 2
    mkfs.ext4 -F /dev/sda3 >/dev/null 2>&1
fi

# 激活 Argon 界面
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci

# 启用增量安装服务
/etc/init.d/auto_install enable

rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF

echo ">>> 5. 构建软件包列表 (极致瘦身) <<<"
# 通过 "-" 号强制排除掉 ImageBuilder 默认带的大堆无用驱动，极速出包
PACKAGES="base-files libc libgcc apk-openssl block-mount fdisk e2fsprogs kmod-fs-ext4 bash curl jq htop \
luci-theme-argon luci-app-argon-config \
luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn luci-i18n-samba4-zh-cn \
luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn \
kmod-igc kmod-r8125 kmod-r8169 kmod-usb-net-rtl8152-vendor \
-kmod-amazon-ena -kmod-bnx2 -kmod-forcedeth -kmod-i40e -kmod-ixgbe -kmod-ixgbevf -kmod-tg3"

# 官方源构建加速隧道
if [ -f "repositories.conf" ]; then
    sed -i 's/https:\/\//http:\/\//g' repositories.conf
    echo "104.21.75.148 downloads.immortalwrt.org" >> /etc/hosts
fi
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true

echo ">>> 6. 开始打包 (多核压榨) <<<"
make image -j$(nproc) PROFILE="generic" PACKAGES="$PACKAGES" FILES="files" EXTRA_IMAGE_NAME="efi-J4125"

echo ">>> 7. 提取固件 <<<"
find bin/targets/x86/64/ -type f -not -name "*combined-efi*.img.gz" -not -name "*sha256sums" -delete
