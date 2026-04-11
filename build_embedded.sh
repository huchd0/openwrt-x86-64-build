#!/bin/bash
set -e
set -o pipefail

# --- 1. 语义纠错字典 (与查询引擎同步) ---
BRAND_DICT="京东云|jd|无线宝(jdcloud) 小米|mi(xiaomi) 红米(redmi) 华硕|asus(asus) 普联|tp(tplink)"
MODEL_DICT="一代|1代|坐享其成|sp01b(re-sp-01b) 鲁班|2代(re-cp-02) 亚瑟|ax1800pro(re-cp-03) 雅典娜(ax6600) 百里(ax6000) 3000t(ax3000t)"

translate() {
    local input="$1"
    local dict="$2"
    for item in $dict; do
        local aliases="${item%(*}"
        local target="${item#*(}"; target="${target%)}"
        if echo "$input" | grep -iqE "$aliases"; then
            echo "$target"
            return
        fi
    done
    echo "$input"
}

# 执行翻译转换
BRAND=$(translate "$BRAND_INPUT" "$BRAND_DICT")
MODEL=$(translate "$MODEL_INPUT" "$MODEL_DICT")

# --- 2. 架构内核精准适配 ---
case "$TARGET_ARCH" in
    *"x86-64"*)             CORE="amd64-compatible" ;;
    *"armv8"*|*"aarch64"*)  CORE="arm64" ;;
    *"mediatek-filogic"*)   CORE="arm64" ;;
    *"ramips"*|*"ath79"*)   CORE="mipsle-softfloat" ;;
    *)                      CORE="arm64" ;; 
esac
echo ">>> 🌍 架构识别: $TARGET_ARCH | 内核适配: $CORE"

# --- 3. 目录初始化 ---
mkdir -p files/root files/etc/uci-defaults files/etc/openclash/core

# --- 4. 插件与内核获取 (带 API 熔断保护) ---
echo ">>> 📥 获取 OpenClash..."
OC_URL=$(curl -sL https://api.github.com/repos/vernesong/OpenClash/releases/latest | jq -r '.assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n 1)

if [[ "$OC_URL" != http* ]]; then
    echo "❌ 致命错误: GitHub API 限流，无法获取插件。为防刷砖，构建中止。"
    exit 1
fi
wget -qO files/root/luci-app-openclash.apk "$OC_URL"

# 小内存架构防爆策略：ramips(一代/二代) 不内置内核，防止分区溢出
if [[ "$TARGET_ARCH" == *"ramips"* ]]; then
    echo "⚠️ 预警：小容量架构，跳过内核注入以防变砖。"
else
    echo ">>> 📥 注入 Meta 内核..."
    wget -qO- "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-${CORE}.tar.gz" | tar -zxf - -C files/etc/openclash/core/
    mv files/etc/openclash/core/clash files/etc/openclash/core/clash_meta 2>/dev/null || true
    chmod +x files/etc/openclash/core/clash_meta 2>/dev/null || true
fi

# --- 5. 静默配置脚本 ---
cat << EOF > files/etc/uci-defaults/99-custom-setup
#!/bin/sh
uci set network.lan.ipaddr='$MANAGEMENT_IP'
uci set system.@system[0].hostname='ImmortalWrt'
uci set system.@system[0].timezone='CST-8'
uci commit system
sed -i 's/downloads.openwrt.org/mirrors.ustc.edu.cn\/openwrt/g' /etc/apk/repositories.d/*.list 2>/dev/null || true
apk add -q --allow-untrusted /root/*.apk 2>/dev/null || true
rm -f /root/*.apk /etc/uci-defaults/99-custom-setup
exit 0
EOF
chmod +x files/etc/uci-defaults/99-custom-setup

# --- 6. 软件包精简策略 ---
PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"
if [[ "$TARGET_ARCH" == *"ramips"* ]]; then
    # ramips 必须拔除不必要的驱动以节省 Flash
    PKGS="$PKGS -ppp -ppp-mod-pppoe -kmod-usb-core -kmod-usb3"
fi

# --- 7. 【唯一性锁死】防刷砖核心校验 ---
echo ">>> 🛠️ 安全 Profile 校验..."
ALL_PROFILES=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)

# 使用翻译后的 MODEL 进行匹配
MATCH_LIST=$(echo "$ALL_PROFILES" | grep -iE "$BRAND" | grep -iE "$MODEL" || echo "$ALL_PROFILES" | grep -iE "$MODEL" || true)
MATCH_COUNT=$(echo "$MATCH_LIST" | grep -v '^$' | wc -l || echo 0)

if [ "$MATCH_COUNT" -eq 1 ]; then
    FINAL_PROFILE=$(echo "$MATCH_LIST" | tr -d '[:space:]')
    echo "✅ 校验通过：锁定设备 $FINAL_PROFILE"
else
    echo "❌ 严重错误：匹配到 $MATCH_COUNT 个结果，无法唯一锁定。"
    echo "建议查看查询引擎确认代号。匹配列表如下："
    echo "$MATCH_LIST"
    exit 1
fi

# --- 8. 执行打包 ---
make image PROFILE="$FINAL_PROFILE" PACKAGES="$PKGS" FILES="files"
