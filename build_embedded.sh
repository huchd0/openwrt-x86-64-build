#!/bin/bash
set -e

# --- 1. 架构感知与内核自适应 ---
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips-mt7621"*)      CORE="mipsle-softfloat" ;;
    *"ramips-mt76x8"*)      CORE="mipsle-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac

echo ">>> 🌍 当前架构: $TARGET_ARCH | 自动适配内核: $CORE"

# --- 2. 目录清理与预备 ---
[ -d files ] && find files -mindepth 1 -delete 2>/dev/null || true
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# --- 3. 插件获取 (不依赖 jq) ---
echo ">>> 📥 获取 OpenClash APK..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

# --- 4. 智能空间管理逻辑 ---
# 只有当架构不是 ramips (通常意味着 Flash 较大) 时，才预装 Meta 内核
if [[ "$TARGET_ARCH" == *"ramips"* ]]; then
    echo "⚠️ 检测到小容量架构，跳过内核注入以确保编译成功 (请刷机后手动上传)"
else
    echo ">>> 📥 注入 OpenClash Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# --- 5. 编写全自动初始化脚本 (通用型) ---
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
# 基础配置
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

# 切换国内镜像源
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true

# 自动安装所有 files/root 下的 APK
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk
rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# --- 6. 软件包列表 (分级管理) ---
# 基础插件包 (绝大多数路由器都能带得动)
BASE_PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn bash curl"

# 额外包 (根据架构自动增减，避免驱动冲突)
if [[ "$TARGET_ARCH" == *"x86"* ]]; then
    EXTRA_PKGS="kmod-igc kmod-r8169"
elif [[ "$TARGET_ARCH" == *"mediatek"* ]] || [[ "$TARGET_ARCH" == *"rockchip"* ]]; then
    # 存储空间大的架构，增加漂亮的主题和统计图表
    EXTRA_PKGS="luci-theme-argon luci-app-statistics luci-i18n-statistics-zh-cn"
else
    # 针对 ramips 等小空间架构，强制剔除 USB 和拨号相关，腾出空间给 OpenClash
    EXTRA_PKGS="-ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3"
fi

PKGS="$BASE_PKGS $EXTRA_PKGS"

# --- 7. 智能 Profile 匹配逻辑 ---
echo ">>> 🛠️ 正在校验 Profile: $DEVICE_PROFILE ..."

# 如果精确匹配失败，则开启“模糊搜索”尝试找到该架构下最匹配的型号
if ! make info | grep -q "^${DEVICE_PROFILE}:"; then
    echo "⚠️ 警告: 精确匹配失败，正在模糊搜索包含 '${DEVICE_PROFILE}' 的型号..."
    SUGGESTION=$(make info | grep ":" | grep -i "${DEVICE_PROFILE}" | head -n 1 | cut -d ':' -f 1)
    
    if [ -n "$SUGGESTION" ]; then
        echo "✅ 自动匹配到: $SUGGESTION"
        DEVICE_PROFILE="$SUGGESTION"
    else
        echo "❌ 无法找到匹配设备。请检查界面输入的 device_profile 是否有误。"
        echo "当前架构可用 Profile 前20个:"
        make info | grep ":" | head -n 20
        exit 1
    fi
fi

# --- 8. 执行最终构建 ---
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
