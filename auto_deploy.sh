#!/bin/bash
#================================================================
# 开发板管理系统 - 全自动一键部署脚本
# 功能：自动识别系统 + 安装环境 + 部署服务 + 美化UI
# 支持：CentOS/RHEL/Fedora/Rocky/Alma + Ubuntu/Debian
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

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限执行此脚本"
        echo "执行: sudo bash $0"
        exit 1
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
        OS_NAME=$PRETTY_NAME
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        OS_NAME=$(cat /etc/redhat-release)
    else
        log_error "无法识别操作系统"
        exit 1
    fi
    
    case "$OS" in
        centos|rhel|fedora|rocky|almalinux)
            PKG_MGR="dnf"
            if ! command -v dnf &>/dev/null; then
                PKG_MGR="yum"
            fi
            OS_FAMILY="redhat"
            ;;
        ubuntu|debian)
            PKG_MGR="apt"
            OS_FAMILY="debian"
            ;;
        *)
            log_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
}

# 安装依赖
install_dependencies() {
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
    
    log_info "系统依赖安装完成"
}

# 安装 Node.js 20.x
install_nodejs() {
    log_step "检查 Node.js 版本..."
    
    if command -v node &>/dev/null; then
        NODE_VERSION=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$NODE_VERSION" -ge 20 ]; then
            log_info "Node.js 版本符合要求: $(node --version)"
            return 0
        else
            log_warn "Node.js 版本过低: $(node --version)，需要升级"
        fi
    fi
    
    log_step "安装 Node.js 20.x LTS..."
    
    if [ "$OS_FAMILY" = "redhat" ]; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        $PKG_MGR install -y nodejs
    else
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        $PKG_MGR install -y nodejs
    fi
    
    log_info "Node.js 安装完成: $(node --version)"
    log_info "npm 版本: $(npm --version)"
}

# 部署 board-manager 后端
deploy_backend() {
    log_step "部署后端服务..."
    
    APP_DIR="/opt/board-manager"
    VENV="${APP_DIR}/venv"
    DB="${APP_DIR}/data.db"
    
    mkdir -p "$APP_DIR"
    cd "$APP_DIR"
    
    # 创建虚拟环境
    if [ ! -d "$VENV" ]; then
        python3 -m venv "$VENV"
    fi
    
    "$VENV/bin/pip" install --upgrade pip -q
    
    # 安装依赖
    if [ -f "requirements.txt" ]; then
        "$VENV/bin/pip" install -r requirements.txt -q
    else
        "$VENV/bin/pip" install fastapi "uvicorn[standard]" sqlalchemy pydantic requests -q
    fi
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/board-manager.service <<EOF
[Unit]
Description=Board Manager API
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=${VENV}/bin/uvicorn app.main:app --host 0.0.0.1 --port 8000
Restart=on-failure
RestartSec=2
User=root
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable board-manager 2>/dev/null || true
    
    log_info "后端服务配置完成"
}

# 部署前端
deploy_frontend() {
    log_step "部署前端..."
    
    FE_DIR="/opt/board-manager/frontend"
    SRC="${FE_DIR}/src/AppContent.vue"
    
    mkdir -p "${FE_DIR}/src"
    
    # 写入美化版 Vue 组件
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
      <p>绿邮® X系列开发板管理系统 | SIM卡槽运营商/标签信息会自动显示</p>
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

    log_info "前端UI文件创建完成"
    
    # 创建 package.json 和其他必要文件
    if [ ! -f "${FE_DIR}/package.json" ]; then
        log_step "初始化前端项目..."
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
    
    # 构建前端
    log_step "构建前端..."
    cd "$FE_DIR"
    npm run build
    
    log_info "前端构建完成"
}

# 配置 Nginx
configure_nginx() {
    log_step "配置 Nginx..."
    
    cat > /etc/nginx/conf.d/board-manager.conf <<'EOF'
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
    
    # 测试配置
    nginx -t
    
    # 启动 Nginx
    systemctl enable nginx
    systemctl restart nginx
    
    log_info "Nginx 配置完成"
}

# 配置防火墙
configure_firewall() {
    log_step "配置防火墙..."
    
    if [ "$OS_FAMILY" = "redhat" ]; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=5173/tcp
            firewall-cmd --permanent --add-port=8000/tcp
            firewall-cmd --permanent --add-port=80/tcp
            firewall-cmd --reload
            log_info "firewalld 规则已添加"
        fi
    else
        if command -v ufw &>/dev/null; then
            ufw allow 5173/tcp
            ufw allow 8000/tcp
            ufw allow 80/tcp
            log_info "ufw 规则已添加"
        fi
    fi
}

# 启动所有服务
start_services() {
    log_step "启动服务..."
    
    systemctl start board-manager 2>/dev/null || log_warn "board-manager 启动失败（可能需要先配置后端代码）"
    systemctl restart nginx
    
    log_info "服务已启动"
}

# 显示部署结果
show_result() {
    PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    log_title "部署完成"
    
    echo ""
    echo -e "${GREEN}✅ 系统信息${NC}"
    echo "  操作系统: $OS_NAME"
    echo "  包管理器: $PKG_MGR"
    echo "  Node.js: $(node --version)"
    echo "  npm: $(npm --version)"
    echo "  Python: $(python3 --version)"
    echo ""
    
    echo -e "${GREEN}🌐 访问地址${NC}"
    echo "  前端界面: http://${PUBLIC_IP}:5173"
    echo "  API接口: http://${PUBLIC_IP}:8000/api/devices"
    echo ""
    
    echo -e "${GREEN}🔧 服务状态${NC}"
    systemctl is-active nginx &>/dev/null && echo "  ✓ Nginx: 运行中" || echo "  ✗ Nginx: 未运行"
    systemctl is-active board-manager &>/dev/null && echo "  ✓ board-manager: 运行中" || echo "  ✗ board-manager: 未运行"
    echo ""
    
    echo -e "${GREEN}📝 常用命令${NC}"
    echo "  查看服务状态: systemctl status board-manager"
    echo "  查看日志: journalctl -u board-manager -f"
    echo "  重启服务: systemctl restart board-manager nginx"
    echo "  查看端口: ss -tlnp | grep -E '(5173|8000)'"
    echo ""
    
    if [ "$OS_FAMILY" = "redhat" ]; then
        echo -e "${YELLOW}🔥 防火墙已开放端口: 5173, 8000, 80${NC}"
    fi
    
    echo ""
    log_title "部署成功"
}

# 主函数
main() {
    clear
    
    log_title "开发板管理系统 - 自动部署脚本"
    echo ""
    
    check_root
    detect_os
    
    log_info "检测到系统: $OS_NAME"
    log_info "包管理器: $PKG_MGR"
    echo ""
    
    install_dependencies
    install_nodejs
    deploy_backend
    deploy_frontend
    configure_nginx
    configure_firewall
    start_services
    
    echo ""
    show_result
}

# 执行主函数
main "$@"