#!/bin/bash
set -e
set -o pipefail

# --- 1. 架构与内核精准自适应 ---
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *"mips"*)               CORE="mips-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac
echo ">>> 🌍 架构识别: $TARGET_ARCH | 内核适配: $CORE"

# --- 2. 安全清理目录 ---
[ -d files ] && find files -mindepth 1 -delete 2>/dev/null || true
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# --- 3. 插件下载 ---
echo ">>> 📥 正在获取 OpenClash APK..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)

if [[ "$OC_URL" != http* ]]; then
    echo "❌ 致命错误: 下载链接异常，构建强制中止。"
    exit 1
fi
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

# --- 4. 豪华版与精简版的命运分水岭 ---
if [ "$BUILD_MODE" == "Lite" ]; then
    echo "⚠️ 用户指令 [Lite 精简模式]：跳过内核注入，防止小 Flash 设备变砖。"
else
    echo ">>> 💎 用户指令 [Deluxe 豪华模式]：全功率全开！正在注入 Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# --- 5. 编写静默初始化脚本 ---
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# --- 6. 豪华装备库 ---
# 基础必备包
PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"

if [ "$BUILD_MODE" == "Lite" ]; then
    # 乞丐版：拔掉所有非必要外设驱动
    PKGS="$PKGS -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3"
else
    # 豪华版：装上 Argon 高级主题，并保留所有拨号和 USB 驱动
    PKGS="$PKGS luci-theme-argon luci-app-argon-config luci-app-statistics luci-i18n-statistics-zh-cn bash curl"
fi

# --- 7. 品牌+型号双重锁死防串线逻辑 ---
echo ">>> 🛠️ 执行最高级别安全 Profile 校验..."
ALL_PROFILES=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)

if echo "$ALL_PROFILES" | grep -qx "$DEVICE_PROFILE"; then
    echo "✅ 精确匹配命中: $DEVICE_PROFILE"
else
    echo "⚠️ 未命中精确 ID，启动【品牌+型号】模糊安全过滤..."
    if [ -n "$BRAND" ]; then
        MATCH_LIST=$(echo "$ALL_PROFILES" | grep -i "$BRAND" | grep -i "$DEVICE_PROFILE" || true)
    else
        MATCH_LIST=$(echo "$ALL_PROFILES" | grep -i "$DEVICE_PROFILE" || true)
    fi
    
    MATCH_COUNT=$(echo "$MATCH_LIST" | grep -v '^$' | wc -l || echo 0)

    if [ "$MATCH_COUNT" -eq 1 ]; then
        DEVICE_PROFILE=$(echo "$MATCH_LIST" | tr -d '[:space:]')
        echo "✅ 安全替换：唯一命中目标为 $DEVICE_PROFILE"
    elif [ "$MATCH_COUNT" -gt 1 ]; then
        echo "❌ 危险动作中止：发现 $MATCH_COUNT 个可能的目标！请从以下列表中挑选一个精确的填写："
        echo "$MATCH_LIST"
        exit 1
    else
        echo "❌ 匹配失败：未找到设备。"
        exit 1
    fi
fi

# --- 8. 执行最终构建 ---
echo ">>> 🚀 [${BUILD_MODE}] 模式启动，为您打包豪华固件..."
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
