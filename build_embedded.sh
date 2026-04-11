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
OC_URL=$(curl -sL https://api.github.com/repos/vernesong/OpenClash/releases/latest | grep "browser_download_url" | grep ".apk" | head -n 1 | cut -d '"' -f 4)

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

# --- 6. 装备库 ---
PKGS="-dnsmasq dnsmasq-full luci-app-openclash luci-app-ttyd luci-i18n-ttyd-zh-cn"

if [ "$BUILD_MODE" == "Lite" ]; then
    PKGS="$PKGS -kmod-usb-core -kmod-usb3"
else
    PKGS="$PKGS luci-theme-argon luci-app-argon-config luci-app-statistics luci-i18n-statistics-zh-cn bash curl"
fi

# --- 7. 智能 Profile 校验 (略，保持你原有的逻辑) ---
echo ">>> 🛠️ 执行 Profile 校验..."
ALL_PROFILES=$(make info | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1)
# ... 这里省略你之前的详细翻译逻辑，假设最终得到正确的 DEVICE_PROFILE ...

# --- 8. 执行最终构建 ---
echo ">>> 🚀 [${BUILD_MODE}] 模式启动，正在为您打包固件..."
make image PROFILE="$DEVICE_PROFILE" PACKAGES="$PKGS" FILES="files"

# --- 9. 【核心新增】重命名固件，注入架构名 ---
echo ">>> 🏷️ 正在为固件注入架构标识: $TARGET_ARCH"
# 进入输出目录
cd bin/targets/*/* for img in *.{bin,img.gz}; do
    if [ -f "$img" ]; then
        # 获取不带后缀的文件名和后缀
        base="${img%.*}"
        ext="${img##*.}"
        # 特殊处理 .img.gz 的双后缀
        if [[ "$img" == *.img.gz ]]; then
            base="${img%.img.gz}"
            ext="img.gz"
        fi
        
        # 新文件名：原名-架构名.后缀
        new_name="${base}-${TARGET_ARCH}.${ext}"
        
        echo "✅ 重命名: $img -> $new_name"
        mv "$img" "$new_name"
    fi
done
