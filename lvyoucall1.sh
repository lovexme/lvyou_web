#!/usr/bin/env bash
set -euo pipefail

# 配置项：根据你的实际安装路径修改
ROOT="/opt/board-manager"
MAIN="$ROOT/app/main.py"
APPVUE="$ROOT/frontend/src/App.vue"
FRONT="$ROOT/frontend"
BACKUP_DIR="$ROOT/backups"

# 创建备份目录
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# ===================== 工具函数 =====================
# 安全替换文件内容（保留备份）
safe_replace() {
    local file=$1
    local backup_suffix=$2
    cp -a "$file" "$BACKUP_DIR/$(basename $file).$backup_suffix.$TIMESTAMP"
    cp -a "$file" "$file.bak.$TIMESTAMP"  # 原目录保留一份备份
}

# 检查文件是否存在
check_file() {
    local file=$1
    local desc=$2
    if [[ ! -f "$file" ]]; then
        echo "❌ 找不到 $desc：$file"
        exit 1
    fi
}

# ===================== 1. 后端补丁（main.py）=====================
echo "=== [1/3] 后端补丁：operator 使用 SIM*_STA（保留 460xx）==="
check_file "$MAIN" "main.py"
safe_replace "$MAIN" "main.py"

# 1.1 确保导入 re
if ! grep -q "^import re" "$MAIN" && ! grep -q "^from re import" "$MAIN"; then
    # 找到最后一个 import/from 行，插入 import re
    awk '
        /^(import|from)\s+/ {last_import=NR}
        {lines[NR]=$0}
        END {
            for (i=1; i<=last_import; i++) print lines[i]
            print "import re"
            for (i=last_import+1; i<=NR; i++) print lines[i]
        }
    ' "$MAIN" > "$MAIN.tmp" && mv "$MAIN.tmp" "$MAIN"
fi

# 1.2 注入/覆盖 _bm_op_from_sta 函数
if grep -q "def _bm_op_from_sta" "$MAIN"; then
    # 覆盖现有函数
    awk -v func="def _bm_op_from_sta(sta: str) -> str:
    \"\"\"从 SIM*_STA 取运营商显示，保留完整 '移动(46001)' 形式\"\"\"
    return (sta or \"\").strip()" '
    /def _bm_op_from_sta/ {
        print func
        # 跳过原函数内容，直到遇到下一个 def 或文件结束
        in_func=1
        next
    }
    in_func && /^def/ {in_func=0; print}
    !in_func {print}
    ' "$MAIN" > "$MAIN.tmp" && mv "$MAIN.tmp" "$MAIN"
else
    # 插入新函数到 import 后
    awk '
        /^(import|from)\s+/ {last_import=NR}
        {lines[NR]=$0}
        END {
            for (i=1; i<=last_import; i++) print lines[i]
            print ""
            print "def _bm_op_from_sta(sta: str) -> str:"
            print "    \"\"\"从 SIM*_STA 取运营商显示，保留完整 '移动(46001)' 形式\"\"\""
            print "    return (sta or \"\").strip()"
            print ""
            for (i=last_import+1; i<=NR; i++) print lines[i]
        }
    ' "$MAIN" > "$MAIN.tmp" && mv "$MAIN.tmp" "$MAIN"
fi

# 1.3 追加 SIM1_STA/SIM2_STA 到请求列表
if grep -q '"SIM2_OP"' "$MAIN" && ! grep -q '"SIM1_STA"' "$MAIN"; then
    sed -i 's/"SIM2_OP"]/"SIM2_OP","SIM1_STA","SIM2_STA"]/g' "$MAIN"
    sed -i "s/'SIM2_OP']/'SIM2_OP','SIM1_STA','SIM2_STA']/g" "$MAIN"
fi

# 1.4 替换 sim1op/sim2op 逻辑（兼容单/双引号）
sed -i 's/sim1op = (data.get("SIM1_OP") or "").strip()/sim1op = ((data.get("SIM1_OP") or "").strip() or _bm_op_from_sta(data.get("SIM1_STA") or ""))/g' "$MAIN"
sed -i "s/sim1op = (data.get('SIM1_OP') or '').strip()/sim1op = ((data.get('SIM1_OP') or '').strip() or _bm_op_from_sta(data.get('SIM1_STA') or ''))/g" "$MAIN"
sed -i 's/sim2op = (data.get("SIM2_OP") or "").strip()/sim2op = ((data.get("SIM2_OP") or "").strip() or _bm_op_from_sta(data.get("SIM2_STA") or ""))/g' "$MAIN"
sed -i "s/sim2op = (data.get('SIM2_OP') or '').strip()/sim2op = ((data.get('SIM2_OP') or '').strip() or _bm_op_from_sta(data.get('SIM2_STA') or ''))/g" "$MAIN"

# 重启后端服务
systemctl daemon-reload 2>/dev/null || true
systemctl restart board-manager-v4.service 2>/dev/null || true
systemctl restart board-manager-v6.service 2>/dev/null || true

# ===================== 2. 前端补丁（App.vue）=====================
echo -e "\n=== [2/3] 前端补丁：SIM 两行（上小下大，紧凑）==="
check_file "$APPVUE" "App.vue"
safe_replace "$APPVUE" "App.vue"

# 2.1 替换旧的 SIM 展示块
OLD_SIM_BLOCK='<div v-if="d.sims?.sim1?.number || d.sims?.sim2?.number" class="device-sims">
  <span v-if="d.sims.sim1.number" class="sim-badge">SIM1: {{ d.sims.sim1.number }}</span>
  <span v-if="d.sims.sim2.number" class="sim-badge">SIM2: {{ d.sims.sim2.number }}</span>
</div>'

NEW_SIM_BLOCK='<div v-if="d.sims?.sim1?.number || d.sims?.sim2?.number || d.sims?.sim1?.operator || d.sims?.sim2?.operator" class="device-sims">
  <span v-if="d.sims?.sim1?.number || d.sims?.sim1?.operator" class="sim-badge bm-sim">
    <span class="sim-title">SIM1: {{ d.sims?.sim1?.operator || '未知运营商' }}</span>
    <span class="sim-number mono">{{ d.sims?.sim1?.number || '-' }}</span>
  </span>
  <span v-if="d.sims?.sim2?.number || d.sims?.sim2?.operator" class="sim-badge bm-sim">
    <span class="sim-title">SIM2: {{ d.sims?.sim2?.operator || '未知运营商' }}</span>
    <span class="sim-number mono">{{ d.sims?.sim2?.number || '-' }}</span>
  </span>
</div>'

# 匹配旧块（忽略空格/换行）
if grep -q '<div v-if="d\.sims\?\.\s*sim1\?\.\s*number\s*\|\|\s*d\.sims\?\.\s*sim2\?\.\s*number"\s*class="device-sims">' "$APPVUE"; then
    # 替换旧块为新块
    awk -v new="$NEW_SIM_BLOCK" '
        /<div v-if="d\.sims\?\.\s*sim1\?\.\s*number\s*\|\|\s*d\.sims\?\.\s*sim2\?\.\s*number"\s+class="device-sims">/ {
            print new
            # 跳过旧块内容
            in_old=1
            next
        }
        in_old && /<\/div>/ {in_old=0; next}
        !in_old {print}
    ' "$APPVUE" > "$APPVUE.tmp" && mv "$APPVUE.tmp" "$APPVUE"
else
    # 检查是否已是新结构
    if ! grep -q 'class="sim-badge bm-sim"' "$APPVUE"; then
        echo "❌ 没找到旧的 device-sims 结构，App.vue 可能已更新"
        exit 1
    fi
fi

# 2.2 清理旧样式
sed -i '/\/\* ===== BM_SIM_REINSTALL_STYLE ===== \*\//,/\/style>/d' "$APPVUE"

# 2.3 注入新 CSS
CSS_BLOCK='/* ===== BM_SIM_REINSTALL_STYLE ===== */
.device-sims{ display:flex; gap:6px; flex-wrap:wrap; align-items:flex-start; }
.sim-badge.bm-sim{
  display:inline-flex;
  flex-direction:column;
  align-items:flex-start;
  gap:2px;
  padding:4px 8px;
  border:1px solid rgba(255,255,255,.12);
  border-radius:8px;
  background:rgba(255,255,255,.04);
}
.sim-badge.bm-sim .sim-title{
  font-size:10px;
  font-weight:600;
  opacity:.75;
  white-space:nowrap;   /* 移动(46001) 不拆行 */
}
.sim-badge.bm-sim .sim-number{
  font-size:13px;
  font-weight:800;
  opacity:.95;
}'

if grep -q "</style>" "$APPVUE"; then
    sed -i "s|</style>|$CSS_BLOCK\n</style>|g" "$APPVUE"
else
    echo -e "\n<style>\n$CSS_BLOCK\n</style>\n" >> "$APPVUE"
fi

# ===================== 3. 构建前端 + 重启服务 =====================
echo -e "\n=== [3/3] 构建前端 + 重启服务 ==="
cd "$FRONT"

# 安装依赖
if [[ ! -d node_modules ]]; then
    echo "安装前端依赖..."
    npm install
fi

# 构建前端
echo "构建前端静态资源..."
npm run build >/dev/null 2>&1 || { echo "❌ 前端构建失败"; exit 1; }

# 重启服务
systemctl restart nginx 2>/dev/null || true
systemctl restart board-manager-v4.service 2>/dev/null || true
systemctl restart board-manager-v6.service 2>/dev/null || true

# ===================== 完成提示 =====================
echo -e "\n✅ 补丁应用完成！"
echo "👉 操作步骤："
echo "  1. 网页点击「重新扫描/刷新状态」（拉取 SIM*_STA 数据）"
echo "  2. 浏览器强制刷新（Ctrl+F5）清除缓存"
echo "👉 备份文件位置：$BACKUP_DIR/"
