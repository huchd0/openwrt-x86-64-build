#!/bin/bash

# =========================================================
# 1. 定义基础软件包 (底层必需，无论如何都会安装)
# =========================================================
BASE_PACKAGES=""
BASE_PACKAGES="$BASE_PACKAGES base-files"                # 基础文件系统结构
BASE_PACKAGES="$BASE_PACKAGES block-mount"               # 磁盘挂载核心支持
BASE_PACKAGES="$BASE_PACKAGES default-settings-chn"      # 默认中国区设置与时区
BASE_PACKAGES="$BASE_PACKAGES luci-i18n-base-zh-cn"      # LuCI 后台中文语言包
BASE_PACKAGES="$BASE_PACKAGES luci-i18n-ksmbd-zh-cn"     # ksmbd 中文语言包 (配合 Argon 主题需求)

# =========================================================
# 2. 根据 GitHub Actions 传进来的变量，动态追加可选包
# =========================================================

# 🐳 Docker 组件
if [ "$INCLUDE_DOCKER" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-dockerman"    # LuCI 的 Docker 图形化管理界面
    BASE_PACKAGES="$BASE_PACKAGES docker-compose"        # Docker Compose 编排支持
fi

# 🔌 OpenClash 组件
if [ "$APP_OPENCLASH" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-openclash"    # OpenClash 核心组件
fi

# 🚀 PassWall 组件
if [ "$APP_PASSWALL" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-passwall"     # PassWall 核心组件
fi

# 🎮 UPnP 组件
if [ "$APP_UPNP" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-upnp"         # 自动端口映射服务
fi

# 🌐 DDNS 组件
if [ "$APP_DDNS" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-ddns"         # 动态域名解析基础应用
    BASE_PACKAGES="$BASE_PACKAGES luci-i18n-ddns-zh-cn"  # 动态域名解析中文包
fi

# 💻 网络唤醒
if [ "$APP_WOL" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-wol"          # 网络唤醒功能
fi

# 🗂️ AList 挂载
if [ "$APP_ALIST" = "true" ]; then
    BASE_PACKAGES="$BASE_PACKAGES luci-app-alist"        # 多存储网盘挂载应用
fi

# =========================================================
# 3. 最终传递给 ImageBuilder 执行编译
# =========================================================
echo ">>> 最终打包的软件列表: $BASE_PACKAGES"

make image PROFILE="generic" PACKAGES="$BASE_PACKAGES" FILES="files"
