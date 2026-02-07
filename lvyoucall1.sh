#!/usr/bin/env bash
set -euo pipefail

# ================= 配置区（可根据实际路径修改） =================
FILE="/opt/board-manager/frontend/src/App.vue"
FRONT="/opt/board-manager/frontend"
# ================================================================

# 检查文件和目录是否存在
if [[ ! -f "$FILE" ]]; then
  echo "❌ 找不到文件：$FILE"
  exit 1
fi
if [[ ! -d "$FRONT" ]]; then
  echo "❌ 找不到前端目录：$FRONT"
  exit 1
fi

echo "🔧 修复 SIM 显示（SIM1/2 第一行运营商不换行，第二行手机号）..."

# 1. 备份原文件
BACKUP="${FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp -a "$FILE" "$BACKUP"
echo "✅ 已备份原文件：$BACKUP"

# 2. 用 Python 直接内联修改 App.vue（核心逻辑）
python3 - "$FILE" << 'PY'
import sys, re
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text(encoding="utf-8", errors="ignore")

# 匹配旧的 SIM 卡显示模板（一行显示号码）
old_pattern = re.compile(
    r'<div v-if="d\.sims\?\.\s*sim1\?\.\s*number\s*\|\|\s*d\.sims\?\.\s*sim2\?\.\s*number"\s+class="device-sims">\s*'
    r'<span v-if="d\.sims\.sim1\.number"\s+class="sim-badge">\s*SIM1:\s*\{\{\s*d\.sims\.sim1\.number\s*\}\}\s*</span>\s*'
    r'<span v-if="d\.sims\.sim2\.number"\s+class="sim-badge">\s*SIM2:\s*\{\{\s*d\.sims\.sim2\.number\s*\}\}\s*</span>\s*'
    r'</div>',
    re.S
)

# 新的两行显示模板（运营商在上，号码在下）
new_template = """<div v-if="d.sims?.sim1?.number || d.sims?.sim2?.number || d.sims?.sim1?.operator || d.sims?.sim2?.operator" class="device-sims">
                     <span v-if="d.sims?.sim1?.number || d.sims?.sim1?.operator" class="sim-badge BM_SIM_UI_PATCH_V2">
                       <span class="sim-title">SIM1: {{ d.sims?.sim1?.operator || '未知运营商' }}</span>
                       <span class="sim-number mono">{{ d.sims?.sim1?.number || '-' }}</span>
                     </span>
                     <span v-if="d.sims?.sim2?.number || d.sims?.sim2?.operator" class="sim-badge BM_SIM_UI_PATCH_V2">
                       <span class="sim-title">SIM2: {{ d.sims?.sim2?.operator || '未知运营商' }}</span>
                       <span class="sim-number mono">{{ d.sims?.sim2?.number || '-' }}</span>
                     </span>
                   </div>"""

# 替换模板
match = old_pattern.search(content)
if match:
    content = content[:match.start()] + new_template + content[match.end():]
else:
    # 检查是否已打过补丁，避免重复修改
    if "BM_SIM_UI_PATCH_V2" not in content:
        print("❌ 没匹配到 device-sims 模板片段（你 App.vue 结构不同）")
        sys.exit(1)

# 删除旧的 CSS 样式（避免冲突）
content = re.sub(
    r"/\*\s*SIM 徽章：两行显示（运营商在上，号码在下）\s*\*/.*?\}\s*",
    "",
    content,
    flags=re.S
)

# 追加新的 CSS 样式（两行布局 + 第一行不换行）
new_css = """
/* ===== SIM 两行显示最终样式（运营商一行 + 手机号一行） ===== */
.sim-badge.BM_SIM_UI_PATCH_V2{
    display:inline-flex;
    flex-direction:column;
    align-items:flex-start;
    gap:3px;
    line-height:1.2;
}
.sim-badge.BM_SIM_UI_PATCH_V2 .sim-title{
    font-size:12px;
    font-weight:600;
    white-space:nowrap;   /* 运营商名称不拆行 */
}
.sim-badge.BM_SIM_UI_PATCH_V2 .sim-number{
    font-size:11px;
    opacity:.85;
}
"""

# 写入 CSS 到文件
if new_css not in content:
    if "</style>" in content:
        content = content.replace("</style>", new_css + "\n</style>", 1)
    else:
        content += "\n<style>\n" + new_css + "\n</style>\n"

# 保存修改后的文件
path.write_text(content, encoding="utf-8")
print("✅ App.vue 模板与 CSS 已更新完成")
PY

# 3. 构建前端
echo "📦 开始构建前端代码..."
cd "$FRONT"
# 仅在无 node_modules 时安装依赖
if [[ ! -d "node_modules" ]]; then
    echo "🔧 安装前端依赖（npm install）..."
    npm install
fi
# 执行构建
echo "🔨 执行前端构建（npm run build）..."
npm run build

# 4. 重启服务
echo "🔄 重启相关服务..."
systemctl restart nginx 2>/dev/null || true
systemctl restart board-manager-v4.service 2>/dev/null || true
systemctl restart board-manager-v6.service 2>/dev/null || true

# 5. 完成提示
echo -e "\n✅ 一键修复 SIM 显示 UI 完成！"
echo "👉 请在浏览器强制刷新页面（Ctrl+F5 / 手机清缓存/无痕模式）查看效果"
