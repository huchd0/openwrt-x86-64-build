#!/bin/bash

# =========================================================
# 0. 准备动态初始化脚本
# =========================================================
mkdir -p files/etc/uci-defaults
DYNAMIC_SCRIPT="files/etc/uci-defaults/99-dynamic-settings"

echo "#!/bin/sh" > $DYNAMIC_SCRIPT
echo "uci set network.lan.ipaddr='$CUSTOM_IP'" >> $DYNAMIC_SCRIPT

# =========================================================
# 1. 隐式底层强化包 (包含磁盘工具与备份核心)
# =========================================================
BASE_PACKAGES=""
# 🌟 系统核心与磁盘管理工具 (注意：此处使用的是正确的 lsblk)
BASE_PACKAGES="$BASE_PACKAGES base-files block-mount default-settings-chn luci-i18n-base-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES sgdisk parted e2fsprogs fdisk lsblk blkid tar"
# 性能优化
BASE_PACKAGES="$BASE_PACKAGES irqbalance zram-swap iperf3 htop curl wget-ssl kmod-vmxnet3"
# 常用静默预装小工具
BASE_PACKAGES="$BASE_PACKAGES luci-app-ttyd luci-i18n-ttyd-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-upnp luci-i18n-upnp-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-wol luci-i18n-wol-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-ramfree luci-i18n-ramfree-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-autoreboot luci-i18n-autoreboot-zh-cn"

# =========================================================
# 🌟 开机拉伸、数据盘绑定、以及“原生备份”机制
# =========================================================
# 提前计算 P3 的物理安全起点 (Kernel 64MB + 用户填写的 RootFS 目标容量)
START_P3=$(( 64 + ROOTFS_SIZE ))

cat >> $DYNAMIC_SCRIPT << EOF
# 1. 抓取物理主硬盘
ROOT_DISK=\$(lsblk -d -n -o NAME | grep -E 'sda|nvme[0-9]n[0-9]' | head -n 1)
if [ -n "\$ROOT_DISK" ]; then
    DISK_DEV="/dev/\$ROOT_DISK"
    # 适配 NVMe 和 SATA 分区命名差异
    echo "\$ROOT_DISK" | grep -q "nvme" && P2="\${DISK_DEV}p2" && P3="\${DISK_DEV}p3" || P2="\${DISK_DEV}2" && P3="\${DISK_DEV}3"

    # 2. 只有在全新刷机(找不到 P3 数据盘)时，才执行全局初始化
    if ! lsblk \$P3 >/dev/null 2>&1; then
        sgdisk -e \$DISK_DEV
        
        # 拉伸系统盘 (P2) 至用户指定大小
        parted -s \$DISK_DEV resizepart 2 ${START_P3}MiB
        sync && sleep 1
        resize2fs \$P2
        
        # 建立数据盘 (P3) 占满剩余所有空间
        parted -s \$DISK_DEV mkpart primary ext4 ${START_P3}MiB 100%
        sync && sleep 2
        mkfs.ext4 -F \$P3
    else
        # 刷机更新模式(保留数据)：依然修复 GPT 并拉伸 P2，但绝对不格式化 P3！
        sgdisk -e \$DISK_DEV
        parted -s \$DISK_DEV resizepart 2 ${START_P3}MiB
        sync && sleep 1
        resize2fs \$P2
    fi

    # 3. UUID 稳健挂载到 /opt (防止硬盘插拔导致盘符错乱)
    P3_UUID=\$(blkid -s UUID -o value \$P3)
    if [ -n "\$P3_UUID" ]; then
        uci -q delete fstab.opt_mount || true
        uci set fstab.opt_mount='mount'
        uci set fstab.opt_mount.uuid="\$P3_UUID"
        uci set fstab.opt_mount.target='/opt'
        uci set fstab.opt_mount.fstype='ext4'
        uci set fstab.opt_mount.enabled='1'
        uci commit fstab
    fi

    # 4. 🚀 建立“原生备份”与“一键恢复”指令
    mkdir -p /opt/backup /opt/docker /opt/alist /opt/downloads /opt/smb
    mount \$P3 /opt 2>/dev/null
    
    # 建立备份：将开机第一刻最纯净的设定进行打包存档
    sleep 3
    tar -czf /opt/backup/factory_config.tar.gz /etc/config /etc/passwd /etc/shadow /etc/dropbear
    
    # 写入系统全局恢复指令 (输入 restore-factory 即可调用)
    cat > /bin/restore-factory << 'INNER'
#!/bin/sh
echo "警告：即将恢复初始系统设定并重启！"
if [ -f /opt/backup/factory_config.tar.gz ]; then
    rm -rf /etc/config/*
    tar -xzf /opt/backup/factory_config.tar.gz -C /
    echo "恢复成功，正在重启系统..."
    reboot
else
    echo "错误：找不到备份文件，无法恢复！"
fi
INNER
    chmod +x /bin/restore-factory
fi
EOF

# =========================================================
# 2. 插件追加逻辑
# =========================================================
[ "$THEME_ARGON" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon"
[ "$APP_HOMEPROXY" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-homeproxy luci-i18n-homeproxy-zh-cn"
[ "$APP_OPENCLASH" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"
[ "$APP_KSMBD" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-ksmbd luci-i18n-ksmbd-zh-cn"
[ "$APP_ALIST" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-alist"
[ "$APP_QBITTORRENT" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-qbittorrent luci-i18n-qbittorrent-zh-cn"
[ "$APP_STATISTICS" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-statistics luci-i18n-statistics-zh-cn collectd collectd-mod-cpu collectd-mod-interface collectd-mod-memory"
[ "$APP_TAILSCALE" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES tailscale"
[ "$KMOD_IGC" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES kmod-igc"
[ "$INCLUDE_DOCKER" = "true" ] && BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman luci-i18n-dockerman-zh-cn docker-compose"

# =========================================================
# 4. 锁死物理参数、极致精简输出并执行编译
# =========================================================
echo "uci commit" >> $DYNAMIC_SCRIPT
echo "exit 0" >> $DYNAMIC_SCRIPT
chmod +x $DYNAMIC_SCRIPT

# 🛡️ 锁死 Kernel 为 64MB (确保未来重刷固件时数据盘起点的物理扇区绝对不偏移)
if grep -q "CONFIG_TARGET_KERNEL_PARTSIZE" .config; then
    sed -i "s/CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/g" .config
else
    echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
fi

# 🎯 锁死 RootFS 初始云端打包体积为 1024MB (装下海量插件，开机后再扩容)
if grep -q "CONFIG_TARGET_ROOTFS_PARTSIZE" .config; then
    sed -i "s/CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=1024/g" .config
else
    echo "CONFIG_TARGET_ROOTFS_PARTSIZE=1024" >> .config
fi

# ✂️ 极致精简输出：只保留 ext4，砍掉 squashfs 和所有无用的虚拟机格式！
echo "CONFIG_TARGET_ROOTFS_EXT4FS=y" >> .config      # 必须保留 ext4 (扩容魔法的基石)
echo "CONFIG_TARGET_ROOTFS_SQUASHFS=n" >> .config    # 砍掉 squashfs
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config       # 砍掉 .tar.gz 备份包
echo "CONFIG_VDI_IMAGES=n" >> .config                # 砍掉 VirtualBox 格式
echo "CONFIG_VMDK_IMAGES=n" >> .config               # 砍掉 VMware 格式
echo "CONFIG_VHDX_IMAGES=n" >> .config               # 砍掉 Hyper-V 格式
echo "CONFIG_QCOW2_IMAGES=n" >> .config              # 砍掉 QEMU 格式
echo "CONFIG_ISO_IMAGES=n" >> .config                # 砍掉 ISO 镜像

echo ">>> 最终打包的软件列表: $BASE_PACKAGES"

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
