#!/bin/bash

echo ">>> 目标环境版本: ${VERSION}"
echo -e "=======================================================\n"

# ==========================================
# 📝 1. 净化与防呆逻辑
# ==========================================
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

# 全流程归一化：将输入强制转为小写，实现不分大小写匹配
RAW_ARCH=$(echo "$INPUT_ARCH" | tr '[:upper:]' '[:lower:]' | xargs)
RAW_BRAND=$(echo "$INPUT_BRAND" | tr '[:upper:]' '[:lower:]' | xargs)
RAW_MODEL=$(echo "$INPUT_MODEL" | tr '[:upper:]' '[:lower:]' | xargs)

if [ -z "$RAW_ARCH" ] && [ -z "$RAW_BRAND" ] && [ -z "$RAW_MODEL" ]; then
   echo "❌ 触发防呆拦截：架构、品牌、型号不能全部为空！请至少填写一项线索。"
   exit 1
fi

# ==========================================
# 📝 2. 双字典配置 (已修正京东云底层合并关系)
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
友讯|dlink             (dlink)
华三|h3c               (h3c)
锐捷|ruijie            (ruijie)
京东云|jd|无线宝       (jdcloud)
斐讯|phicomm           (phicomm)
新路由|newifi|dteam    (newifi|d-team)
极路由|hiwifi          (hiwifi)
奇虎|360               (qihoo)
移动|中国移动|cmcc     (cmcc)
捷稀|jcg               (jcg)
广和通|glinet|gl       (glinet)
友善|nanopi|friendlyarm (friendlyarm)
迅雷|网心云|赚钱宝     (xunlei|onething|thunder)
"

MODEL_DICT="
一代|1代|坐享其成|sp01b (re-sp-01b)
鲁班|2代|二代|cp02       (re-cp-02)
亚瑟|ax1800pro|cp03     (re-cp-03)
雅典娜|ax6600           (ax6600)
百里                    (ax6000)
k2|k2经典               (k2)
k2p|k2p神机             (k2p)
k3|k3路由器             (k3)
k3c                     (k3c)
cr6606|cr6608|cr6609    (cr660x)
wr30u|联通wr30u         (wr30u)
ax3000t                 (ax3000t)
ax3600                  (ax3600)
ax9000                  (ax9000)
新路由1|y1|mini         (y1)
新路由2|d1              (d1)
新路由3|d2|newifi3      (d2)
r2s                     (nanopi-r2s)
r4s                     (nanopi-r4s)
r5s                     (nanopi-r5s)
r5c                     (nanopi-r5c)
r6s                     (nanopi-r6s)
t7|360t7                (t7)
q20|捷稀q20             (q20)
rax3000m|移动rax3000m   (rax3000m)
e8820s|中兴e8820s       (e8820s)
"

# ==========================================
# ⚙️ 3. 核心翻译引擎 (增强型：不分大小写)
# ==========================================
translate() {
  local input="$1"
  local dict="$2"
  local output=""
  
  [ -z "$input" ] && return

  for word in $input; do
    local matched=0
    while IFS= read -r line; do
      [[ ! "$line" =~ [^[:space:]] ]] && continue
      # 提取括号内的目标代号
      local target=$(echo "${line##*\(}" | tr -d ')')
      # 提取别名部分并转为小写
      local aliases_str=$(echo "${line%\(*}" | tr '[:upper:]' '[:lower:]')
      
      IFS='|' read -ra ALIAS_ARRAY <<< "$aliases_str"
      for raw_alias in "${ALIAS_ARRAY[@]}"; do
        local clean_alias=$(echo "$raw_alias" | xargs)
        if [[ "$word" == "$clean_alias" ]]; then
          output="$output $target"
          matched=1
          break 2
        fi
      done
    done <<< "$dict"
    if [ $matched -eq 0 ]; then output="$output $word"; fi
  done
  echo $(echo "$output" | xargs)
}

PARSED_BRAND=$(translate "$RAW_BRAND" "$BRAND_DICT")
PARSED_MODEL=$(translate "$RAW_MODEL" "$MODEL_DICT")

# 转换为正则表达式格式
QUERY_B="${PARSED_BRAND// /.*}"
QUERY_M="${PARSED_MODEL// /.*}"

echo "🔍 引擎启动状态："
[ -n "$RAW_ARCH" ] && echo "    - 扫描模式: [本地极速穿透 - 指定架构 $RAW_ARCH]" || echo "    - 扫描模式: [全网多线程爬虫 - 全网盲搜]"
echo "    - 品牌锁定: [${RAW_BRAND:-未指定}] -> 匹配关键词: [$QUERY_B]"
echo "    - 型号锁定: [${RAW_MODEL:-未指定}] -> 匹配关键词: [$QUERY_M]"
echo -e "-------------------------------------------------------\n"

# ==========================================
# 🚀 4. 底层提取
# ==========================================
ALL_LIST=""

if [ -n "$RAW_ARCH" ]; then
    echo ">>> 检测到已填写架构，切换至 Docker 本地环境提取..."
    docker pull -q immortalwrt/imagebuilder:${RAW_ARCH}-openwrt-${VERSION} >/dev/null 2>&1 || true
    ALL_LIST=$(docker run --rm immortalwrt/imagebuilder:${RAW_ARCH}-openwrt-${VERSION} make info 2>/dev/null | grep "^[a-zA-Z0-9_-]*:" | cut -d ':' -f 1 | awk -v arch="$RAW_ARCH" '{print arch " : " $1}')
    
    if [ -z "$ALL_LIST" ]; then
        echo "❌ 拉取失败：该架构可能拼写错误或不存在。"
        exit 1
    fi
else
    echo ">>> 正在剥离前端外壳，深入官方主节点抓取架构池..."
    
    # 增加对 qualcommax/ipq807x 等新路径的兼容性
    TARGETS=$(curl -sL --max-time 10 "https://downloads.immortalwrt.org/releases/${VERSION}/targets/" 2>/dev/null | grep -oE '<a href="[a-zA-Z0-9_-]+/"' | cut -d'"' -f2 | sed 's/\///g')
    
    if [ -z "$TARGETS" ]; then
        echo "❌ 第一级目录抓取失败，请检查网络。"
        exit 1
    fi
    
    cat << 'EOF' > /tmp/get_sub.sh
#!/bin/bash
t="$1"
ver="$2"
curl -sL --max-time 10 "https://downloads.immortalwrt.org/releases/${ver}/targets/${t}/" 2>/dev/null | grep -oE '<a href="[a-zA-Z0-9_-]+/"' | cut -d'"' -f2 | sed 's/\///g' | sed "s/^/$t-/"
EOF
    chmod +x /tmp/get_sub.sh
    
    ARCH_LIST=$(printf "%s\n" "$TARGETS" | xargs -I {} -P 10 /tmp/get_sub.sh "{}" "$VERSION")
    
    echo ">>> 成功突破迷雾，锁定 $(echo "$ARCH_LIST" | wc -w) 个独立子架构！"
    echo ">>> 🚦 正在启动【高并发下载通道】提取海量设备特征..."
    
    mkdir -p /tmp/profiles
    
    cat << 'EOF' > /tmp/fetch_json.sh
#!/bin/bash
arch="$1"
ver="$2"
subpath=$(echo "$arch" | tr "-" "/")
URL="https://downloads.immortalwrt.org/releases/${ver}/targets/${subpath}/profiles.json"
FALLBACK="https://mirrors.ustc.edu.cn/immortalwrt/releases/${ver}/targets/${subpath}/profiles.json"

if ! curl -sL -f --connect-timeout 5 --max-time 30 -o "/tmp/profiles/${arch}_raw.json" "$URL" 2>/dev/null; then
    curl -sL -f --connect-timeout 5 --max-time 30 -o "/tmp/profiles/${arch}_raw.json" "$FALLBACK" 2>/dev/null || true
fi

if [ -s "/tmp/profiles/${arch}_raw.json" ] && jq -e . "/tmp/profiles/${arch}_raw.json" >/dev/null 2>&1; then
    jq -r '.profiles | keys[]' "/tmp/profiles/${arch}_raw.json" | awk -v a="$arch" '{print a " : " $1}' > "/tmp/profiles/${arch}.txt"
fi
EOF
    chmod +x /tmp/fetch_json.sh
    
    printf "%s\n" "$ARCH_LIST" | xargs -I {} -P 15 /tmp/fetch_json.sh "{}" "$VERSION"
    
    cat /tmp/profiles/*.txt > /tmp/all_list.txt 2>/dev/null || true
    ALL_LIST=$(cat /tmp/all_list.txt 2>/dev/null || true)
    
    if [ -z "$ALL_LIST" ]; then
        echo "❌ 致命错误：数据库抓取归零。"
        exit 1
    fi
    
    echo ">>> ✅ 全网数据矩阵重组完毕！总计挖掘到 $(echo "$ALL_LIST" | wc -l) 款专属设备。"
fi

# ==========================================
# 🎯 5. 增强型全语义模糊过滤 (通用方案)
# ==========================================
# 提取纯数字备用关键词 (如 AX6000 -> 6000)
PURE_NUM=$(echo "$RAW_MODEL" | tr -cd '0-9')

# 执行多重过滤
# 逻辑：(匹配品牌 AND 匹配型号) OR (匹配纯数字关键词)
RESULT=$(echo "$ALL_LIST" | grep -iE "$QUERY_B" | grep -iE "$QUERY_M" || true)

# 如果没搜到，自动启动“数字降维盲搜”
if [ -z "$RESULT" ] && [ -n "$PURE_NUM" ]; then
  echo "⚠️ 深度匹配未命中，启动 [数字降维盲搜] 模式..."
  RESULT=$(echo "$ALL_LIST" | grep -iE "$PURE_NUM" | grep -iE "$RAW_BRAND" || echo "$ALL_LIST" | grep -iE "$PURE_NUM" || true)
fi

# 排除重复并排序
RESULT=$(echo "$RESULT" | sort -u)
  
  # 极致对齐逻辑：18字符左对齐，冒号后无空格
  FORMATTED_RESULT=$(echo "$RESULT" | awk -F ' : ' '{printf "%-18s:%s\n", $1, $2}' | sort -u)
  
  echo "$FORMATTED_RESULT"
  echo -e "======================================================="
  
  # GitHub 首页摘要
  echo "### ✅ 匹配成功！精准锁定以下组合：" >> $GITHUB_STEP_SUMMARY
  echo '```text' >> $GITHUB_STEP_SUMMARY
  echo "$FORMATTED_RESULT" >> $GITHUB_STEP_SUMMARY
  echo '```' >> $GITHUB_STEP_SUMMARY
fi
