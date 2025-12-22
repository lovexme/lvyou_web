#!/bin/bash
#================================================================
# 开发板管理系统 - 完整管理脚本
# 命令：install | uninstall | restart | status | update-ui | logs
#================================================================

set -euo pipefail

# 颜色输出
RED='\u001B[0;31m'
GREEN='\u001B[0;32m'
YELLOW='\u001B[1;33m'
BLUE='\u001B[0;34m'
PURPLE='\u001B[0;35m'
CYAN='\u001B[0;36m'
NC='\u001B[0m'

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${BLUE}[→]${NC} $1"; }
log_title() { echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# 配置
APP_DIR="/opt/board-manager"
FE_DIR="${APP_DIR}/frontend"
VENV="${APP_DIR}/venv"
BAK_DIR="${APP_DIR}/_bak"
SERVICE_API="/etc/systemd/system/board-manager.service"
SERVICE_SCAN="/etc/systemd/system/board-scan.service"
NGINX_CONF="/etc/nginx/conf.d/board-manager.conf"

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限执行"
        echo "执行: sudo bash $0 $1"
        exit 1
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_FAMILY="unknown"
        case "$OS" in
            centos|rhel|fedora|rocky|almalinux)
                OS_FAMILY="redhat"
                PKG_MGR=$(command -v dnf || command -v yum)
                ;;
            ubuntu|debian)
                OS_FAMILY="debian"
                PKG_MGR="apt"
                ;;
        esac
    fi
}

# 安装函数
do_install() {
    log_title "开始安装"
    
    detect_os
    
    # 安装依赖
    log_step "安装系统依赖..."
    if [ "$OS_FAMILY" = "redhat" ]; then
        $PKG_MGR update -y -q 2>/dev/null || true
        $PKG_MGR install -y wget tar curl firewalld nginx python3 python3-pip sqlite 2>/dev/null || true
        systemctl enable --now firewalld 2>/dev/null || true
    else
        export DEBIAN_FRONTEND=noninteractive
        $PKG_MGR update -qq -y
        $PKG_MGR install -y wget tar curl nginx python3 python3-pip python3-venv sqlite3 2>/dev/null || true
    fi
    
    # 安装 Node.js 20.x
    log_step "安装 Node.js 20.x..."
    if [ "$OS_FAMILY" = "redhat" ]; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        $PKG_MGR install -y nodejs
    else
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        $PKG_MGR install -y nodejs
    fi
    
    # 创建目录
    mkdir -p "$APP_DIR" "$FE_DIR/src" "$BAK_DIR"
    
    # 部署后端
    log_step "配置后端服务..."
    cd "$APP_DIR"
    
    if [ ! -d "$VENV" ]; then
        python3 -m venv "$VENV"
    fi
    
    "$VENV/bin/pip" install --upgrade pip -q
    "$VENV/bin/pip" install fastapi "uvicorn[standard]" sqlalchemy pydantic requests -q
    
    # 创建 systemd 服务
    cat > "$SERVICE_API" <<EOF
[Unit]
Description=Board Manager API
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${VENV}/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=2
User=root
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF
    
    # 部署前端（调用 update_ui 函数）
    update_ui
    
    # 配置 Nginx
    log_step "配置 Nginx..."
    cat > "$NGINX_CONF" <<'EOF'
server {
    listen 5173;
    server_name _;
    
    root /opt/board-manager/frontend/dist;
    index index.html;
    
    client_max_body_size 10M;
    
    location /api/ {
        proxy_pass http://127.0.0.1:8000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF
    
    nginx -t
    
    # 配置防火墙
    if [ "$OS_FAMILY" = "redhat" ]; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=5173/tcp
            firewall-cmd --permanent --add-port=8000/tcp
            firewall-cmd --permanent --add-port=80/tcp
            firewall-cmd --reload
        fi
    fi
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable nginx board-manager
    systemctl restart nginx board-manager
    
    show_status
    log_title "安装完成"
}

# 卸载函数
do_uninstall() {
    log_title "开始卸载"
    
    # 停止服务
    log_step "停止服务..."
    systemctl stop board-manager 2>/dev/null || true
    systemctl stop board-scan 2>/dev/null || true
    systemctl disable board-manager 2>/dev/null || true
    systemctl disable board-scan 2>/dev/null || true
    log_info "服务已停止"
    
    # 删除 systemd 服务文件
    log_step "删除服务配置..."
    rm -f "$SERVICE_API" "$SERVICE_SCAN"
    systemctl daemon-reload
    log_info "服务配置已删除"
    
    # 删除 Nginx 配置
    log_step "删除 Nginx 配置..."
    rm -f "$NGINX_CONF"
    nginx -t && systemctl reload nginx 2>/dev/null || true
    log_info "Nginx 配置已删除"
    
    # 删除防火墙规则
    detect_os
    if [ "$OS_FAMILY" = "redhat" ]; then
        if systemctl is-active --quiet firewalld; then
            log_step "删除防火墙规则..."
            firewall-cmd --permanent --remove-port=5173/tcp 2>/dev/null || true
            firewall-cmd --permanent --remove-port=8000/tcp 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            log_info "防火墙规则已删除"
        fi
    fi
    
    # 询问是否删除数据
    echo ""
    read -p "是否删除所有数据和文件？[y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_step "删除应用目录..."
        rm -rf "$APP_DIR"
        log_info "应用目录已删除: $APP_DIR"
    else
        log_warn "保留应用目录: $APP_DIR"
        log_warn "如需完全删除，请手动执行: rm -rf $APP_DIR"
    fi
    
    log_title "卸载完成"
}

# 重启服务
do_restart() {
    log_title "重启服务"
    
    log_step "重启 board-manager..."
    systemctl restart board-manager 2>/dev/null || log_warn "board-manager 重启失败"
    
    log_step "重启 nginx..."
    systemctl restart nginx
    
    log_step "重启 board-scan（如果存在）..."
    systemctl restart board-scan 2>/dev/null || log_warn "board-scan 未运行"
    
    sleep 2
    show_status
    log_title "重启完成"
}

# 查看状态
show_status() {
    log_title "系统状态"
    
    PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${GREEN}🌐 访问地址${NC}"
    echo "  前端界面: http://${PUBLIC_IP}:5173"
    echo "  API接口: http://${PUBLIC_IP}:8000/api/devices"
    echo ""
    
    echo -e "${GREEN}🔧 服务状态${NC}"
    systemctl is-active nginx &>/dev/null && echo "  ✓ Nginx: 运行中" || echo "  ✗ Nginx: 未运行"
    systemctl is-active board-manager &>/dev/null && echo "  ✓ board-manager: 运行中" || echo "  ✗ board-manager: 未运行"
    systemctl is-active board-scan &>/dev/null && echo "  ✓ board-scan: 运行中" || echo "  - board-scan: 未配置"
    echo ""
    
    echo -e "${GREEN}📊 端口监听${NC}"
    ss -tlnp | grep -E ':(5173|8000)s' || echo "  未检测到监听端口"
    echo ""
    
    echo -e "${GREEN}💾 磁盘使用${NC}"
    if [ -d "$APP_DIR" ]; then
        du -sh "$APP_DIR" 2>/dev/null | awk '{print "  应用目录: "$0}'
    fi
    echo ""
}

# 查看日志
show_logs() {
    log_title "查看日志"
    
    echo ""
    echo "选择要查看的日志："
    echo "  1) board-manager (后端API)"
    echo "  2) board-scan (扫描服务)"
    echo "  3) nginx (Web服务器)"
    echo "  4) 全部"
    echo ""
    read -p "请选择 [1-4]: " choice
    
    case $choice in
        1)
            log_info "正在查看 board-manager 日志 (Ctrl+C 退出)..."
            sleep 1
            journalctl -u board-manager -f
            ;;
        2)
            log_info "正在查看 board-scan 日志 (Ctrl+C 退出)..."
            sleep 1
            journalctl -u board-scan -f
            ;;
        3)
            log_info "正在查看 nginx 日志 (Ctrl+C 退出)..."
            sleep 1
            tail -f /var/log/nginx/board-manager-access.log
            ;;
        4)
            log_info "正在查看所有日志 (Ctrl+C 退出)..."
            sleep 1
            journalctl -u board-manager -u board-scan -u nginx -f
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}

# 更新UI
update_ui() {
    log_step "部署美化版UI..."
    
    mkdir -p "${FE_DIR}/src" "$BAK_DIR"
    
    SRC="${FE_DIR}/src/AppContent.vue"
    
    # 备份
    if [ -f "$SRC" ]; then
        cp "$SRC" "${BAK_DIR}/AppContent.vue.$(date +%Y%m%d_%H%M%S).bak"
    fi
    
    # 写入Vue组件（这里是完整的美化版代码）
    cat > "$SRC" <<'VUECODE'
<script setup>
import { ref, onMounted, computed } from 'vue'
import axios from 'axios'

const api = axios.create({ baseURL: '' })
const devices = ref([])
const loading = ref(false)
const msg = ref('')
const smsPhone = ref('')
const smsContent = ref('')
const smsSlot = ref(1)
const selectedIds = ref(new Set())
const searchText = ref('')

const allSelected = computed(() => 
  filteredDevices.value.length > 0 && selectedIds.value.size === filteredDevices.value.length
)

const filteredDevices = computed(() => {
  if (!searchText.value.trim()) return devices.value
  const text = searchText.value.toLowerCase()
  return devices.value.filter(d => 
    d.devId?.toLowerCase().includes(text) || 
    d.ip?.toLowerCase().includes(text) ||
    d.sims?.sim1?.number?.includes(text) ||
    d.sims?.sim2?.number?.includes(text)
  )
})

const onlineCount = computed(() => devices.value.filter(d => d.status === 'online').length)
const offlineCount = computed(() => devices.value.filter(d => d.status !== 'online').length)

function toggleAll() {
  if (allSelected.value) {
    selectedIds.value = new Set()
  } else {
    selectedIds.value = new Set(filteredDevices.value.map(d => d.id))
  }
}

function toggleOne(id) {
  const s = new Set(selectedIds.value)
  s.has(id) ? s.delete(id) : s.add(id)
  selectedIds.value = s
}

function prettyTime(ts) {
  if (!ts) return '-'
  return new Date(ts * 1000).toLocaleString('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  })
}

function simLine(d, slot) {
  const sim = slot === 1 ? d?.sims?.sim1 : d?.sims?.sim2
  if (!sim) return '-'
  const number = (sim.number || '').trim()
  const op = (sim.operator || '').trim()
  const label = (sim.label || '').trim()
  
  if (number && op) return `${number} (${op})`
  if (number) return number
  if (label) return label
  if (op) return op
  return '-'
}

async function loadDevices() {
  loading.value = true
  msg.value = ''
  try {
    const { data } = await api.get('/api/devices')
    devices.value = data
  } catch (e) {
    msg.value = '❌ ' + (e?.response?.data?.detail || e.message)
  } finally {
    loading.value = false
  }
}

async function refreshAllStat() {
  loading.value = true
  msg.value = ''
  try {
    const { data } = await api.post('/api/devices/stat_refresh_all?limit=200')
    msg.value = `✅ 已刷新 ${data.refreshed} 台，失败 ${data.failed} 台`
    await loadDevices()
  } catch (e) {
    msg.value = '❌ ' + (e?.response?.data?.detail || e.message)
  } finally {
    loading.value = false
  }
}

async function startScanAdd() {
  loading.value = true
  msg.value = ''
  try {
    const { data } = await api.post('/api/scan/start')
    msg.value = '🔍 ' + data.msg
  } catch (e) {
    msg.value = '❌ ' + (e?.response?.data?.detail || e.message)
  } finally {
    loading.value = false
  }
}

async function sendSms() {
  const ids = Array.from(selectedIds.value)
  if (ids.length === 0) {
    msg.value = '⚠️ 请先选择设备'
    return
  }
  if (!smsPhone.value.trim()) {
    msg.value = '⚠️ 请输入接收号码'
    return
  }
  if (!smsContent.value.trim()) {
    msg.value = '⚠️ 请输入短信内容'
    return
  }
  
  loading.value = true
  msg.value = ''
  try {
    const payload = {
      deviceIds: ids,
      phone: smsPhone.value.trim(),
      content: smsContent.value.trim(),
      slot: Number(smsSlot.value)
    }
    const { data } = await api.post('/api/sms/send', payload)
    const ok = data.results.filter(r => r.ok).length
    const fail = data.results.filter(r => !r.ok).length
    msg.value = `✅ 成功 ${ok} 台，失败 ${fail} 台 (SIM${smsSlot.value})`
  } catch (e) {
    msg.value = '❌ ' + (e?.response?.data?.error || e?.response?.data?.detail || e.message)
  } finally {
    loading.value = false
  }
}

onMounted(() => loadDevices())
</script>

<template>
  <div class="page">
    <header class="header">
      <div class="header-left">
        <div class="logo">
          <svg class="logo-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor">
            <rect x="3" y="3" width="18" height="18" rx="2" stroke-width="2"/>
            <path d="M3 9h18M9 3v18" stroke-width="2"/>
          </svg>
          <div>
            <div class="title">开发板管理系统</div>
            <div class="subtitle">绿邮 X系列双卡双待 4G 开发板</div>
          </div>
        </div>
      </div>
      <div class="header-right">
        <button class="btn btn-icon" :disabled="loading" @click="loadDevices" title="刷新列表">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M21.5 2v6h-6M2.5 22v-6h6M2 11.5a10 10 0 0118.8-4.3M22 12.5a10 10 0 01-18.8 4.2"/>
          </svg>
        </button>
      </div>
    </header>

    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-icon online">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10"/>
            <path d="M12 6v6l4 2"/>
          </svg>
        </div>
        <div class="stat-content">
          <div class="stat-value">{{ onlineCount }}</div>
          <div class="stat-label">在线设备</div>
        </div>
      </div>
      
      <div class="stat-card">
        <div class="stat-icon offline">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10"/>
            <path d="M15 9l-6 6M9 9l6 6"/>
          </svg>
        </div>
        <div class="stat-content">
          <div class="stat-value">{{ offlineCount }}</div>
          <div class="stat-label">离线设备</div>
        </div>
      </div>
      
      <div class="stat-card">
        <div class="stat-icon total">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M17 21v-2a4 4 0 00-4-4H5a4 4 0 00-4 4v2"/>
            <circle cx="9" cy="7" r="4"/>
            <path d="M23 21v-2a4 4 0 00-3-3.87M16 3.13a4 4 0 010 7.75"/>
          </svg>
        </div>
        <div class="stat-content">
          <div class="stat-value">{{ devices.length }}</div>
          <div class="stat-label">总设备数</div>
        </div>
      </div>
      
      <div class="stat-card">
        <div class="stat-icon selected">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M9 11l3 3L22 4"/>
            <path d="M21 12v7a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2h11"/>
          </svg>
        </div>
        <div class="stat-content">
          <div class="stat-value">{{ selectedIds.size }}</div>
          <div class="stat-label">已选设备</div>
        </div>
      </div>
    </div>

    <transition name="fade">
      <div v-if="msg" class="toast" :class="{ 'toast-error': msg.includes('❌') }">
        {{ msg }}
        <button class="toast-close" @click="msg = ''">×</button>
      </div>
    </transition>

    <section class="card">
      <div class="card-header">
        <h2>📱 群发短信</h2>
        <div class="card-actions">
          <button class="btn btn-sm btn-secondary" :disabled="loading" @click="refreshAllStat">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M21 12a9 9 0 11-6.219-8.56"/>
            </svg>
            刷新状态
          </button>
          <button class="btn btn-sm btn-secondary" :disabled="loading" @click="startScanAdd">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="11" cy="11" r="8"/>
              <path d="M21 21l-4.35-4.35"/>
            </svg>
            扫描添加
          </button>
        </div>
      </div>
      
      <div class="form-grid">
        <div class="form-group">
          <label>卡槽选择</label>
          <select v-model="smsSlot" class="input select">
            <option :value="1">SIM1 卡槽</option>
            <option :value="2">SIM2 卡槽</option>
          </select>
        </div>
        
        <div class="form-group">
          <label>接收号码</label>
          <input v-model="smsPhone" class="input" placeholder="13800138000" />
        </div>
        
        <div class="form-group full-width">
          <label>短信内容</label>
          <textarea v-model="smsContent" class="input textarea" rows="3" 
            placeholder="输入要发送的短信内容..."></textarea>
        </div>
        
        <div class="form-group full-width">
          <button class="btn btn-primary btn-lg" :disabled="loading || selectedIds.size === 0" @click="sendSms">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M22 2L11 13M22 2l-7 20-4-9-9-4 20-7z"/>
            </svg>
            发送短信 ({{ selectedIds.size }} 台设备)
          </button>
        </div>
      </div>
    </section>

    <section class="card">
      <div class="card-header">
        <h2>📡 设备列表</h2>
        <div class="search-box">
          <svg class="search-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="8"/>
            <path d="M21 21l-4.35-4.35"/>
          </svg>
          <input v-model="searchText" class="input search-input" placeholder="搜索设备ID、IP或号码..." />
        </div>
      </div>
      
      <div class="table-wrap">
        <table class="table">
          <thead>
            <tr>
              <th style="width: 50px">
                <input type="checkbox" :checked="allSelected" @change="toggleAll" />
              </th>
              <th style="width: 140px">设备ID</th>
              <th style="width: 140px">IP地址</th>
              <th style="width: 100px">状态</th>
              <th>SIM1 卡槽</th>
              <th>SIM2 卡槽</th>
              <th style="width: 160px">最后在线</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="d in filteredDevices" :key="d.id" :class="{ 'row-selected': selectedIds.has(d.id) }">
              <td>
                <input type="checkbox" :checked="selectedIds.has(d.id)" @change="toggleOne(d.id)" />
              </td>
              <td class="mono">{{ d.devId }}</td>
              <td class="mono">{{ d.ip }}</td>
              <td>
                <span class="badge" :class="d.status === 'online' ? 'badge-success' : 'badge-danger'">
                  <span class="badge-dot"></span>
                  {{ d.status === 'online' ? '在线' : '离线' }}
                </span>
              </td>
              <td>
                <div class="sim-info">
                  <svg class="sim-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <rect x="5" y="2" width="14" height="20" rx="2"/>
                    <path d="M10 2v4M14 2v4"/>
                  </svg>
                  {{ simLine(d, 1) }}
                </div>
              </td>
              <td>
                <div class="sim-info">
                  <svg class="sim-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                    <rect x="5" y="2" width="14" height="20" rx="2"/>
                    <path d="M10 2v4M14 2v4"/>
                  </svg>
                  {{ simLine(d, 2) }}
                </div>
              </td>
              <td class="mono time">{{ prettyTime(d.lastSeen) }}</td>
            </tr>
            <tr v-if="filteredDevices.length === 0">
              <td colspan="7" class="empty-state">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="12" cy="12" r="10"/>
                  <path d="M12 8v4M12 16h.01"/>
                </svg>
                <p>{{ searchText ? '未找到匹配的设备' : '暂无设备数据' }}</p>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <footer class="footer">
      <p>绿邮® X系列开发板管理系统</p>
    </footer>
  </div>
</template>

<style scoped>
* { box-sizing: border-box; }
.page {
  min-height: 100vh;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  padding: 24px;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}
.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 24px;
}
.logo {
  display: flex;
  align-items: center;
  gap: 16px;
}
.logo-icon {
  width: 48px;
  height: 48px;
  color: #fff;
  filter: drop-shadow(0 4px 6px rgba(0,0,0,0.1));
}
.title {
  font-size: 28px;
  font-weight: 800;
  color: #fff;
  text-shadow: 0 2px 4px rgba(0,0,0,0.1);
}
.subtitle {
  font-size: 13px;
  color: rgba(255,255,255,0.9);
  margin-top: 4px;
}
.btn {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  padding: 10px 18px;
  border: none;
  border-radius: 12px;
  font-weight: 600;
  font-size: 14px;
  cursor: pointer;
  transition: all 0.2s;
  background: #fff;
  color: #334155;
  box-shadow: 0 2px 8px rgba(0,0,0,0.1);
}
.btn:hover:not(:disabled) {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(0,0,0,0.15);
}
.btn:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}
.btn svg {
  width: 18px;
  height: 18px;
}
.btn-icon {
  padding: 10px;
  background: rgba(255,255,255,0.2);
  color: #fff;
  backdrop-filter: blur(10px);
}
.btn-primary {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: #fff;
}
.btn-secondary {
  background: #f1f5f9;
  color: #475569;
}
.btn-sm {
  padding: 8px 14px;
  font-size: 13px;
}
.btn-lg {
  padding: 14px 28px;
  font-size: 16px;
  width: 100%;
}
.stats-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 16px;
  margin-bottom: 24px;
}
.stat-card {
  background: #fff;
  border-radius: 16px;
  padding: 20px;
  display: flex;
  align-items: center;
  gap: 16px;
  box-shadow: 0 4px 12px rgba(0,0,0,0.08);
  transition: transform 0.2s;
}
.stat-card:hover {
  transform: translateY(-4px);
}
.stat-icon {
  width: 56px;
  height: 56px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
}
.stat-icon svg {
  width: 28px;
  height: 28px;
  color: #fff;
}
.stat-icon.online {
  background: linear-gradient(135deg, #10b981 0%, #059669 100%);
}
.stat-icon.offline {
  background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%);
}
.stat-icon.total {
  background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%);
}
.stat-icon.selected {
  background: linear-gradient(135deg, #8b5cf6 0%, #7c3aed 100%);
}
.stat-value {
  font-size: 32px;
  font-weight: 800;
  color: #0f172a;
  line-height: 1;
}
.stat-label {
  font-size: 13px;
  color: #64748b;
  margin-top: 4px;
}
.toast {
  background: #fff;
  border-left: 4px solid #10b981;
  border-radius: 12px;
  padding: 14px 18px;
  margin-bottom: 24px;
  box-shadow: 0 4px 12px rgba(0,0,0,0.1);
  display: flex;
  justify-content: space-between;
  align-items: center;
}
.toast-error {
  border-left-color: #ef4444;
}
.toast-close {
  background: none;
  border: none;
  font-size: 24px;
  color: #64748b;
  cursor: pointer;
}
.fade-enter-active, .fade-leave-active {
  transition: all 0.3s;
}
.fade-enter-from, .fade-leave-to {
  opacity: 0;
  transform: translateY(-10px);
}
.card {
  background: #fff;
  border-radius: 20px;
  padding: 24px;
  margin-bottom: 24px;
  box-shadow: 0 4px 16px rgba(0,0,0,0.08);
}
.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 20px;
  flex-wrap: wrap;
  gap: 16px;
}
.card-header h2 {
  font-size: 20px;
  font-weight: 800;
  color: #0f172a;
  margin: 0;
}
.card-actions {
  display: flex;
  gap: 10px;
}
.form-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 16px;
}
.form-group {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.form-group.full-width {
  grid-column: 1 / -1;
}
.form-group label {
  font-size: 13px;
  font-weight: 700;
  color: #334155;
}
.input {
  padding: 12px 16px;
  border: 2px solid #e2e8f0;
  border-radius: 10px;
  font-size: 14px;
  transition: all 0.2s;
  outline: none;
}
.input:focus {
  border-color: #667eea;
  box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
}
.textarea {
  resize: vertical;
  font-family: inherit;
}
.search-box {
  position: relative;
  width: 300px;
}
.search-icon {
  position: absolute;
  left: 12px;
  top: 50%;
  transform: translateY(-50%);
  width: 18px;
  height: 18px;
  color: #94a3b8;
  pointer-events: none;
}
.search-input {
  padding-left: 40px;
  width: 100%;
}
.table-wrap {
  overflow-x: auto;
  border-radius: 12px;
  border: 1px solid #e2e8f0;
}
.table {
  width: 100%;
  border-collapse: collapse;
  min-width: 900px;
}
.table thead th {
  background: #f8fafc;
  padding: 14px 16px;
  text-align: left;
  font-size: 12px;
  font-weight: 700;
  color: #475569;
  text-transform: uppercase;
  border-bottom: 2px solid #e2e8f0;
}
.table tbody td {
  padding: 16px;
  border-bottom: 1px solid #f1f5f9;
  font-size: 14px;
  color: #334155;
}
.table tbody tr:hover {
  background: #f8fafc;
}
.table tbody tr.row-selected {
  background: #ede9fe;
}
.mono {
  font-family: ui-monospace, monospace;
  font-size: 13px;
}
.badge {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 6px 12px;
  border-radius: 20px;
  font-size: 12px;
  font-weight: 700;
}
.badge-success {
  background: rgba(16, 185, 129, 0.1);
  color: #065f46;
}
.badge-danger {
  background: rgba(239, 68, 68, 0.1);
  color: #7f1d1d;
}
.badge-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: currentColor;
  animation: pulse 2s infinite;
}
@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}
.sim-info {
  display: flex;
  align-items: center;
  gap: 8px;
}
.sim-icon {
  width: 16px;
  height: 16px;
  color: #64748b;
}
.empty-state {
  text-align: center;
  padding: 48px 20px !important;
  color: #94a3b8;
}
.empty-state svg {
  width: 48px;
  height: 48px;
  margin: 0 auto 12px;
}
.footer {
  text-align: center;
  color: rgba(255,255,255,0.8);
  font-size: 13px;
  margin-top: 24px;
}
@media (max-width: 768px) {
  .stats-grid {
    grid-template-columns: repeat(2, 1fr);
  }
  .form-grid {
    grid-template-columns: 1fr;
  }
  .search-box {
    width: 100%;
  }
}
</style>
VUECODE

    # 初始化前端项目
    if [ ! -f "${FE_DIR}/package.json" ]; then
        cd "$FE_DIR"
        cat > package.json <<'PKG'
{
  "name": "frontend",
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "vue": "^3.4.0",
    "axios": "^1.6.0"
  },
  "devDependencies": {
    "@vitejs/plugin-vue": "^5.0.0",
    "vite": "^5.4.11"
  }
}
PKG
        npm install
    fi
    
    # 构建
    cd "$FE_DIR"
    npm run build
    
    log_info "UI更新完成"
}

# 帮助信息
show_help() {
    cat <<EOF

开发板管理系统 - 管理脚本

用法: sudo bash $0 [命令]

命令:
  install       安装系统（完整安装所有组件）
  uninstall     卸载系统（可选择是否删除数据）
  restart       重启所有服务
  status        查看系统状态
  update-ui     更新并美化UI界面
  logs          查看系统日志
  help          显示此帮助信息

示例:
  sudo bash $0 install      # 安装系统
  sudo bash $0 status       # 查看状态
  sudo bash $0 restart      # 重启服务
  sudo bash $0 uninstall    # 卸载系统
  sudo bash $0 logs         # 查看日志

EOF
}

# 主函数
main() {
    CMD="${1:-help}"
    
    case "$CMD" in
        install)
            check_root "$CMD"
            do_install
            ;;
        uninstall)
            check_root "$CMD"
            do_uninstall
            ;;
        restart)
            check_root "$CMD"
            do_restart
            ;;
        status)
            show_status
            ;;
        update-ui)
            check_root "$CMD"
            update_ui
            log_step "重启服务..."
            systemctl restart nginx
            log_info "UI已更新"
            ;;
        logs)
            show_logs
            ;;
        help|*)
            show_help
            ;;
    esac
}

main "$@"