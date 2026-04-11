#!/bin/bash
# 开启最高等级的错误检查机制
set -e
set -o pipefail

# --- 1. 架构识别与内核精准自适应 ---
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *"mips"*)               CORE="mips-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac

echo ">>> 🌍 目标架构: $TARGET_ARCH | 内核适配: $CORE"

# --- 2. 目录清理 (防挂载点报错) ---
[ -d files ] && find files -mindepth 1 -delete 2>/dev/null || true
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# --- 3. 插件下载与数据完整性校验 ---
echo ">>> 📥 获取 OpenClash APK..."
OC_URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)

# 安全锁：确保拿到的是真正的下载链接，而不是 API 报错的 JSON
if [[ "$OC_URL" != http* ]]; then
    echo "❌ 致命错误: 无法获取合法的 OpenClash APK 链接 (可能是 GitHub API 限制)。构建中止。"
    exit 1
fi
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

# --- 4. 空间预警与内核处理 (严格的架构隔离) ---
if [[ "$TARGET_ARCH" == *"ramips"* ]] || [[ "$TARGET_ARCH" == *"ath79"* ]]; then
    echo "⚠️ 安全策略启动：检测到典型小容量架构 ($TARGET_ARCH)。跳过内核注入以防止固件超限变砖。"
else
    echo ">>> 📥 注入 OpenClash Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# --- 5. 编写初始化脚本 ---
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system

sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true

apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk
rm -f /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# --- 6. 软件包组合 (精准打击) ---
# 无论什么架构，这几个都是必备核心
PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"

# 仅对乞丐版架构进行极端阉割，保留高性能 ARM 的拨号能力
if [[ "$TARGET_ARCH" == *"ramips"* ]] || [[ "$TARGET_ARCH" == *"ath79"* ]]; then
    PKGS="$PKGS -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3"
fi

# --- 7. Profile 宁缺毋滥匹配逻辑 (核心防砖护城河) ---
echo ">>> 🛠️ 安全校验 Profile: $DEVICE_PROFILE ..."

if ! make info | grep -q "^${DEVICE_PROFILE}:"; then
    echo "⚠️ 警告: 精确匹配失败，启动全量安全检索..."
    
    # 统计有多少个型号包含了输入的关键字
    MATCH_COUNT=$(make info | grep "^[a-zA-Z0-9_-]*:" | grep -i "${DEVICE_PROFILE}" | wc -l)
    
    if [ "$MATCH_COUNT" -eq 1 ]; then
        SUGGESTION=$(make info | grep "^[a-zA-Z0-9_-]*:" | grep -i "${DEVICE_PROFILE}" | cut -d ':' -f 1)
        echo "✅ 验证通过：发现唯一匹配项 $SUGGESTION，安全替换。"
        DEVICE_PROFILE="$SUGGESTION"
    elif [ "$MATCH_COUNT" -gt 1 ]; then
        echo "❌ 致命风险: 找到 $MATCH_COUNT 个包含 '${DEVICE_PROFILE}' 的设备！"
        echo "为了防止跨品牌刷砖，程序已强制中止。请从以下列表中选择精确的型号填入："
        make info | grep "^[a-zA-Z0-9_-]*:" | grep -i "${DEVICE_PROFILE}"
        exit 1
    else
        echo "❌ 致命错误: 该架构下完全找不到包含 '${DEVICE_PROFILE}' 的设备。请检查输入。"
        exit 1
    fi
fi

# --- 8. 触发构建 ---
echo ">>> 🚀 最终校验通过，开始打包..."
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"
