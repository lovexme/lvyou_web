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

# 使用 sed 和 awk 进行修改（纯 sh 方案）
{
    # 添加 import re（如果不存在）
    if ! grep -q '^[[:space:]]*import[[:space:]]\+re[[:space:]]*$' "$MAIN"; then
        awk '
        /^[[:space:]]*(import|from)[[:space:]]/ { last_import = NR }
        END {
            if (last_import) {
                # 在最后一行import后添加
                system("sed -i \"" last_import + 1 "i import re\" '"$MAIN"'")
            } else {
                # 文件开头添加
                system("sed -i \"1i import re\" '"$MAIN"'")
            }
        }' "$MAIN"
    fi
    
    # 添加/替换 _bm_op_from_sta 函数
    if grep -q '^[[:space:]]*def[[:space:]]\+_bm_op_from_sta' "$MAIN"; then
        # 替换现有函数
        sed -i '/^[[:space:]]*def[[:space:]]\+_bm_op_from_sta/,/^[[:space:]]*def\|^[[:space:]]*class\|^[[:space:]]*@/{
            /^[[:space:]]*def[[:space:]]\+_bm_op_from_sta/{
                x
                s/.*/def _bm_op_from_sta(sta: str) -> str:\
    """从 SIM*_STA 取运营商显示，保留完整 '"'"'移动(46001)'"'"' 形式"""\
    return (sta or "").strip()/
                p
                d
            }
            /^[[:space:]]*def\|^[[:space:]]*class\|^[[:space:]]*@/!d
        }' "$MAIN"
    else
        # 在 import 后插入函数
        awk '
        /^[[:space:]]*(import|from)[[:space:]]/ { last_import = NR }
        END {
            if (last_import) {
                cmd = "sed -i \"" last_import + 1 "i\\"
                cmd = cmd "\\n"
                cmd = cmd "def _bm_op_from_sta(sta: str) -> str:\\"
                cmd = cmd "\\n    \\\"\\\"\\\"从 SIM*_STA 取运营商显示，保留完整 '\''移动(46001)'\'' 形式\\\"\\\"\\\"\\"
                cmd = cmd "\\n    return (sta or \\\"\\\").strip()"
                cmd = cmd "\\n\" '\""$MAIN"'\""
                system(cmd)
            }
        }' "$MAIN"
    fi
    
    # 添加 SIM1_STA/SIM2_STA 到 keys
    sed -i 's/"SIM2_OP"]/"SIM2_OP","SIM1_STA","SIM2_STA"]/g' "$MAIN"
    sed -i "s/'SIM2_OP']/'SIM2_OP','SIM1_STA','SIM2_STA']/g" "$MAIN"
    
    # 修改 sim1op 和 sim2op 的赋值逻辑
    sed -i 's/sim1op = (data.get("SIM1_OP") or "").strip()/sim1op = ((data.get("SIM1_OP") or "").strip() or _bm_op_from_sta(data.get("SIM1_STA") or ""))/g' "$MAIN"
    sed -i "s/sim1op = (data.get('SIM1_OP') or '').strip()/sim1op = ((data.get('SIM1_OP') or '').strip() or _bm_op_from_sta(data.get('SIM1_STA') or ''))/g" "$MAIN"
    sed -i 's/sim2op = (data.get("SIM2_OP") or "").strip()/sim2op = ((data.get("SIM2_OP") or "").strip() or _bm_op_from_sta(data.get("SIM2_STA") or ""))/g' "$MAIN"
    sed -i "s/sim2op = (data.get('SIM2_OP') or '').strip()/sim2op = ((data.get('SIM2_OP') or '').strip() or _bm_op_from_sta(data.get('SIM2_STA') or ''))/g" "$MAIN"
    
    echo "✅ 后端补丁完成：operator 将显示 '移动(460xx)'"
}

# 重启服务
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart board-manager-v4.service 2>/dev/null || true
    systemctl restart board-manager-v6.service 2>/dev/null || true
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
    
    # 使用 sed 修改 App.vue
    TEMP_FILE=$(mktemp)
    
    # 读取文件内容
    content=$(cat "$APPVUE")
    
    # 替换 SIM 显示块（简化版，适用于常见结构）
    new_sim_block='<div v-if="d.sims?.sim1?.number || d.sims?.sim2?.number || d.sims?.sim1?.operator || d.sims?.sim2?.operator" class="device-sims">\
  <span v-if="d.sims?.sim1?.number || d.sims?.sim1?.operator" class="sim-badge bm-sim">\
    <span class="sim-title">SIM1: {{ d.sims?.sim1?.operator || '"'"'未知运营商'"'"' }}</span>\
    <span class="sim-number mono">{{ d.sims?.sim1?.number || '"'"'-'"'"' }}</span>\
  </span>\
  <span v-if="d.sims?.sim2?.number || d.sims?.sim2?.operator" class="sim-badge bm-sim">\
    <span class="sim-title">SIM2: {{ d.sims?.sim2?.operator || '"'"'未知运营商'"'"' }}</span>\
    <span class="sim-number mono">{{ d.sims?.sim2?.number || '"'"'-'"'"' }}</span>\
  </span>\
</div>'
    
    # 尝试替换现有结构
    echo "$content" | awk '
    BEGIN { in_sim_div = 0; replaced = 0 }
    /<div[[:space:]].*device-sims/ { in_sim_div = 1 }
    in_sim_div && /<\/div>/ {
        if (!replaced) {
            print "'"$new_sim_block"'"
            replaced = 1
        }
        in_sim_div = 0
        next
    }
    in_sim_div { next }
    { print }
    ' > "$TEMP_FILE"
    
    # 检查是否替换成功
    if grep -q 'class="device-sims"' "$TEMP_FILE"; then
        mv "$TEMP_FILE" "$APPVUE"
        
        # 添加样式
        if grep -q '<style>' "$APPVUE"; then
            # 移除可能存在的旧样式
            sed -i '/\/\* ===== BM_SIM_REINSTALL_STYLE ===== \*\//,/\/\* ===== END BM_SIM_REINSTALL_STYLE ===== \*\//d' "$APPVUE"
            
            # 添加新样式
            css='/* ===== BM_SIM_REINSTALL_STYLE ===== */\
.device-sims{ display:flex; gap:6px; flex-wrap:wrap; align-items:flex-start; }\
.sim-badge.bm-sim{\
  display:inline-flex;\
  flex-direction:column;\
  align-items:flex-start;\
  gap:2px;\
  padding:4px 8px;\
  border:1px solid rgba(255,255,255,.12);\
  border-radius:8px;\
  background:rgba(255,255,255,.04);\
}\
.sim-badge.bm-sim .sim-title{\
  font-size:10px;\
  font-weight:600;\
  opacity:.75;\
  white-space:nowrap;\
}\
.sim-badge.bm-sim .sim-number{\
  font-size:13px;\
  font-weight:800;\
  opacity:.95;\
}\
/* ===== END BM_SIM_REINSTALL_STYLE ===== */'
            
            sed -i "/<style>/a $css" "$APPVUE"
        fi
        
        echo "✅ 前端补丁完成：两行紧凑显示"
    else
        echo "⚠️  前端结构可能已变化，使用手动补丁"
        rm -f "$TEMP_FILE"
        
        # 创建手动补丁说明
        echo ""
        echo "=== 手动补丁说明 ==="
        echo "请编辑 $APPVUE"
        echo "1. 找到 device-sims 相关的 div 元素"
        echo "2. 替换为以下内容:"
        echo "$new_sim_block"
        echo "3. 在 <style> 标签内添加以下 CSS:"
        echo "$css"
    fi
fi

echo ""
echo "=== [3/3] 构建前端 + 重启服务 ==="
if [ -d "$FRONT" ] && [ -f "$FRONT/package.json" ]; then
    echo "构建前端..."
    cd "$FRONT"
    
    if [ ! -d "node_modules" ]; then
        echo "安装 npm 依赖..."
        npm install --silent
    fi
    
    echo "运行构建..."
    npm run build > /dev/null 2>&1 || {
        echo "⚠️  构建过程可能有警告，继续执行..."
    }
    
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
