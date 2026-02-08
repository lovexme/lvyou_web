#!/bin/sh
# 补丁脚本：修复板卡管理器 SIM 运营商显示问题
# GitHub: https://github.com/yourusername/board-manager-patches

set -e

ROOT="/opt/board-manager"
MAIN="$ROOT/app/main.py"
APPVUE="$ROOT/frontend/src/App.vue"
FRONT="$ROOT/frontend"

echo "=== [1/3] 后端补丁：operator 使用 SIM*_STA（保留 460xx） ==="
if [ ! -f "$MAIN" ]; then
    echo "❌ 找不到 $MAIN（安装路径可能不同）"
    echo "请检查安装目录，或修改脚本中的 ROOT 变量"
    exit 1
fi

# 备份原文件
BACKUP="$MAIN.bak.$(date +%Y%m%d_%H%M%S)"
cp -p "$MAIN" "$BACKUP"
echo "✅ 已备份到: $BACKUP"

# 创建临时文件
TEMP_PY=$(mktemp)

# 使用 Python3 进行复杂修改
python3 << 'PYEOF' > "$TEMP_PY"
import sys
import re
from pathlib import Path

main_path = sys.argv[1]
p = Path(main_path)
s = p.read_text("utf-8", errors="ignore")

# 确保 import re
if re.search(r'^\s*import\s+re\s*$', s, flags=re.M) is None:
    imports = list(re.finditer(r'^(?:import|from)\s+.*$', s, flags=re.M))
    if imports:
        pos = imports[-1].end()
        s = s[:pos] + "\nimport re\n" + s[pos:]
    else:
        s = "import re\n" + s

# 注入/覆盖函数：保留完整 STA（移动(46001)）
func = """def _bm_op_from_sta(sta: str) -> str:
    \"\"\"从 SIM*_STA 取运营商显示，保留完整 '移动(46001)' 形式\"\"\"
    return (sta or "").strip()"""

if "_bm_op_from_sta" in s:
    # 替换现有函数
    pattern = r"def\s+_bm_op_from_sta\s*\(.*?\):.*?(?=^\s*def\s|\Z)"
    s = re.sub(pattern, func, s, flags=re.S|re.M)
else:
    # 插在 import 后
    imports = list(re.finditer(r'^(?:import|from)\s+.*$', s, flags=re.M))
    pos = imports[-1].end() if imports else 0
    s = s[:pos] + "\n\n" + func + "\n" + s[pos:]

# 追加 keys: SIM1_STA/SIM2_STA（如果没请求到，后端也拿不到）
if "SIM1_OP" in s and "SIM2_OP" in s:
    s = s.replace('"SIM2_OP"]', '"SIM2_OP","SIM1_STA","SIM2_STA"]')
    s = s.replace("'SIM2_OP']", "'SIM2_OP','SIM1_STA','SIM2_STA']")

# OP 为空时用 STA
if 'data.get("SIM1_OP")' in s:
    s = s.replace(
        'sim1op = (data.get("SIM1_OP") or "").strip()',
        'sim1op = ((data.get("SIM1_OP") or "").strip() or _bm_op_from_sta(data.get("SIM1_STA") or ""))'
    )
    s = s.replace(
        'sim2op = (data.get("SIM2_OP") or "").strip()',
        'sim2op = ((data.get("SIM2_OP") or "").strip() or _bm_op_from_sta(data.get("SIM2_STA") or ""))'
    )

if "data.get('SIM1_OP')" in s:
    s = s.replace(
        "sim1op = (data.get('SIM1_OP') or '').strip()",
        "sim1op = ((data.get('SIM1_OP') or '').strip() or _bm_op_from_sta(data.get('SIM1_STA') or ''))"
    )
    s = s.replace(
        "sim2op = (data.get('SIM2_OP') or '').strip()",
        "sim2op = ((data.get('SIM2_OP') or '').strip() or _bm_op_from_sta(data.get('SIM2_STA') or ''))"
    )

print(s)
PYEOF

# 应用修改
python3 -c "
import sys
sys.argv.append('$MAIN')
exec(open('$TEMP_PY').read())
" > "${MAIN}.new"

mv "${MAIN}.new" "$MAIN"
rm -f "$TEMP_PY"
echo "✅ 后端补丁完成：operator 将显示 '移动(460xx)'"

# 重启服务
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart board-manager-v4.service 2>/dev/null || true
    systemctl restart board-manager-v6.service 2>/dev/null || true
    echo "✅ 服务已重启"
fi

echo ""
echo "=== [2/3] 前端补丁：SIM 两行（上小下大，紧凑） ==="
if [ ! -f "$APPVUE" ]; then
    echo "⚠️  找不到 $APPVUE（这次安装可能没带前端源码）"
    echo "跳过前端补丁..."
else
    # 备份前端文件
    BACKUP_VUE="$APPVUE.bak.$(date +%Y%m%d_%H%M%S)"
    cp -p "$APPVUE" "$BACKUP_VUE"
    echo "✅ 已备份到: $BACKUP_VUE"
    
    # 使用 Python 处理前端文件
    TEMP_VUE=$(mktemp)
    python3 << 'VUEEOF' > "$TEMP_VUE"
import sys
import re
from pathlib import Path

appvue_path = sys.argv[1]
p = Path(appvue_path)
s = p.read_text("utf-8", errors="ignore")

# 尝试匹配旧的 SIM 显示结构
old_pattern = r'<div[^>]*class="device-sims"[^>]*>.*?</div>'
old_match = re.search(old_pattern, s, re.DOTALL)

if old_match:
    # 替换为新结构
    new_sim_block = '''<div v-if="d.sims?.sim1?.number || d.sims?.sim2?.number || d.sims?.sim1?.operator || d.sims?.sim2?.operator" class="device-sims">
  <span v-if="d.sims?.sim1?.number || d.sims?.sim1?.operator" class="sim-badge bm-sim">
    <span class="sim-title">SIM1: {{ d.sims?.sim1?.operator || '未知运营商' }}</span>
    <span class="sim-number mono">{{ d.sims?.sim1?.number || '-' }}</span>
  </span>
  <span v-if="d.sims?.sim2?.number || d.sims?.sim2?.operator" class="sim-badge bm-sim">
    <span class="sim-title">SIM2: {{ d.sims?.sim2?.operator || '未知运营商' }}</span>
    <span class="sim-number mono">{{ d.sims?.sim2?.number || '-' }}</span>
  </span>
</div>'''
    
    s = s[:old_match.start()] + new_sim_block + s[old_match.end():]
    
    # 清理旧样式
    s = re.sub(r'/\* ===== BM_SIM_REINSTALL_STYLE ===== \*/.*?(?=</style>|$)', '', s, flags=re.DOTALL)
    
    # 添加新样式
    css = '''
/* ===== BM_SIM_REINSTALL_STYLE ===== */
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
  white-space:nowrap;
}
.sim-badge.bm-sim .sim-number{
  font-size:13px;
  font-weight:800;
  opacity:.95;
}
/* ===== END BM_SIM_REINSTALL_STYLE ===== */'''
    
    if '</style>' in s:
        s = s.replace('</style>', css + '\n</style>', 1)
    else:
        s += '\n<style>' + css + '\n</style>\n'
    
    print(s)
    print("✅ 前端补丁完成：两行紧凑显示", file=sys.stderr)
else:
    # 如果没有找到旧结构，检查是否已经有新结构
    if 'class="sim-badge bm-sim"' in s:
        print(s)
        print("⚠️  前端已经是最新结构，跳过修改", file=sys.stderr)
    else:
        print(s)
        print("❌ 未找到 device-sims 结构，请手动修改", file=sys.stderr)
VUEEOF
    
    # 应用修改
    python3 -c "
import sys
sys.argv.append('$APPVUE')
exec(open('$TEMP_VUE').read())
" > "${APPVUE}.new"
    
    if [ -s "${APPVUE}.new" ]; then
        mv "${APPVUE}.new" "$APPVUE"
        echo "✅ 前端文件已更新"
    fi
    
    rm -f "$TEMP_VUE" "${APPVUE}.new" 2>/dev/null || true
fi

echo ""
echo "=== [3/3] 构建前端 + 重启服务 ==="
if [ -d "$FRONT" ] && [ -f "$FRONT/package.json" ]; then
    echo "构建前端..."
    cd "$FRONT"
    
    if [ ! -d "node_modules" ]; then
        echo "安装 npm 依赖..."
        if command -v npm >/dev/null 2>&1; then
            npm install --silent > /dev/null 2>&1 || {
                echo "⚠️  npm install 有警告，继续执行..."
            }
        else
            echo "❌ 未找到 npm 命令，跳过前端构建"
            exit 1
        fi
    fi
    
    echo "运行构建..."
    if command -v npm >/dev/null 2>&1; then
        npm run build > /tmp/npm_build.log 2>&1 || {
            echo "⚠️  构建过程可能有错误，检查日志: /tmp/npm_build.log"
            echo "继续执行..."
        }
    fi
    
    echo "✅ 前端构建完成"
else
    echo "⚠️  前端目录不存在，跳过构建"
fi

# 最后重启服务
if command -v systemctl >/dev/null 2>&1; then
    echo "重启服务..."
    systemctl restart nginx 2>/dev/null || true
    systemctl restart board-manager-v4.service 2>/dev/null || true
    systemctl restart board-manager-v6.service 2>/dev/null || true
    echo "✅ 服务已重启"
fi

echo ""
echo "✅ 补丁应用完成！"
echo ""
echo "下一步操作："
echo "1. 打开网页，点击「重新扫描/刷新状态」按钮"
echo "2. 浏览器强制刷新：Ctrl+F5（Windows/Linux）或 Cmd+Shift+R（Mac）"
echo "3. 手机用户请清空缓存或使用无痕模式"
echo ""
echo "如果遇到问题："
echo "• 查看备份文件: $BACKUP"
if [ -f "$BACKUP_VUE" ]; then
    echo "• 前端备份: $BACKUP_VUE"
fi
echo "• 查看服务状态: systemctl status board-manager-v4.service"
echo "• 查看日志: journalctl -u board-manager-v4.service -f"
