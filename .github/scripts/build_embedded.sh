#!/bin/bash
set -e
set -o pipefail

# ==========================================
# 📝 1. 品牌容错字典
# ==========================================
BRAND_DICT="
小米|mi                (xiaomi)
红米                  (redmi)
华硕|败家之眼|asus     (asus)
普联|tp|tplink         (tplink|tp-link)
网件|netgear           (netgear)
领势|linksys           (linksys)
腾达|tenda             (tenda)
水星|mercury           (mercury)
中兴|zte               (zte)
华为|huawei            (huawei)
华三|h3c               (h3c)
锐捷|ruijie            (ruijie)
京东云|jd|无线宝       (jdcloud)
斐讯|phicomm           (phicomm)
新路由|newifi|dteam    (newifi|d-team)
极路由|hiwifi          (hiwifi)
奇虎|360               (qihoo)
移动|中国移动|cmcc     (cmcc)
友善|nanopi|friendlyarm(friendlyarm)
"

RAW_BRAND=$(echo "$BRAND_INPUT" | xargs | tr '[:upper:]' '[:lower:]')
EXACT_PROFILE=$(echo "$DEVICE_PROFILE" | xargs)

translate_brand() {
  local input="$1"; local dict="$2"
  [ -z "$input" ] && return
  for word in $input; do
    local matched=0
    while IFS= read -r line; do
      [[ ! "$line" =~ [^[:space:]] ]] && continue
      local target=$(echo "${line##*\(}" | tr -d ')')
      local aliases_str=$(echo "${line%\(*}" | tr '[:upper:]' '[:lower:]')
      IFS='|' read -ra ALIAS_ARRAY <<< "$aliases_str"
      for raw_alias in "${ALIAS_ARRAY[@]}"; do
        local clean_alias=$(echo "$raw_alias" | xargs)
        if [[ "$word" == "$clean_alias" ]]; then echo "$target"; return; fi
      done
    done <<< "$dict"
    if [ $matched -eq 0 ]; then echo "$word"; fi
  done
}
BRAND_KEYWORD=$(translate_brand "$RAW_BRAND" "$BRAND_DICT" | tr ' ' '|')

# ==========================================
# ⚙️ 2. 架构内核适配
# ==========================================
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac

# ==========================================
# 📁 3. 目录初始化与内核获取
# ==========================================
mkdir -p files/etc/uci-defaults files/etc/openclash/core

if [ "$BUILD_MODE" == "Deluxe" ]; then
    echo ">>> 💎 [豪华版] 正在注入 Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
else
    echo "⚠️ [${BUILD_MODE}] 模式触发，跳过内核注入以防超容变砖。"
fi

# ==========================================
# 📦 4. 模式化分流：软件包策略与全自动脚本
# ==========================================
PKGS="-dnsmasq dnsmasq-full luci-app-ttyd luci-i18n-ttyd-zh-cn"

if [ "$BUILD_MODE" == "Lite" ]; then
    echo ">>> 🗑️ [丐版模式] 强行剔除所有非核心组件..."
    PKGS="$PKGS -luci-app-openclash -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3 kmod-usb2"

elif [ "$BUILD_MODE" == "Extroot" ]; then
    echo ">>> 💾 [扩容模式] 注入 USB 驱动、挂载工具与全自动扩容脚本..."
    # 核心驱动包
    PKGS="$PKGS block-mount e2fsprogs kmod-fs-ext4 kmod-usb-core kmod-usb3 kmod-usb-storage fdisk"
    PKGS="$PKGS -luci-app-openclash -ppp -ppp-mod-pppoe"
    
    # 💥 植入全自动无感扩容脚本 (会在首次开机时自动执行)
    cat << 'EOF' > files/etc/uci-defaults/90-auto-extroot
#!/bin/sh
# 检查是否已经挂载了 overlay，防止无限循环重启
if uci -q get fstab.@mount[0].target | grep -q "/overlay"; then
    exit 0
fi

# 给予系统 15 秒时间识别插入的 U 盘
sleep 15

# 寻找第一个 USB 存储设备 (通常是 /dev/sda1)
DEVICE=$(block info | grep -oE "/dev/sd[a-z][0-9]+" | head -n 1)

if [ -n "$DEVICE" ]; then
    logger -t Extroot "检测到 U 盘 $DEVICE，开始自动化全盘扩容..."
    
    # 强制将 U 盘格式化为 ext4
    mkfs.ext4 -F -L "extroot" "$DEVICE"
    
    # 临时挂载并迁移原系统数据
    mkdir -p /mnt/extroot
    mount "$DEVICE" /mnt/extroot
    tar -C /overlay -cvf - . | tar -C /mnt/extroot -xf -
    umount /mnt/extroot
    
    # 自动生成挂载配置
    block detect > /etc/config/fstab
    uci set fstab.@mount[0].target='/overlay'
    uci set fstab.@mount[0].enabled='1'
    uci commit fstab
    
    logger -t Extroot "扩容配置完成，正在重启以挂载外部存储空间..."
    sync
    reboot
else
    logger -t Extroot "未检测到 U 盘。跳过扩容。若需扩容请插上 U 盘后重启路由器。"
    # 返回 1 让此脚本保留在系统中，直到插入 U 盘并成功执行一次
    exit 1
fi
EOF
    chmod +x files/etc/uci-defaults/90-auto-extroot

else
    echo ">>> 🔌 [豪华模式] 注入全套组件 (OpenClash + USB + 主题)..."
    PKGS="$PKGS luci-app-openclash luci-theme-argon block-mount e2fsprogs kmod-fs-ext4 kmod-usb-core kmod-usb3 kmod-usb-storage"
fi

# ==========================================
# 🔧 5. 系统基础配置
# ==========================================
cat << EOF > files/etc/uci-defaults/99-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci commit network
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
rm -f /etc/uci-defaults/99-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-setup

# ==========================================
# 🛡️ 6. 严苛防爆：全字匹配与双保险
# ==========================================
echo ">>> 🛠️ 安全校验：严格 Profile 匹配与品牌双保险..."
ALL_PROFILES=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)

FINAL_PROFILE=$(echo "$ALL_PROFILES" | grep -ix "$EXACT_PROFILE" || true)
MATCH_COUNT=$(echo "$FINAL_PROFILE" | grep -v '^$' | wc -l || echo 0)

if [ "$MATCH_COUNT" -eq 1 ]; then
    FINAL_PROFILE=$(echo "$FINAL_PROFILE" | tr -d '[:space:]')
    echo "✅ 第一重校验通过：锁定设备代号 -> $FINAL_PROFILE"
elif [ "$MATCH_COUNT" -gt 1 ]; then
    echo "❌ 严重错误：数据库代号异常，安全锁死。"; exit 1
else
    echo "❌ 致命错误：当前架构下不存在该设备代号 [$EXACT_PROFILE]！"; exit 1
fi

if [ -n "$BRAND_KEYWORD" ]; then
    if echo "$FINAL_PROFILE" | grep -iqE "$BRAND_KEYWORD"; then
        echo "✅ 第二重校验通过：品牌匹配无误！"
    else
        echo "❌ 刷砖预警：输入的品牌 [$BRAND_INPUT] 与代号 [$FINAL_PROFILE] 不匹配！"; exit 1
    fi
fi

# ==========================================
# 🚀 7. 终极打包与智能超载拦截机制
# ==========================================
echo ">>> 🚀 正在以【$BUILD_MODE】模式全速打包固件..."
make image PROFILE="$FINAL_PROFILE" PACKAGES="$PKGS" FILES="files"

if ! ls bin/targets/*/*/*.{bin,img.gz} 1> /dev/null 2>&1; then
    echo "================================================================"
    echo "❌ 🚨 致命错误：固件体积超标！"
    echo "原因：在【$BUILD_MODE】模式下，固件超出了设备的物理 Flash 上限。"
    [ "$BUILD_MODE" == "Deluxe" ] && echo "💡 建议：您的设备可能只有 16MB 内存。请切换到【Extroot 扩容底包】模式重新编译，刷入后插 U 盘智能扩容。"
    [ "$BUILD_MODE" == "Extroot" ] && echo "💡 建议：连底包都超标？请切换到【Lite 丐版】，或回退至旧版本 OpenWrt (如 23.05.4)。"
    echo "================================================================"
    exit 1
fi

echo ">>> 🏷️ 正在为生成的固件注入架构标识..."
cd bin/targets/*/* || true
for img in *.{bin,img.gz}; do
    if [ -f "$img" ]; then
        base="${img%.*}"; ext="${img##*.}"
        [[ "$img" == *.img.gz ]] && base="${img%.img.gz}" && ext="img.gz"
        new_name="${base}-${TARGET_ARCH}.${ext}"
        echo "✅ 成功重命名: $new_name"
        mv "$img" "$new_name"
    fi
done
