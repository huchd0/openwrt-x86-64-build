#!/bin/bash
set -e

# 接收 GitHub Actions 传来的环境变量
ROOTFS_SIZE=${ROOTFS_SIZE:-1024}
MANAGEMENT_IP=${MANAGEMENT_IP:-192.168.100.1}

if [[ ! "$MANAGEMENT_IP" == *"/"* ]]; then
    MANAGEMENT_IP="${MANAGEMENT_IP}/24"
fi

echo "=== 1. 自定义固件参数 (互刷保护) ==="
echo "CONFIG_TARGET_KERNEL_PARTSIZE=64" >> .config
echo "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" >> .config

# 极致优化：只生成 UEFI 的 squashfs 格式
echo "CONFIG_TARGET_ROOTFS_EXT4FS=n" >> .config
echo "CONFIG_TARGET_ROOTFS_TARGZ=n" >> .config
echo "CONFIG_VMDK_IMAGES=n" >> .config
echo "CONFIG_VDI_IMAGES=n" >> .config
echo "CONFIG_VHDX_IMAGES=n" >> .config
echo "CONFIG_QCOW2_IMAGES=n" >> .config
echo "CONFIG_ISO_IMAGES=n" >> .config
echo "CONFIG_GRUB_IMAGES=n" >> .config

echo "=== 2. 准备初始化文件夹 ==="
mkdir -p files/etc/uci-defaults
mkdir -p files/etc/init.d

echo "=== 3. 下载必要核心与驱动固件 ==="

echo "正在下载 OpenClash Meta 兼容版内核..."
mkdir -p files/etc/openclash/core
wget -qO files/etc/openclash/core/meta.tar.gz "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-compatible.tar.gz"
tar -zxf files/etc/openclash/core/meta.tar.gz -C files/etc/openclash/core/
mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta
chmod +x files/etc/openclash/core/clash_meta
rm -f files/etc/openclash/core/meta.tar.gz

echo "正在注入 MT7925 官方底层固件..."
mkdir -p files/lib/firmware/mediatek/mt7925

wget -qO files/lib/firmware/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin"
wget -qO files/lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/53539c0625c5dbdd2308146e3435f06b51f68c01/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin"

echo "=== 4. 编写全自动开机初始化脚本 ==="

# 注意这里的路径，千万不能有空格
cat << 'EOF_WIFI' > files/etc/init.d/wifi-auto-patch
#!/bin/sh /etc/rc.common
START=99

start() {
    (
        WAIT=0
        while [ $WAIT -lt 30 ]; do
            wifi config
            if uci get wireless.radio0 >/dev/null 2>&1; then
                break
            fi
            sleep 2
            WAIT=$((WAIT+1))
        done

        if uci get wireless.radio0 >/dev/null 2>&1; then
            uci set wireless.radio0.band='5g'
            uci set wireless.radio0.channel='149'
            uci set wireless.radio0.htmode='EHT80'
            uci set wireless.radio0.country='AU'
            uci set wireless.radio0.cell_density='0'
            uci set wireless.radio0.txpower='23'
            
            for iface in $(uci show wireless | grep '=wifi-iface' | cut -d'.' -f2 | cut -d'=' -f1); do
                uci set wireless.${iface}.ssid='mywifi7'
                uci set wireless.${iface}.encryption='sae-mixed'
                uci set wireless.${iface}.key='Aa666666'
                uci set wireless.${iface}.ieee80211w='1'
                uci set wireless.${iface}.network='lan'
                uci set wireless.${iface}.mode='ap'
            done
            
            uci commit wireless
        fi
        
        /etc/init.d/wifi-auto-patch disable
        rm -f /etc/init.d/wifi-auto-patch
    ) &
}
EOF_WIFI
