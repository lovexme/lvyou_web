#!/usr/bin/env bash
# Board LAN Hub - v3.0 (安全优化版+密码持久化+增强转发)
# 修改版：带别名/分组/自然排序/批量转发/批量WiFi/单个&批量卡号/详情弹窗 UI
# 新增：增强版批量转发配置，支持12种转发方式
# 优化：安全卸载、错误处理、密码安全、服务健康检查、密码持久化、IPv6支持
set -euo pipefail

RED='\u001B[0;31m'
GREEN='\u001B[0;32m'
YELLOW='\u001B[1;33m'
BLUE='\u001B[0;34m'
PURPLE='\u001B[0;35m'
CYAN='\u001B[0;36m'
NC='\u001B[0m'

log_info(){ echo -e "${GREEN}[✓]${NC} $*"; }
log_warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
log_err(){ echo -e "${RED}[✗]${NC} $*"; }
log_step(){ echo -e "${BLUE}[→]${NC} $*"; }
title(){ echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${CYAN}$*${NC}
${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

APPDIR="/opt/board-manager"
APIPORT=8000
SCANUSER="admin"
SCANPASS="admin"
UIPASS="admin"
CIDR=""

SERVICEAPI4="/etc/systemd/system/board-manager-v4.service"
SERVICEAPI6="/etc/systemd/system/board-manager-v6.service"
CONFIG_FILE="/etc/board-manager.conf"
BACKUP_DIR="/var/backups/board-manager"

need_root(){
  if [[ $EUID -ne 0 ]]; then
    log_err "需要root权限，请使用 sudo 运行"
    exit 1
  fi
}

safe_delete(){
  local target="$1"
  local safe_dirs=("/" "/bin" "/sbin" "/usr" "/etc" "/lib" "/lib64" "/var" "/home" "/root" "/boot" "/dev" "/proc" "/sys" "/tmp")
  
  for dir in "${safe_dirs[@]}"; do
    if [[ "${target}" == "$dir" || "${target}" == "$dir/"* ]]; then
      log_err "安全拒绝：拒绝删除系统目录 '$target'"
      return 1
    fi
  done
  
  # 检查是否为空（防止意外删除）
  if [[ -z "${target}" || "${target}" == "/"* ]]; then
    log_err "目录为空或格式错误: '$target'"
    return 1
  fi
  
  # 交互式确认
  read -p "确认删除目录 '$target' 及其所有内容？(输入 'DELETE' 确认): " confirm
  if [[ "$confirm" != "DELETE" ]]; then
    log_info "取消删除"
    return 0
  fi
  
  if [[ -d "$target" ]]; then
    log_step "删除目录: $target"
    rm -rf "$target"
    return 0
  fi
  return 0
}

detect_os(){
  if [[ -z "${OS_FAMILY:-}" ]]; then
    if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      case "${ID:-}" in
        ubuntu|debian) OS_FAMILY="debian"; PKG="apt-get" ;;
        centos|rhel|fedora|rocky|almalinux) OS_FAMILY="redhat"; PKG="$(command -v dnf || command -v yum || true)" ;;
        *) OS_FAMILY="debian"; PKG="apt-get" ;;
      esac
    else
      OS_FAMILY="debian"; PKG="apt-get"
    fi
  fi
}

cleanup_temp(){
  rm -f /tmp/board_mgr_task.log 2>/dev/null || true
  rm -f /tmp/pip_up.log /tmp/pip_ins.log 2>/dev/null || true
  rm -f /tmp/board_mgr_*.log 2>/dev/null || true
}

run_task(){
  local desc="$1"; shift
  local start_ts end_ts
  start_ts=$(date +%s)

  echo -ne "${BLUE}[⌛]${NC} ${desc} "
  set +e
  cleanup_temp
  ("$@") >/tmp/board_mgr_task.log 2>&1 &
  local pid=$!
  local spin='-|/'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    echo -ne "\b${spin:$i:1}"
    sleep 0.12
  done
  wait "$pid"
  local rc=$?
  set -e

  end_ts=$(date +%s)
  local cost=$((end_ts - start_ts))
  if [[ $rc -eq 0 ]]; then
    echo -e "\b ${GREEN}完成${NC} (${cost}s)"
  else
    echo -e "\b ${RED}失败${NC} (${cost}s)"
    tail -n 120 /tmp/board_mgr_task.log >&2 || true
    return $rc
  fi
}

help(){
  cat <<EOF
============================================================
Board LAN Hub - v3.0 (安全优化版+密码持久化+增强转发)
============================================================
用法: $0 <命令> [选项]

命令:
  install              安装系统（UI+API 同端口）
  scan                 触发扫描并添加设备
  status               查看后端服务状态
  restart              重启后端服务
  logs                 查看服务日志
  uninstall            卸载系统（安全模式）
  uninstall --force    强制卸载（跳过确认）
  backup               备份数据
  restore              恢复数据
  set-ui-pass          修改 UI 登录密码
  set-port             修改服务端口
  help                 显示此帮助

选项:
  --dir <路径>         安装目录 (默认: /opt/board-manager)
  --api-port <端口>    后端端口 (默认: 8000)
  --user <用户名>      设备登录用户名 (默认: admin)
  --pass <密码>        设备登录密码 (默认: admin)
  --cidr <网段>        指定扫描网段 (例如: 192.168.1.0/24)
============================================================
EOF
  exit 0
}

get_local_ip(){
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' 2>/dev/null || true)
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  echo "$ip"
}

auto_detect_cidr(){
  local local_ip subnet suggested_cidr confirm custom_cidr
  local_ip=$(get_local_ip)
  if [[ -z "$local_ip" ]]; then
    log_warn "无法自动检测内网IP，使用默认值 192.168.1.0/24"
    echo "192.168.1.0/24"
    return
  fi
  subnet=$(echo "$local_ip" | cut -d. -f1-3)
  suggested_cidr="${subnet}.0/24"
  log_info "检测到本机IP: ${GREEN}${local_ip}${NC}"
  log_info "建议的内网段: ${GREEN}${suggested_cidr}${NC}"
  echo ""
  read -p "是否使用此内网段进行扫描？(Y/n): " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    read -p "请输入自定义内网段 (例如: 192.168.1.0/24): " custom_cidr
    if [[ -n "$custom_cidr" ]]; then echo "$custom_cidr"; else echo "$suggested_cidr"; fi
  else
    echo "$suggested_cidr"
  fi
}

check_port(){
  local port="$1"
  log_step "检查端口 ${port} ..."
  
  # 检查IPv4
  if ss -ltn 2>/dev/null | grep -q ":${port} "; then
    log_err "端口 ${port} 已被占用！"
    ss -ltnp 2>/dev/null | grep ":${port} " || true
    return 1
  fi
  
  # 检查IPv6（修复第一版的问题）
  if ss -ltn 2>/dev/null | grep -q "\\[[0-9a-f:]*\\]:${port} "; then
    log_err "端口 ${port} (IPv6) 已被占用！"
    ss -ltnp 2>/dev/null | grep "\\[[0-9a-f:]*\\]:${port} " || true
    return 1
  fi
  
  return 0
}

install_deps(){
  title "安装/检查系统依赖"
  detect_os
  
  if ! command -v curl >/dev/null 2>&1; then
    run_task "安装 curl" bash -lc "apt-get install -y curl 2>/dev/null || yum install -y curl 2>/dev/null || true"
  fi
  
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    run_task "apt-get update" bash -lc "apt-get update -y -qq" || true
    run_task "安装系统依赖" bash -lc "apt-get install -y -qq git ca-certificates python3 python3-pip python3-venv sqlite3 iproute2 net-tools" || {
      log_err "依赖安装失败，请检查网络连接"
      return 1
    }
  else
    run_task "安装系统依赖" bash -lc "$PKG install -y -q git ca-certificates python3 python3-pip sqlite iproute net-tools" || {
      log_err "依赖安装失败，请检查网络连接"
      return 1
    }
  fi
  
  # 检查关键命令
  for cmd in python3 sqlite3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_err "必需命令 $cmd 未安装"
      return 1
    fi
  done
  
  log_info "系统依赖 OK"
}

install_node(){
  title "安装/检查 Node.js"
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    local node_ver npm_ver
    node_ver=$(node -v 2>/dev/null || echo "未知")
    npm_ver=$(npm -v 2>/dev/null || echo "未知")
    log_info "已存在 node=${node_ver} npm=${npm_ver}"
    return 0
  fi
  
  detect_os
  if [[ "$OS_FAMILY" == "debian" ]]; then
    run_task "安装 Node.js 20.x 源" bash -lc "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
    run_task "安装 nodejs" bash -lc "apt-get install -y -qq nodejs" || {
      log_err "Node.js 安装失败"
      return 1
    }
  else
    run_task "安装 Node.js 20.x 源" bash -lc "curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -"
    run_task "安装 nodejs" bash -lc "$PKG install -y -q nodejs" || {
      log_err "Node.js 安装失败"
      return 1
    }
  fi
  
  if ! command -v node >/dev/null 2>&1; then
    log_err "Node.js 安装后未找到"
    return 1
  fi
  
  log_info "Node OK：node=$(node -v) npm=$(npm -v)"
}

ensure_dirs(){
  title "准备目录"
  mkdir -p "${APPDIR}/app" "${APPDIR}/frontend/src" "${APPDIR}/data" "${APPDIR}/static" "${APPDIR}/bak"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  mkdir -p "$BACKUP_DIR"
  log_info "目录 OK：${APPDIR}"
}

pip_install_with_mirrors(){
  local pip="$1"; shift
  local -a mirrors=(
    "https://pypi.tuna.tsinghua.edu.cn/simple"
    "https://mirrors.aliyun.com/pypi/simple"
    "https://pypi.doubanio.com/simple"
    "https://pypi.org/simple"
  )
  local rc=1
  for m in "${mirrors[@]}"; do
    local host
    host=$(echo "$m" | sed 's|https://||' | cut -d/ -f1)
    log_step "pip 源：$host"
    set +e
    "$pip" -q install --upgrade pip -i "$m" --trusted-host "$host" >/tmp/pip_up.log 2>&1
    "$pip" -q install "$@" -i "$m" --trusted-host "$host" >/tmp/pip_ins.log 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
  done
  
  # 最后尝试不使用镜像
  log_step "尝试默认pip源..."
  "$pip" -q install "$@" >/tmp/pip_ins.log 2>&1 && return 0
  
  tail -n 120 /tmp/pip_ins.log >&2 || true
  return 1
}

write_backend(){
  title "部署后端（FastAPI + SQLite + Static UI）端口: ${APIPORT}"
  local venv="${APPDIR}/venv"

  if [[ ! -d "$venv" ]]; then
    run_task "创建 venv" bash -lc "python3 -m venv '$venv'"
  fi

  if [[ ! -f "$venv/bin/python" ]]; then
    log_err "Python虚拟环境创建失败"
    return 1
  fi

  run_task "pip 安装依赖" bash -lc " \
    $(declare -f pip_install_with_mirrors); \
    pip_install_with_mirrors '$venv/bin/pip' fastapi 'uvicorn[standard]' requests \
  "

  # 创建配置文件
  cat > "$CONFIG_FILE" <<EOF
# Board Manager 配置文件
APPDIR="${APPDIR}"
APIPORT="${APIPORT}"
SCANUSER="${SCANUSER}"
SCANPASS="${SCANPASS}"
UIPASS="${UIPASS}"
INSTALL_DATE="$(date +%Y-%m-%d)"
EOF

  # 后端代码 - 增强版
  cat > "${APPDIR}/app/main.py" <<'PY'
import asyncio
import json
import os
import re
import sqlite3
import subprocess
from ipaddress import ip_address, ip_network, IPv4Network
from typing import Any, Dict, List, Optional, Tuple

import requests
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import base64

DBPATH = os.environ.get("BMDB", "/opt/board-manager/data/data.db")
STATICDIR = os.environ.get("BMSTATIC", "/opt/board-manager/static")
DEFAULTUSER = os.environ.get("BMDEVUSER", "admin")
DEFAULTPASS = os.environ.get("BMDEVPASS", "admin")

TIMEOUT = float(os.environ.get("BMHTTPTIMEOUT", "2.5"))
CONCURRENCY = int(os.environ.get("BMSCANCONCURRENCY", "96"))
CIDRFALLBACKLIMIT = int(os.environ.get("BMCIDRFALLBACKLIMIT", "1024"))

app = FastAPI(title="Board LAN Hub", version="3.1.0")

UIUSER = os.environ.get("BMUIUSER", "admin")
UIPASS = os.environ.get("BMUIPASS", "admin")

def _unauthorized() -> Response:
    return Response(status_code=401)

def _check_basic(auth: str) -> bool:
    try:
        if not auth or not auth.startswith("Basic "):
            return False
        raw = base64.b64decode(auth.split(" ", 1)[1]).decode("utf-8")
        user, pw = raw.split(":", 1)
        return (user == UIUSER) and (pw == UIPASS)
    except Exception:
        return False

@app.middleware("http")
async def basic_auth_mw(request: Request, call_next):
    if request.url.path.startswith('/static/'):
        return await call_next(request)
    if request.url.path == '/api/health':
        return await call_next(request)
    if request.url.path == '/' or request.url.path.startswith('/api/'):
        auth = request.headers.get('Authorization','')
        if not _check_basic(auth):
            if request.url.path == '/':
                return await call_next(request)
            return _unauthorized()
    return await call_next(request)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs(STATICDIR, exist_ok=True)
app.mount("/static", StaticFiles(directory=STATICDIR), name="static")

@app.get("/")
def uiindex():
  indexpath = os.path.join(STATICDIR, "index.html")
  if not os.path.exists(indexpath):
      raise HTTPException(status_code=404, detail="UI not built (missing static/index.html)")
  return FileResponse(indexpath)

def db() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DBPATH), exist_ok=True)
    con = sqlite3.connect(DBPATH)
    con.row_factory = sqlite3.Row
    return con

def hascolumn(con: sqlite3.Connection, table: str, col: str) -> bool:
    cur = con.cursor()
    cur.execute(f"PRAGMA table_info({table})")
    cols = [r[1] for r in cur.fetchall()]
    return col in cols

def initdb():
    con = db()
    cur = con.cursor()
    cur.execute("""
      CREATE TABLE IF NOT EXISTS devices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        devId TEXT,
        grp TEXT DEFAULT 'auto',
        ip TEXT NOT NULL,
        mac TEXT DEFAULT '',
        user TEXT DEFAULT '',
        pass TEXT DEFAULT '',
        status TEXT DEFAULT 'unknown',
        lastSeen INTEGER DEFAULT 0,
        sim1number TEXT DEFAULT '',
        sim1operator TEXT DEFAULT '',
        sim2number TEXT DEFAULT '',
        sim2operator TEXT DEFAULT '',
        created TEXT DEFAULT CURRENT_TIMESTAMP
      )
    """)
    if not hascolumn(con, "devices", "mac"):
        cur.execute("ALTER TABLE devices ADD COLUMN mac TEXT DEFAULT ''")
    if not hascolumn(con, "devices", "alias"):
        cur.execute("ALTER TABLE devices ADD COLUMN alias TEXT DEFAULT ''")
    cur.execute("CREATE UNIQUE INDEX IF NOT EXISTS idxdevicesip ON devices(ip)")
    cur.execute("CREATE INDEX IF NOT EXISTS idxdevicesmac ON devices(mac)")
    con.commit()
    con.close()

initdb()

def nowts() -> int:
    import time
    return int(time.time())

def sh(cmd: List[str]) -> str:
    return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()

def guessipv4cidr() -> str:
    try:
        r = sh(["bash", "-lc", "ip -4 route show default 2>/dev/null | head -n1"])
        m = re.search(r"dev\s+(\S+)", r)
        if m:
            iface = m.group(1)
            a = sh(["bash", "-lc", f"ip -4 addr show dev {iface} | awk '/inet /{{print $2; exit}}'"])
            if a:
                net = ip_network(a, strict=False)
                if isinstance(net, IPv4Network):
                    return str(net.network_address) + f"/{net.prefixlen}"
    except Exception:
        pass

    try:
        txt = sh(["bash", "-lc", "ip -o -4 addr show | awk '{print $2,$4}'"])
        for line in txt.splitlines():
            parts = line.strip().split()
            if len(parts) != 2:
                continue
            iface, cidr = parts[0], parts[1]
            if iface == "lo":
                continue
            net = ip_network(cidr, strict=False)
            if isinstance(net, IPv4Network):
                return str(net.network_address) + f"/{net.prefixlen}"
    except Exception:
        pass

    return "192.168.1.0/24"

def getarptable() -> Dict[str, str]:
    out: Dict[str, str] = {}
    try:
        with open("/proc/net/arp", "r") as f:
            lines = f.readlines()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 4:
                ip = parts[0].strip()
                mac = parts[3].strip().upper()
                if mac and mac != "00:00:00:00:00:00" and ":" in mac:
                    out[ip] = mac
    except Exception:
        pass

    try:
        txt = subprocess.check_output(["ip", "neigh", "show"], text=True, stderr=subprocess.DEVNULL)
        for line in txt.splitlines():
            parts = line.split()
            if len(parts) >= 5 and "lladdr" in parts:
                ip = parts[0].strip()
                mac = parts[parts.index("lladdr") + 1].strip().upper()
                if mac and mac != "00:00:00:00:00:00" and ":" in mac:
                    out[ip] = mac
    except Exception:
        pass

    return out

def istargetdevice(ip: str, user: str, pw: str) -> Tuple[bool, Optional[str]]:
    url = f"http://{ip}/mgr"
    try:
        r = requests.get(url, timeout=TIMEOUT, allow_redirects=False)
        if r.status_code != 401:
            return False, None
        h = r.headers.get("WWW-Authenticate", "")
        if "Digest" not in h:
            return False, None
        m = re.search(r'realm="([^"]+)"', h)
        realm = m.group(1) if m else None
        if realm != "asyncesp":
            return False, realm
        r2 = requests.get(url, timeout=TIMEOUT, auth=requests.auth.HTTPDigestAuth(user, pw))
        return (r2.status_code == 200), realm
    except Exception:
        return False, None

def getdevicedata(ip: str, user: str, pw: str) -> Optional[Dict[str, Any]]:
    url = f"http://{ip}/mgr?a=getHtmlData_index"
    keys = ["DEV_ID","DEV_VER","SIM1_PHNUM","SIM2_PHNUM","SIM1_OP","SIM2_OP"]
    payload = {"keys": keys}
    try:
        r = requests.post(
            url,
            timeout=TIMEOUT,
            auth=requests.auth.HTTPDigestAuth(user, pw),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data={"keys": json.dumps(payload, ensure_ascii=False)},
        )
        if r.status_code != 200:
            return None
        j = r.json()
        if isinstance(j, dict) and j.get("success") and isinstance(j.get("data"), dict):
            return j["data"]
        return None
    except Exception:
        return None

def upsertdevice(ip: str, mac: str, user: str, pw: str, grp: str = "auto") -> Dict[str, Any]:
    data = getdevicedata(ip, user, pw) or {}
    devid = (data.get("DEV_ID") or "").strip() or None
    sim1num = (data.get("SIM1_PHNUM") or "").strip()
    sim2num = (data.get("SIM2_PHNUM") or "").strip()
    sim1op = (data.get("SIM1_OP") or "").strip()
    sim2op = (data.get("SIM2_OP") or "").strip()

    con = db()
    cur = con.cursor()

    mac = (mac or "").strip().upper()
    devicerow = None

    if mac:
        cur.execute("SELECT * FROM devices WHERE mac=? AND mac!='' LIMIT 1", (mac,))
        devicerow = cur.fetchone()
        if devicerow:
            cur.execute("""
              UPDATE devices SET
                ip=?,
                devId=COALESCE(?, devId),
                grp=?,
                mac=?,
                user=?,
                pass=?,
                status='online',
                lastSeen=?,
                sim1number=?,
                sim1operator=?,
                sim2number=?,
                sim2operator=?
              WHERE id=?
            """, (ip, devid, grp, mac, user, pw, nowts(), sim1num, sim1op, sim2num, sim2op, devicerow["id"]))

    if not devicerow:
        cur.execute("""
          INSERT INTO devices(devId, grp, ip, mac, user, pass, status, lastSeen, sim1number, sim1operator, sim2number, sim2operator)
          VALUES(?,?,?,?,?,?,'online',?,?,?,?,?)
          ON CONFLICT(ip) DO UPDATE SET
            devId=COALESCE(excluded.devId, devices.devId),
            grp=excluded.grp,
            mac=CASE WHEN excluded.mac!='' THEN excluded.mac ELSE devices.mac END,
            user=excluded.user,
            pass=excluded.pass,
            status='online',
            lastSeen=excluded.lastSeen,
            sim1number=excluded.sim1number,
            sim1operator=excluded.sim1operator,
            sim2number=excluded.sim2number,
            sim2operator=excluded.sim2operator
        """, (devid, grp, ip, mac, user, pw, nowts(), sim1num, sim1op, sim2num, sim2op))

    con.commit()
    cur.execute("SELECT * FROM devices WHERE ip=? LIMIT 1", (ip,))
    out = dict(cur.fetchone())
    con.close()
    return out

def listdevices():
    con = db()
    cur = con.cursor()
    cur.execute("SELECT * FROM devices ORDER BY created DESC, id DESC")
    rows = [dict(r) for r in cur.fetchall()]
    con.close()
    out = []
    for r in rows:
        out.append({
          "id": r["id"],
          "devId": r["devId"] or "",
          "alias": r.get("alias") or "",
          "grp": r.get("grp") or "auto",
          "ip": r["ip"],
          "mac": r.get("mac") or "",
          "status": r["status"] or "unknown",
          "lastSeen": r["lastSeen"] or 0,
          "created": r["created"] or "",
          "sims": {
            "sim1": {"number": r["sim1number"] or "", "operator": r["sim1operator"] or "", "label": (r["sim1number"] or r["sim1operator"] or "SIM")},
            "sim2": {"number": r["sim2number"] or "", "operator": r["sim2operator"] or "", "label": (r["sim2number"] or r["sim2operator"] or "SIM")},
          }
        })
    return out

def getallnumbers():
    con = db()
    cur = con.cursor()
    cur.execute("SELECT id, devId, ip, sim1number, sim1operator, sim2number, sim2operator FROM devices")
    rows = [dict(r) for r in cur.fetchall()]
    con.close()

    numbers = []
    for r in rows:
      if r["sim1number"] and r["sim1number"].strip():
        numbers.append({
          "deviceId": r["id"],
          "deviceName": r["devId"] or r["ip"],
          "ip": r["ip"],
          "number": r["sim1number"].strip(),
          "operator": r["sim1operator"] or "",
          "slot": 1
        })
      if r["sim2number"] and r["sim2number"].strip():
        numbers.append({
          "deviceId": r["id"],
          "deviceName": r["devId"] or r["ip"],
          "ip": r["ip"],
          "number": r["sim2number"].strip(),
          "operator": r["sim2operator"] or "",
          "slot": 2
        })
    return numbers

class DirectSmsReq(BaseModel):
    deviceId: int
    phone: str
    content: str
    slot: int

@app.get("/api/health")
def health():
    return {"status":"ok", "message":"Board LAN Hub API is running"}

# ===== 设备别名/分组 =====
class AliasReq(BaseModel):
    alias: str

@app.post("/api/devices/{devid}/alias")
def api_set_alias(devid: int, req: AliasReq):
    alias = (req.alias or "").strip()
    if len(alias) > 24:
        raise HTTPException(400, "alias too long")
    con = db(); cur = con.cursor()
    cur.execute("UPDATE devices SET alias=? WHERE id=?", (alias, devid))
    con.commit(); ok = cur.rowcount
    con.close()
    if ok == 0:
        raise HTTPException(404, "Device not found")
    return {"ok": True}

class GroupReq(BaseModel):
    group: str

@app.post("/api/devices/{devid}/group")
def api_set_group(devid: int, req: GroupReq):
    group = (req.group or "").strip() or "auto"
    con = db(); cur = con.cursor()
    cur.execute("UPDATE devices SET grp=? WHERE id=?", (group, devid))
    con.commit(); ok = cur.rowcount
    con.close()
    if ok == 0:
        raise HTTPException(404, "Device not found")
    return {"ok": True}

# ===== 增强版批量转发 =====
class EnhancedBatchForwardReq(BaseModel):
    device_ids: List[int]
    forward_method: str
    forwardUrl: str = ""
    notifyUrl: str = ""
    deviceKey0: str = ""
    deviceKey1: str = ""
    deviceKey2: str = ""
    smtpProvider: str = ""
    smtpServer: str = ""
    smtpPort: str = ""
    smtpAccount: str = ""
    smtpPassword: str = ""
    smtpFromEmail: str = ""
    smtpToEmail: str = ""
    smtpEncryption: str = ""
    webhookUrl1: str = ""
    webhookUrl2: str = ""
    webhookUrl3: str = ""
    signKey1: str = ""
    signKey2: str = ""
    signKey3: str = ""
    sc3ApiUrl: str = ""
    sctSendKey: str = ""
    PPToken: str = ""
    PPChannel: str = ""
    PPWebhook: str = ""
    PPFriends: str = ""
    PPGroupId: str = ""
    WPappToken: str = ""
    WPUID: str = ""
    WPTopicId: str = ""
    lyApiUrl: str = ""

@app.post("/api/devices/batch/enhanced-forward")
def api_enhanced_batch_forward(req: EnhancedBatchForwardReq):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    
    con = db()
    cur = con.cursor()
    ph = ','.join('?' * len(req.device_ids))
    cur.execute(f"SELECT id, ip, user, pass FROM devices WHERE id IN ({ph})", req.device_ids)
    devs = [dict(r) for r in cur.fetchall()]
    con.close()
    
    results = []
    
    for d in devs:
        ip = d['ip']
        user = (d.get('user') or DEFAULTUSER).strip()
        pw = (d.get('pass') or DEFAULTPASS).strip()
        
        try:
            # 检查设备是否可达
            ok, _ = istargetdevice(ip, user, pw)
            if not ok:
                results.append({"id": d['id'], "ip": ip, "ok": False, "error": "auth failed"})
                continue
            
            # 根据转发方式构建不同的请求数据
            form_data = {"method": req.forward_method}
            
            if req.forward_method == "0":
                # 不使用快捷配置
                form_data.update({})
            elif req.forward_method in ["1", "2"]:  # Bark
                form_data.update({
                    "BARK_DEVICE_KEY0": req.deviceKey0,
                    "BARK_DEVICE_KEY1": req.deviceKey1,
                    "BARK_DEVICE_KEY2": req.deviceKey2
                })
            elif req.forward_method == "8":  # SMTP
                form_data.update({
                    "SMTP_PROVIDER": req.smtpProvider,
                    "SMTP_SERVER": req.smtpServer,
                    "SMTP_PORT": req.smtpPort,
                    "SMTP_ACCOUNT": req.smtpAccount,
                    "SMTP_PASSWORD": req.smtpPassword,
                    "SMTP_FROM_EMAIL": req.smtpFromEmail,
                    "SMTP_TO_EMAIL": req.smtpToEmail,
                    "SMTP_ENCRYPTION": req.smtpEncryption
                })
            elif req.forward_method in ["10", "11", "16"]:  # 企业微信/飞书
                form_data.update({
                    "WDF_CWH_URL1": req.webhookUrl1,
                    "WDF_CWH_URL2": req.webhookUrl2,
                    "WDF_CWH_URL3": req.webhookUrl3
                })
            elif req.forward_method == "13":  # 钉钉
                form_data.update({
                    "WDF_CWH_URL1": req.webhookUrl1,
                    "WDF_CWH_URL2": req.webhookUrl2,
                    "WDF_CWH_URL3": req.webhookUrl3,
                    "WDF_SIGN_KEY1": req.signKey1,
                    "WDF_SIGN_KEY2": req.signKey2,
                    "WDF_SIGN_KEY3": req.signKey3
                })
            elif req.forward_method == "22":  # Server酱3
                form_data.update({
                    "SC3_URL": req.sc3ApiUrl
                })
            elif req.forward_method == "21":  # Server酱Turbo
                form_data.update({
                    "SCT_SEND_KEY": req.sctSendKey
                })
            elif req.forward_method == "30":  # PushPlus
                form_data.update({
                    "PPToken": req.PPToken,
                    "PPChannel": req.PPChannel,
                    "PPWebhook": req.PPWebhook,
                    "PPFriends": req.PPFriends,
                    "PPGroupId": req.PPGroupId
                })
            elif req.forward_method == "35":  # WxPusher
                form_data.update({
                    "WPappToken": req.WPappToken,
                    "WPUID": req.WPUID,
                    "WPTopicId": req.WPTopicId
                })
            elif req.forward_method == "90":  # 绿微平台
                form_data.update({
                    "LYWEB_API_URL": req.lyApiUrl
                })
            else:
                # 通用URL方式（保持向后兼容）
                form_data.update({
                    "forwardUrl": req.forwardUrl,
                    "notifyUrl": req.notifyUrl
                })
            
            # 发送配置请求
            resp = requests.post(
                f"http://{ip}/saveForwardConfig",
                data=form_data,
                timeout=TIMEOUT + 5,
                auth=requests.auth.HTTPDigestAuth(user, pw)
            )
            
            results.append({
                "id": d['id'], 
                "ip": ip, 
                "ok": resp.status_code == 200, 
                "status": resp.status_code
            })
            
        except Exception as e:
            results.append({
                "id": d['id'], 
                "ip": ip, 
                "ok": False, 
                "error": str(e)
            })
    
    return {"results": results}

# ===== 保持原有批量转发接口（兼容旧版） =====
class BatchForwardReq(BaseModel):
    device_ids: List[int]
    forwardUrl: str
    notifyUrl: str

@app.post("/api/devices/batch/forward")
def api_batch_forward(req: BatchForwardReq):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    con = db(); cur = con.cursor()
    ph = ','.join('?'*len(req.device_ids))
    cur.execute(f"SELECT id, ip, user, pass FROM devices WHERE id IN ({ph})", req.device_ids)
    devs = [dict(r) for r in cur.fetchall()]
    con.close()
    results=[]
    for d in devs:
        ip=d['ip']
        user=(d.get('user') or DEFAULTUSER).strip()
        pw=(d.get('pass') or DEFAULTPASS).strip()
        try:
            ok,_=istargetdevice(ip,user,pw)
            if not ok:
                results.append({"id":d['id'],"ip":ip,"ok":False,"error":"auth failed"})
                continue
            resp=requests.post(f"http://{ip}/mgr", params={"a":"saveForwardConfig"},
                               data={"forwardUrl": req.forwardUrl, "notifyUrl": req.notifyUrl},
                               timeout=TIMEOUT+5, auth=requests.auth.HTTPDigestAuth(user,pw))
            results.append({"id":d['id'],"ip":ip,"ok":resp.status_code==200, "status":resp.status_code})
        except Exception as e:
            results.append({"id":d['id'],"ip":ip,"ok":False,"error":str(e)})
    return {"results":results}

# ===== 批量 WiFi =====
class BatchWifiReq(BaseModel):
    device_ids: List[int]
    ssid: str
    pwd: str

@app.post("/api/devices/batch/wifi")
def api_batch_wifi(req: BatchWifiReq):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    con=db(); cur=con.cursor()
    ph=','.join('?'*len(req.device_ids))
    cur.execute(f"SELECT id, ip, user, pass FROM devices WHERE id IN ({ph})", req.device_ids)
    devs=[dict(r) for r in cur.fetchall()]
    con.close()
    results=[]
    for d in devs:
        ip=d['ip']
        user=(d.get('user') or DEFAULTUSER).strip()
        pw=(d.get('pass') or DEFAULTPASS).strip()
        try:
            ok,_=istargetdevice(ip,user,pw)
            if not ok:
                results.append({"id":d['id'],"ip":ip,"ok":False,"error":"auth failed"})
                continue
            resp=requests.get(f"http://{ip}/ap", params={"a":"apadd","ssid":req.ssid,"pwd":req.pwd},
                              timeout=TIMEOUT+5, auth=requests.auth.HTTPDigestAuth(user,pw))
            results.append({"id":d['id'],"ip":ip,"ok":resp.status_code==200, "status":resp.status_code})
        except Exception as e:
            results.append({"id":d['id'],"ip":ip,"ok":False,"error":str(e)})
    return {"results":results}

# ===== SIM 单台/批量 =====
class SimReq(BaseModel):
    sim1: str = ''
    sim2: str = ''

@app.post("/api/devices/{devid}/sim")
def api_set_sim(devid: int, req: SimReq):
    con=db(); cur=con.cursor()
    cur.execute("SELECT ip, user, pass FROM devices WHERE id=?", (devid,))
    r=cur.fetchone()
    if not r:
        con.close()
        raise HTTPException(404, "Device not found")
    ip=r['ip']; user=(r['user'] or DEFAULTUSER).strip(); pw=(r['pass'] or DEFAULTPASS).strip()
    con.close()
    resp=requests.post(f"http://{ip}/mgr", params={"a":"updatePhnum"},
                       data={"sim1Phnum": req.sim1, "sim2Phnum": req.sim2},
                       timeout=TIMEOUT+5, auth=requests.auth.HTTPDigestAuth(user,pw))
    if resp.status_code==200:
        con2=db(); cur2=con2.cursor()
        cur2.execute("UPDATE devices SET sim1number=?, sim2number=? WHERE id=?", (req.sim1, req.sim2, devid))
        con2.commit(); con2.close()
        return {"ok": True}
    return {"ok": False, "status": resp.status_code}

class BatchSimReq(BaseModel):
    device_ids: List[int]
    sim1: str = ''
    sim2: str = ''

@app.post("/api/devices/batch/sim")
def api_batch_sim(req: BatchSimReq):
    if not req.device_ids:
        raise HTTPException(400, "device_ids required")
    con=db(); cur=con.cursor()
    ph=','.join('?'*len(req.device_ids))
    cur.execute(f"SELECT id, ip, user, pass FROM devices WHERE id IN ({ph})", req.device_ids)
    devs=[dict(r) for r in cur.fetchall()]
    con.close()
    results=[]
    for d in devs:
        ip=d['ip']; user=(d.get('user') or DEFAULTUSER).strip(); pw=(d.get('pass') or DEFAULTPASS).strip()
        try:
            ok,_=istargetdevice(ip,user,pw)
            if not ok:
                results.append({"id":d['id'],"ip":ip,"ok":False,"error":"auth failed"})
                continue
            resp=requests.post(f"http://{ip}/mgr", params={"a":"updatePhnum"},
                               data={"sim1Phnum": req.sim1, "sim2Phnum": req.sim2},
                               timeout=TIMEOUT+5, auth=requests.auth.HTTPDigestAuth(user,pw))
            if resp.status_code==200:
                con2=db(); cur2=con2.cursor()
                cur2.execute("UPDATE devices SET sim1number=?, sim2number=? WHERE id=?", (req.sim1, req.sim2, d['id']))
                con2.commit(); con2.close()
            results.append({"id":d['id'],"ip":ip,"ok":resp.status_code==200, "status":resp.status_code})
        except Exception as e:
            results.append({"id":d['id'],"ip":ip,"ok":False,"error":str(e)})
    return {"results":results}

@app.get("/api/devices/{devid}/detail")
def api_device_detail(devid: int):
    con=db(); cur=con.cursor()
    cur.execute("SELECT * FROM devices WHERE id=?", (devid,))
    r=cur.fetchone()
    con.close()
    if not r:
        raise HTTPException(404, "Device not found")
    device=dict(r)
    # forward_config / wifi_list 目前仍是占位，前端已预留展示
    return {"device":device, "forwardconfig":{}, "wifilist":[]}

@app.get("/api/devices")
def apidevices():
    return listdevices()

@app.get("/api/numbers")
def apinumbers():
    return getallnumbers()

@app.delete("/api/devices/{dev_id}")
def deletedevice(dev_id: int):
    con = db()
    cur = con.cursor()
    cur.execute("DELETE FROM devices WHERE id=?", (dev_id,))
    con.commit()
    affected = cur.rowcount
    con.close()
    if affected == 0:
        raise HTTPException(404, "Device not found")
    return {"ok": True, "message": "Device deleted"}

@app.post("/api/sms/send-direct")
def smssenddirect(req: DirectSmsReq):
    if req.slot not in (1, 2):
        raise HTTPException(400, "slot must be 1 or 2")
    phone = req.phone.strip()
    content = req.content.strip()
    if not phone or not content:
        raise HTTPException(400, "phone/content required")

    con = db()
    cur = con.cursor()
    cur.execute("SELECT * FROM devices WHERE id=?", (req.deviceId,))
    r = cur.fetchone()
    con.close()
    if not r:
        raise HTTPException(404, "Device not found")

    ip = r["ip"]
    user = (r["user"] or DEFAULTUSER).strip()
    pw = (r["pass"] or DEFAULTPASS).strip()

    ok, _ = istargetdevice(ip, user, pw)
    if not ok:
        raise HTTPException(400, "Device authentication failed")

    url = f"http://{ip}/mgr"
    params = {"a": "sendsms", "sid": str(req.slot), "phone": phone, "content": content}
    try:
        resp = requests.get(url, params=params, timeout=TIMEOUT + 3, auth=requests.auth.HTTPDigestAuth(user, pw))
        if resp.status_code == 200:
            try:
                j = resp.json()
                if isinstance(j, dict) and j.get("success") is True:
                    return {"ok": True, "message": "SMS sent successfully"}
                return {"ok": False, "error": f"device response: {j}"}
            except Exception:
                return {"ok": False, "error": "non-json response"}
        return {"ok": False, "error": f"http {resp.status_code}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}

@app.post("/api/scan/start")
def scanstart(cidr: Optional[str] = None, group: str = "auto", user: str = DEFAULTUSER, password: str = DEFAULTPASS):
    if not cidr:
        cidr = guessipv4cidr()

    try:
        net = ip_network(cidr, strict=False)
        if not isinstance(net, IPv4Network):
            raise ValueError("only IPv4 supported scan")
    except Exception as e:
        raise HTTPException(400, f"bad cidr: {e}")

    arptable = getarptable()

    iplist: List[str] = []
    if arptable:
        for ip in arptable.keys():
            try:
                if ip_address(ip) in net:
                    iplist.append(ip)
            except Exception:
                continue

    if not iplist:
        iplist = [str(h) for h in net.hosts()]

    if len(iplist) > CIDRFALLBACKLIMIT:
        iplist = iplist[:CIDRFALLBACKLIMIT]

    sem = asyncio.Semaphore(CONCURRENCY)
    found: List[Dict[str, Any]] = []

    async def probe(ip: str):
        async with sem:
            loop = asyncio.get_event_loop()
            ok, _ = await loop.run_in_executor(None, istargetdevice, ip, user, password)
            if ok:
                mac = arptable.get(ip, "")
                d = await loop.run_in_executor(None, upsertdevice, ip, mac, user, password, group)
                found.append(d)

    async def run():
        await asyncio.gather(*(probe(ip) for ip in iplist))

    asyncio.run(run())
    return {"ok": True, "cidr": cidr, "found": len(found), "devices": [{"ip": d["ip"], "devId": d.get("devId", "")} for d in found]}
PY

  log_info "后端已写入"
  log_info "配置文件已创建: $CONFIG_FILE"
}

writefrontendstatic(){
  title "部署前端（v3.0 + 密码持久化 + 增强转发）"
  local FE="${APPDIR}/frontend"
  mkdir -p "${FE}/src"

  cat > "${FE}/package.json" <<'PKG'
{
  "name": "board-lan-ui",
  "version": "3.1.0",
  "private": true,
  "type": "module",
  "scripts": { "build": "vite build" },
  "dependencies": { "axios": "^1.6.0", "vue": "^3.4.0" },
  "devDependencies": { "@vitejs/plugin-vue": "^5.0.0", "vite": "^5.4.11" }
}
PKG

  cat > "${FE}/vite.config.js" <<VITECFG
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
export default defineConfig({
  plugins: [vue()],
  base: '/static/',
  build: { outDir: '${APPDIR}/static', emptyOutDir: true }
})
VITECFG

  cat > "${FE}/index.html" <<'HTML'
<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
    <meta name="theme-color" content="#0f172a" />
    <title>开发板管理系统</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.js"></script>
  </body>
</html>
HTML

  cat > "${FE}/src/main.js" <<'JS'
import { createApp } from 'vue'
import App from './App.vue'
createApp(App).mount('#app')
JS

  # 前端代码 - 增强版
  cat > "${FE}/src/App.vue" <<'VUE'
<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import axios from 'axios'

const api = axios.create({ baseURL: '' })

const uiPass = ref('')
const authed = ref(false)
const loading = ref(false)
const notice = ref({ text: '', type: 'info' })

function setNotice(text, type = 'info') {
  notice.value = { text, type }
}
function clearNotice() {
  notice.value = { text: '', type: 'info' }
}
function setAuth(pw) {
  const token = window.btoa(`admin:${pw}`)
  api.defaults.headers.common['Authorization'] = `Basic ${token}`
  // 保存到 localStorage
  localStorage.setItem('board_mgr_auth_token', token)
  localStorage.setItem('board_mgr_auth_time', Date.now().toString())
}
async function login() {
  if (!uiPass.value.trim()) return setNotice('请输入密码', 'err')
  setAuth(uiPass.value.trim())
  loading.value = true
  try {
    await api.get('/api/health')
    authed.value = true
    setNotice('登录成功', 'ok')
    await refresh()
  } catch (e) {
    authed.value = false
    setNotice(e?.response?.data?.detail || '密码错误或无权限', 'err')
  } finally {
    loading.value = false
  }
}
function logout() {
  authed.value = false
  uiPass.value = ''
  delete api.defaults.headers.common['Authorization']
  // 清除 localStorage
  localStorage.removeItem('board_mgr_auth_token')
  localStorage.removeItem('board_mgr_auth_time')
}

// 页面加载时检查是否有保存的token
onMounted(() => {
  const savedToken = localStorage.getItem('board_mgr_auth_token')
  const savedTime = localStorage.getItem('board_mgr_auth_time')
  
  // 如果token存在且是7天内保存的（604800000毫秒）
  if (savedToken && savedTime && (Date.now() - parseInt(savedTime) < 604800000)) {
    api.defaults.headers.common['Authorization'] = `Basic ${savedToken}`
    authed.value = true
    // 验证token是否有效
    api.get('/api/health').then(() => {
      refresh()
    }).catch(() => {
      // token无效，清除
      logout()
      setNotice('登录已过期，请重新登录', 'err')
    })
  }
})

const devices = ref([])
const numbers = ref([])

const activeTab = ref('devices')
const searchText = ref('')
const groupFilter = ref('all')

const fromSelected = ref('')
const toPhone = ref('')
const content = ref('')

const selectedIds = ref([])
const selectAll = ref(false)

const showForwardModal = ref(false)
const showEnhancedForwardModal = ref(false)
const showWifiModal = ref(false)
const showSimModal = ref(false)
const showDetailModal = ref(false)

const forwardUrl = ref('')
const notifyUrl = ref('')

// 增强转发配置
const forwardMethod = ref('0')
const enhancedForwardConfig = ref({
  deviceKey0: '',
  deviceKey1: '',
  deviceKey2: '',
  smtpProvider: '1',
  smtpServer: '',
  smtpPort: '',
  smtpAccount: '',
  smtpPassword: '',
  smtpFromEmail: '',
  smtpToEmail: '',
  smtpEncryption: 'starttls',
  webhookUrl1: '',
  webhookUrl2: '',
  webhookUrl3: '',
  signKey1: '',
  signKey2: '',
  signKey3: '',
  sc3ApiUrl: '',
  sctSendKey: '',
  PPToken: '',
  PPChannel: '',
  PPWebhook: '',
  PPFriends: '',
  PPGroupId: '',
  WPappToken: '',
  WPUID: '',
  WPTopicId: '',
  lyApiUrl: ''
})

const wifiSsid = ref('')
const wifiPwd = ref('')

const sim1Number = ref('')
const sim2Number = ref('')

const deviceDetail = ref(null)
const detailSavedWifi = computed(() => deviceDetail.value?.wifilist || [])

// SMTP配置映射
const smtpConfigs = {
  '1': { domain: '', server: 'smtp.163.com', port: '465' },
  '2': { domain: 'vip.163.com', server: 'smtp.vip.163.com', port: '465' },
  '3': { domain: '', server: 'smtp.ym.163.com', port: '465' },
  '10': { domain: '', server: 'smtp.qq.com', port: '465' },
  '11': { domain: '', server: 'smtp.exmail.qq.com', port: '465' },
  '20': { domain: 'aliyun.com', server: 'smtp.aliyun.com', port: '465' },
  '21': { domain: '', server: 'smtp.qiye.aliyun.com', port: '465' },
  '30': { domain: '139.com', server: 'smtp.139.com', port: '465' },
  '33': { domain: 'wo.com', server: 'smtp.wo.cn', port: '465' },
  '36': { domain: '189.cn', server: 'smtp.189.cn', port: '465' },
  '37': { domain: '21cn.com', server: 'smtp.21cn.com', port: '465' },
  '40': { domain: '', server: 'smtp.sina.com', port: '465' },
  '41': { domain: 'sohu.com', server: 'smtp.sohu.com', port: '465' },
  '42': { domain: '', server: 'smtp.zoho.com', port: '465' },
  '43': { domain: '', server: 'smtp.88.com', port: '465' },
  '50': { domain: '', server: 'smtp.office365.com', port: '587' },
  '51': { domain: 'yahoo.com', server: 'smtp.mail.yahoo.com', port: '465' },
  '52': { domain: 'icloud.com', server: 'smtp.mail.me.com', port: '465' },
  '53': { domain: 'gmail.com', server: 'smtp.gmail.com', port: '465' },
  '54': { domain: 'aol.com', server: 'smtp.aol.com', port: '465' },
  '55': { domain: 'yandex.com', server: 'smtp.yandex.com', port: '465' },
  '56': { domain: 'mail.ru', server: 'smtp.mail.ru', port: '465' },
  '999': { domain: '', server: '', port: '' }
}

// 监听SMTP提供商变化
watch(() => enhancedForwardConfig.value.smtpProvider, (newVal) => {
  const config = smtpConfigs[newVal]
  if (config && newVal !== '999') {
    enhancedForwardConfig.value.smtpServer = config.server
    enhancedForwardConfig.value.smtpPort = config.port
  }
})

function prettyTime(ts) {
  if (!ts) return '-'
  return new Date(ts * 1000).toLocaleString('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}
function displayName(d) {
  return (d?.alias || d?.devId || '').trim() || '-'
}
function splitAlphaNum(s) {
  const str = (s || '').trim()
  const m = str.match(/^([A-Za-z]*)(\d+)?$/)
  if (!m) return { a: str.toUpperCase(), n: null, raw: str.toUpperCase() }
  return { a: (m[1] || '').toUpperCase(), n: m[2] ? parseInt(m[2], 10) : null, raw: str.toUpperCase() }
}
function cmpNatural(a, b) {
  const A = splitAlphaNum(a)
  const B = splitAlphaNum(b)
  if (A.a !== B.a) return A.a < B.a ? -1 : 1
  if (A.n !== null && B.n !== null && A.n !== B.n) return A.n - B.n
  if (A.n === null && B.n !== null) return 1
  if (A.n !== null && B.n === null) return -1
  if (A.raw !== B.raw) return A.raw < B.raw ? -1 : 1
  return 0
}

const uniqueGroups = computed(() => {
  const g = new Set(devices.value.map(d => (d.grp || 'auto')))
  return ['all', ...Array.from(g).sort()]
})

const filteredDevices = computed(() => {
  const t = searchText.value.trim().toLowerCase()
  let arr = devices.value

  if (groupFilter.value !== 'all') {
    arr = arr.filter(d => (d.grp || 'auto') === groupFilter.value)
  }
  if (t) {
    arr = arr.filter(d =>
      displayName(d).toLowerCase().includes(t) ||
      (d.ip || '').toLowerCase().includes(t) ||
      (d.mac || '').toLowerCase().includes(t) ||
      (d.sims?.sim1?.number || '').includes(t) ||
      (d.sims?.sim2?.number || '').includes(t)
    )
  }
  return [...arr].sort((x, y) => cmpNatural(displayName(x), displayName(y)))
})

const filteredNumbers = computed(() => {
  const t = searchText.value.trim().toLowerCase()
  if (!t) return numbers.value
  return numbers.value.filter(n =>
    (n.number || '').includes(t) ||
    (n.deviceName || '').toLowerCase().includes(t) ||
    (n.ip || '').toLowerCase().includes(t) ||
    (n.operator || '').toLowerCase().includes(t)
  )
})

const onlineCount = computed(() => devices.value.filter(d => d.status === 'online').length)
const offlineCount = computed(() => devices.value.filter(d => d.status !== 'online').length)
const selectedCount = computed(() => selectedIds.value.length)

function toggleSelectAll() {
  selectedIds.value = selectAll.value ? filteredDevices.value.map(d => d.id) : []
}

async function loadDevices() {
  const { data } = await api.get('/api/devices')
  devices.value = Array.isArray(data) ? data : []
}
async function loadNumbers() {
  const { data } = await api.get('/api/numbers')
  numbers.value = Array.isArray(data) ? data : []
  if (!fromSelected.value && numbers.value.length) {
    const n = numbers.value[0]
    fromSelected.value = `${n.deviceId}|${n.slot}|${n.number}`
  }
}
async function refresh() {
  loading.value = true
  try {
    await loadDevices()
    await loadNumbers()
  } catch (e) {
    // 如果返回401，清除登录状态
    if (e?.response?.status === 401) {
      logout()
      setNotice('登录已过期，请重新登录', 'err')
    } else {
      setNotice(e?.response?.data?.detail || e.message, 'err')
    }
  } finally {
    loading.value = false
  }
}

async function startScanAdd() {
  loading.value = true
  setNotice('扫描中，请稍候...', 'info')
  try {
    const { data } = await api.post('/api/scan/start')
    setNotice(`扫描完成：found=${data.found} cidr=${data.cidr}`, 'ok')
    await refresh()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function send() {
  if (!fromSelected.value) return setNotice('请选择发送卡', 'err')
  if (!toPhone.value.trim()) return setNotice('请输入收件号码', 'err')
  if (!content.value.trim()) return setNotice('请输入短信内容', 'err')
  const [deviceId, slot] = fromSelected.value.split('|')

  loading.value = true
  try {
    const payload = { deviceId: Number(deviceId), slot: Number(slot), phone: toPhone.value.trim(), content: content.value.trim() }
    const { data } = await api.post('/api/sms/send-direct', payload)
    if (data.ok) setNotice('发送成功', 'ok')
    else setNotice(data.error || '发送失败', 'err')
  } catch (e) {
    setNotice(e?.response?.data?.error || e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function renameDevice(d) {
  const v = window.prompt('输入别名(最多24字符):', d.alias || '')
  if (v === null) return
  loading.value = true
  try {
    await api.post(`/api/devices/${d.id}/alias`, { alias: v.trim() })
    await refresh()
    setNotice('已更新别名', 'ok')
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}
async function setGroup(d) {
  const v = window.prompt('输入分组名:', d.grp || 'auto')
  if (v === null) return
  loading.value = true
  try {
    await api.post(`/api/devices/${d.id}/group`, { group: (v.trim() || 'auto') })
    await refresh()
    setNotice('已更新分组', 'ok')
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function deleteDevice(id) {
  if (!confirm('确认删除？')) return
  try {
    await api.delete(`/api/devices/${id}`)
    setNotice('已删除', 'ok')
    await refresh()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  }
}

// 旧版转发配置
function openForwardModal() {
  if (!selectedCount.value) return setNotice('请先勾选设备', 'err')
  showForwardModal.value = true
}
function closeForwardModal() {
  showForwardModal.value = false
  forwardUrl.value = ''
  notifyUrl.value = ''
}
async function applyForward() {
  loading.value = true
  try {
    const { data } = await api.post('/api/devices/batch/forward', {
      device_ids: selectedIds.value,
      forwardUrl: forwardUrl.value.trim(),
      notifyUrl: notifyUrl.value.trim(),
    })
    const ok = (data.results || []).filter(r => r.ok).length
    setNotice(`转发配置完成：${ok}/${(data.results || []).length}`, ok ? 'ok' : 'err')
    closeForwardModal()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

// 增强版转发配置
function openEnhancedForwardModal() {
  if (!selectedCount.value) return setNotice('请先勾选设备', 'err')
  showEnhancedForwardModal.value = true
}
function closeEnhancedForwardModal() {
  showEnhancedForwardModal.value = false
  forwardMethod.value = '0'
  // 重置配置
  Object.keys(enhancedForwardConfig.value).forEach(key => {
    enhancedForwardConfig.value[key] = ''
  })
  enhancedForwardConfig.value.smtpProvider = '1'
  enhancedForwardConfig.value.smtpEncryption = 'starttls'
}
async function applyEnhancedForward() {
  loading.value = true
  try {
    const payload = {
      device_ids: selectedIds.value,
      forward_method: forwardMethod.value,
      ...enhancedForwardConfig.value
    }
    
    const { data } = await api.post('/api/devices/batch/enhanced-forward', payload)
    const ok = (data.results || []).filter(r => r.ok).length
    setNotice(`转发配置完成：${ok}/${(data.results || []).length}`, ok ? 'ok' : 'err')
    closeEnhancedForwardModal()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

function openWifiModal() {
  if (!selectedCount.value) return setNotice('请先勾选设备', 'err')
  showWifiModal.value = true
}
function closeWifiModal() {
  showWifiModal.value = false
  wifiSsid.value = ''
  wifiPwd.value = ''
}
async function applyWifi() {
  if (!wifiSsid.value.trim()) return setNotice('请输入SSID', 'err')
  loading.value = true
  try {
    const { data } = await api.post('/api/devices/batch/wifi', {
      device_ids: selectedIds.value,
      ssid: wifiSsid.value.trim(),
      pwd: wifiPwd.value.trim(),
    })
    const ok = (data.results || []).filter(r => r.ok).length
    setNotice(`WiFi 添加完成：${ok}/${(data.results || []).length}`, ok ? 'ok' : 'err')
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

function openSimModal() {
  if (!selectedCount.value) return setNotice('请先勾选设备', 'err')
  showSimModal.value = true
}
function closeSimModal() {
  showSimModal.value = false
  sim1Number.value = ''
  sim2Number.value = ''
}
async function applySim() {
  loading.value = true
  try {
    const { data } = await api.post('/api/devices/batch/sim', {
      device_ids: selectedIds.value,
      sim1: sim1Number.value.trim(),
      sim2: sim2Number.value.trim(),
    })
    const ok = (data.results || []).filter(r => r.ok).length
    setNotice(`卡号批量更新：${ok}/${(data.results || []).length}`, ok ? 'ok' : 'err')
    await refresh()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}

async function showDetail(d) {
  loading.value = true
  try {
    const { data } = await api.get(`/api/devices/${d.id}/detail`)
    deviceDetail.value = data
    showDetailModal.value = true
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}
function closeDetailModal() {
  showDetailModal.value = false
  deviceDetail.value = null
}
async function saveSimSingle() {
  const id = deviceDetail.value?.device?.id
  if (!id) return
  loading.value = true
  try {
    await api.post(`/api/devices/${id}/sim`, {
      sim1: deviceDetail.value.device.sim1number || '',
      sim2: deviceDetail.value.device.sim2number || '',
    })
    setNotice('已保存卡号', 'ok')
    await refresh()
  } catch (e) {
    setNotice(e?.response?.data?.detail || e.message, 'err')
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="app">
    <div v-if="!authed" class="login-wrap">
      <div class="login-card">
        <div class="login-title">开发板管理系统</div>
        <div class="login-sub">请输入访问密码</div>
        <input v-model="uiPass" class="input" type="password" placeholder="密码" @keyup.enter="login" />
        <button class="btn btn-primary btn-block" :disabled="loading" @click="login">登录</button>

        <div v-if="notice.text" class="notice" :class="`notice-${notice.type}`" style="margin-top:10px">
          <div class="notice-text">{{ notice.text }}</div>
          <button class="notice-close" @click="clearNotice">×</button>
        </div>
      </div>
    </div>

    <div v-else>
      <div class="topbar">
        <div class="brand">
          <div class="logo">BM</div>
          <div class="brand-text">
            <div class="brand-title">Board LAN Hub</div>
            <div class="brand-sub">v3.1 + 增强转发</div>
          </div>
        </div>
        <div class="actions">
          <button class="btn btn-ghost" :disabled="loading" @click="refresh">刷新</button>
          <button class="btn btn-primary" :disabled="loading" @click="startScanAdd">扫描添加</button>
          <button class="btn btn-ghost" @click="logout">退出</button>
        </div>
      </div>

      <div v-if="notice.text" class="notice" :class="`notice-${notice.type}`">
        <div class="notice-text">{{ notice.text }}</div>
        <button class="notice-close" @click="clearNotice">×</button>
      </div>

      <div class="grid">
        <div class="kpi"><div class="kpi-label">在线</div><div class="kpi-value">{{ onlineCount }}</div></div>
        <div class="kpi"><div class="kpi-label">离线</div><div class="kpi-value">{{ offlineCount }}</div></div>
        <div class="kpi"><div class="kpi-label">设备</div><div class="kpi-value">{{ devices.length }}</div></div>
        <div class="kpi"><div class="kpi-label">号码</div><div class="kpi-value">{{ numbers.length }}</div></div>
      </div>

      <div class="card">
        <div class="card-title">短信发送</div>
        <div class="form">
          <div class="field">
            <label>发送卡</label>
            <select v-model="fromSelected" class="input">
              <option v-for="n in numbers" :key="`${n.deviceId}-${n.slot}`" :value="`${n.deviceId}|${n.slot}|${n.number}`">
                {{ n.number }}
              </option>
            </select>
          </div>
          <div class="field">
            <label>收件号码</label>
            <input v-model="toPhone" class="input" placeholder="输入手机号" />
          </div>
          <div class="field field-full">
            <label>内容</label>
            <textarea v-model="content" class="input textarea" rows="3" placeholder="输入短信内容"></textarea>
          </div>
          <div class="field field-full">
            <button class="btn btn-primary btn-block" :disabled="loading" @click="send">发送短信</button>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-title">设备 / 号码</div>

        <div class="tabs">
          <button class="tab" :class="{active: activeTab==='devices'}" @click="activeTab='devices'">设备</button>
          <button class="tab" :class="{active: activeTab==='numbers'}" @click="activeTab='numbers'">号码</button>
        </div>

        <div class="toolbar">
          <input v-model="searchText" class="input" placeholder="搜索（别名/DEV_ID/IP/MAC/号码）..." style="flex:1" />
          <select v-model="groupFilter" class="input" style="width:140px">
            <option value="all">全部分组</option>
            <option v-for="g in uniqueGroups.filter(x=>x!=='all')" :key="g" :value="g">{{ g }}</option>
          </select>
        </div>

        <div v-if="selectedCount>0 && activeTab==='devices'" class="batch-bar">
          <span class="batch-info">已选 {{ selectedCount }} 台</span>
          <button class="btn btn-ghost btn-sm" @click="openEnhancedForwardModal">配置转发</button>
          <button class="btn btn-ghost btn-sm" @click="openWifiModal">配置WiFi</button>
          <button class="btn btn-ghost btn-sm" @click="openSimModal">编辑卡号</button>
          <button class="btn btn-danger btn-sm" @click="selectedIds=[]; selectAll=false">取消</button>
        </div>

        <div v-if="activeTab==='devices'" class="table-wrap">
          <table class="table">
            <thead>
              <tr>
                <th><input type="checkbox" v-model="selectAll" @change="toggleSelectAll" class="ck"> 名称</th>
                <th>IP</th>
                <th>MAC</th>
                <th>状态</th>
                <th>最后在线</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              <tr v-if="filteredDevices.length===0">
                <td class="empty" colspan="6">暂无设备，点击"扫描添加"</td>
              </tr>
              <tr v-for="d in filteredDevices" :key="d.id">
                <td>
                  <input type="checkbox" v-model="selectedIds" :value="d.id" class="ck">
                  {{ displayName(d) }}
                  <span class="muted">（{{ d.grp || 'auto' }}）</span>
                </td>
                <td class="mono">{{ d.ip }}</td>
                <td class="mono">{{ d.mac || '-' }}</td>
                <td><span class="pill" :class="d.status==='online' ? 'pill-ok' : 'pill-bad'">{{ d.status==='online'?'在线':'离线' }}</span></td>
                <td class="mono">{{ prettyTime(d.lastSeen) }}</td>
                <td>
                  <button class="btn btn-ghost btn-sm" @click="showDetail(d)">详情</button>
                  <button class="btn btn-ghost btn-sm" @click="renameDevice(d)">改名</button>
                  <button class="btn btn-ghost btn-sm" @click="setGroup(d)">分组</button>
                  <button class="btn btn-danger btn-sm" @click="deleteDevice(d.id)">删除</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div v-if="activeTab==='numbers'" class="table-wrap">
          <table class="table">
            <thead>
              <tr><th>号码</th><th>卡槽</th><th>运营商</th><th>设备</th><th>IP</th></tr>
            </thead>
            <tbody>
              <tr v-if="filteredNumbers.length===0"><td class="empty" colspan="5">暂无号码（扫描后会自动获取）</td></tr>
              <tr v-for="n in filteredNumbers" :key="`${n.deviceId}-${n.slot}`">
                <td class="mono">{{ n.number }}</td>
                <td>SIM{{ n.slot }}</td>
                <td>{{ n.operator }}</td>
                <td>{{ n.deviceName }}</td>
                <td class="mono">{{ n.ip }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- 增强版转发配置模态框 -->
      <div v-if="showEnhancedForwardModal" class="modal" @click.self="closeEnhancedForwardModal">
        <div class="modal-content" style="max-width: 700px; max-height: 80vh; overflow-y: auto">
          <div class="modal-title">批量配置转发方式</div>
          
          <div class="field field-full">
            <label>转发方式：</label>
            <select v-model="forwardMethod" class="input">
              <option value="0">----- 不使用快捷配置 -----</option>
              <option value="1">转发至 Bark for iOS</option>
              <option value="8">转发至 邮箱(SMTP)</option>
              <option value="10">转发至 企业微信群Webhook</option>
              <option value="11">转发至 企业微信群Webhook （开启：来电接听＋录音上报）</option>
              <option value="13">转发至 钉钉群Webhook</option>
              <option value="16">转发至 飞书群Webhook</option>
              <option value="22">转发至 Server酱3</option>
              <option value="21">转发至 Server酱Turbo</option>
              <option value="30">转发至 PushPlus(推送加)</option>
              <option value="35">转发至 WxPusher</option>
              <option value="90">转发至 绿微平台普通WEB接口(v1)</option>
              <option value="custom">自定义URL（旧版）</option>
            </select>
          </div>
          
          <!-- Bark配置 -->
          <div v-if="forwardMethod === '1'" class="config-section">
            <div class="field field-full">
              <label>device_key(必填)：</label>
              <input v-model="enhancedForwardConfig.deviceKey0" class="input" placeholder="从bark中复制推送地址的device_key" />
              <div class="muted">从bark中复制推送地址，类似于：https://api.day.app/device_key/...</div>
            </div>
          </div>
          
          <!-- SMTP配置 -->
          <div v-if="forwardMethod === '8'" class="config-section">
            <div class="field field-full">
              <label>邮箱提供商：</label>
              <select v-model="enhancedForwardConfig.smtpProvider" class="input">
                <option value="1">网易 - 网易免费邮箱（163、126、yeah、188）</option>
                <option value="2">网易 - 网易VIP邮箱（vip.163）</option>
                <option value="3">网易 - 网易企业邮</option>
                <option value="10">腾讯 - 腾讯免费邮箱（qq、foxmail）</option>
                <option value="11">腾讯 - 腾讯企业邮</option>
                <option value="20">阿里 - 阿里免费邮箱（aliyun）</option>
                <option value="21">阿里 - 阿里企业邮箱</option>
                <option value="30">运营商 - 移动139邮箱</option>
                <option value="33">运营商 - 联通WO邮箱</option>
                <option value="36">运营商 - 电信189邮箱</option>
                <option value="37">运营商 - 电信21cn邮箱（21cn）</option>
                <option value="40">国内 - 新浪邮箱（sina）</option>
                <option value="41">国内 - 搜狐邮箱（sohu）</option>
                <option value="42">国内 - Zoho邮箱</option>
                <option value="43">国内 - 完美邮箱（88、111、email）</option>
                <option value="50">国际 - 微软邮箱（Outlook、hotmail）</option>
                <option value="51">国际 - 雅虎邮箱（Yahoo）</option>
                <option value="52">国际 - 苹果邮箱（iCLoud）</option>
                <option value="53">国际 - 谷歌邮箱（GMail）</option>
                <option value="54">国际 - AOL邮箱</option>
                <option value="55">国际 - Yandex邮箱</option>
                <option value="56">国际 - Mail.ru邮箱</option>
                <option value="999">-- 自定义邮箱 --</option>
              </select>
            </div>
            
            <div v-if="enhancedForwardConfig.smtpProvider === '999'" class="field field-full">
              <label>发信服务器：</label>
              <input v-model="enhancedForwardConfig.smtpServer" class="input" />
            </div>
            
            <div class="field field-full">
              <label>发信账号地址：</label>
              <input v-model="enhancedForwardConfig.smtpAccount" class="input" />
            </div>
            
            <div class="field field-full">
              <label>发信账号密码：</label>
              <input v-model="enhancedForwardConfig.smtpPassword" class="input" type="password" />
            </div>
            
            <div class="field field-full">
              <label>发信邮箱地址：</label>
              <input v-model="enhancedForwardConfig.smtpFromEmail" class="input" />
            </div>
            
            <div class="field field-full">
              <label>收信邮箱地址：</label>
              <input v-model="enhancedForwardConfig.smtpToEmail" class="input" />
            </div>
          </div>
          
          <!-- 企业微信/飞书配置 -->
          <div v-if="forwardMethod === '10' || forwardMethod === '11' || forwardMethod === '16'" class="config-section">
            <div class="field field-full">
              <label>机器人(1)的webhook地址(必填)：</label>
              <textarea v-model="enhancedForwardConfig.webhookUrl1" class="input textarea" rows="1"></textarea>
            </div>
            <div class="field field-full">
              <label>机器人(2)的webhook地址：</label>
              <textarea v-model="enhancedForwardConfig.webhookUrl2" class="input textarea" rows="1"></textarea>
            </div>
            <div class="field field-full">
              <label>机器人(3)的webhook地址：</label>
              <textarea v-model="enhancedForwardConfig.webhookUrl3" class="input textarea" rows="1"></textarea>
            </div>
          </div>
          
          <!-- 钉钉配置 -->
          <div v-if="forwardMethod === '13'" class="config-section">
            <div class="field field-full">
              <label>机器人(1)的webhook地址(必填)：</label>
              <textarea v-model="enhancedForwardConfig.webhookUrl1" class="input textarea" rows="2"></textarea>
            </div>
            <div class="field field-full">
              <label>机器人(1)的安全设置：加签</label>
              <input v-model="enhancedForwardConfig.signKey1" class="input" />
            </div>
            <div class="field field-full">
              <label>机器人(2)的webhook地址：</label>
              <textarea v-model="enhancedForwardConfig.webhookUrl2" class="input textarea" rows="2"></textarea>
            </div>
            <div class="field field-full">
              <label>机器人(2)的安全设置：加签</label>
              <input v-model="enhancedForwardConfig.signKey2" class="input" />
            </div>
            <div class="field field-full">
              <label>机器人(3)的webhook地址：</label>
              <textarea v-model="enhancedForwardConfig.webhookUrl3" class="input textarea" rows="2"></textarea>
            </div>
            <div class="field field-full">
              <label>机器人(3)的安全设置：加签</label>
              <input v-model="enhancedForwardConfig.signKey3" class="input" />
            </div>
          </div>
          
          <!-- 自定义URL（旧版） -->
          <div v-if="forwardMethod === 'custom'" class="config-section">
            <div class="field field-full">
              <label>转发URL</label>
              <input v-model="forwardUrl" class="input" placeholder="例如: http://example.com/forward" />
            </div>
            <div class="field field-full">
              <label>通知URL</label>
              <input v-model="notifyUrl" class="input" placeholder="例如: http://example.com/notify" />
            </div>
          </div>
          
          <div class="modal-message">将应用到 {{ selectedCount }} 台设备</div>
          <div class="modal-buttons">
            <button class="modal-btn" @click="closeEnhancedForwardModal">取消</button>
            <button class="modal-btn ok" :disabled="loading" @click="applyEnhancedForward">确定</button>
          </div>
        </div>
      </div>

      <!-- 旧版转发配置模态框（保持兼容） -->
      <div v-if="showForwardModal" class="modal" @click.self="closeForwardModal">
        <div class="modal-content">
          <div class="modal-title">批量配置转发/通知</div>
          <div class="field field-full"><label>转发URL</label><input v-model="forwardUrl" class="input" /></div>
          <div class="field field-full"><label>通知URL</label><input v-model="notifyUrl" class="input" /></div>
          <div class="modal-message">将应用到 {{ selectedCount }} 台设备</div>
          <div class="modal-buttons">
            <button class="modal-btn" @click="closeForwardModal">取消</button>
            <button class="modal-btn ok" :disabled="loading" @click="applyForward">确定</button>
          </div>
        </div>
      </div>

      <div v-if="showWifiModal" class="modal" @click.self="closeWifiModal">
        <div class="modal-content">
          <div class="modal-title">批量添加WiFi</div>
          <div class="field field-full"><label>SSID</label><input v-model="wifiSsid" class="input" /></div>
          <div class="field field-full"><label>密码</label><input v-model="wifiPwd" class="input" type="password" /></div>
          <div class="modal-message">将应用到 {{ selectedCount }} 台设备</div>
          <div class="modal-buttons">
            <button class="modal-btn" @click="closeWifiModal">取消</button>
            <button class="modal-btn ok" :disabled="loading" @click="applyWifi">确定</button>
          </div>
        </div>
      </div>

      <div v-if="showSimModal" class="modal" @click.self="closeSimModal">
        <div class="modal-content">
          <div class="modal-title">批量编辑卡号</div>
          <div class="field field-full"><label>SIM1</label><input v-model="sim1Number" class="input" /></div>
          <div class="field field-full"><label>SIM2</label><input v-model="sim2Number" class="input" /></div>
          <div class="modal-message">将应用到 {{ selectedCount }} 台设备</div>
          <div class="modal-buttons">
            <button class="modal-btn" @click="closeSimModal">取消</button>
            <button class="modal-btn ok" :disabled="loading" @click="applySim">确定</button>
          </div>
        </div>
      </div>

      <div v-if="showDetailModal" class="modal" @click.self="closeDetailModal">
        <div class="modal-content" style="max-width:760px">
          <div class="modal-title">设备详情</div>

          <div v-if="deviceDetail?.device" class="detail">
            <div class="detail-row">
              <div><b>名称</b>：{{ deviceDetail.device.alias || deviceDetail.device.devId || '-' }}</div>
              <div><b>分组</b>：{{ deviceDetail.device.grp || 'auto' }}</div>
            </div>
            <div class="detail-row">
              <div><b>IP</b>：<span class="mono">{{ deviceDetail.device.ip }}</span></div>
              <div><b>MAC</b>：<span class="mono">{{ deviceDetail.device.mac || '-' }}</span></div>
            </div>

            <div class="detail-block">
              <div class="detail-h">卡号（可编辑）</div>
              <div class="detail-row">
                <div style="flex:1"><label>SIM1</label><input v-model="deviceDetail.device.sim1number" class="input" /></div>
                <div style="flex:1"><label>SIM2</label><input v-model="deviceDetail.device.sim2number" class="input" /></div>
              </div>
              <button class="btn btn-primary btn-sm" :disabled="loading" @click="saveSimSingle">保存卡号</button>
            </div>

            <div class="detail-block">
              <div class="detail-h">转发配置</div>
              <pre class="pre">{{ JSON.stringify(deviceDetail.forwardconfig || {}, null, 2) }}</pre>
            </div>

            <div class="detail-block">
              <div class="detail-h">已保存 WiFi 列表</div>
              <div v-if="detailSavedWifi.length===0" class="muted">暂无（后端需要实现 wifilist 抓取/解析）</div>
              <table v-else class="table" style="min-width: 0">
                <thead><tr><th>SSID</th><th>安全</th><th>备注</th></tr></thead>
                <tbody>
                  <tr v-for="(w,idx) in detailSavedWifi" :key="idx">
                    <td class="mono">{{ w.ssid || '-' }}</td>
                    <td>{{ w.sec || w.security || '-' }}</td>
                    <td class="muted">{{ w.note || '' }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="modal-buttons">
            <button class="modal-btn" @click="closeDetailModal">关闭</button>
          </div>
        </div>
      </div>

      <div class="footer">Board LAN Hub v3.1 · 增强转发支持</div>
    </div>
  </div>
</template>

<style scoped>
* { box-sizing: border-box; }
.app{min-height:100vh;background:#f6f7fb;padding:14px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;color:#0f172a}
.topbar{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:12px}
.brand{display:flex;align-items:center;gap:10px}
.logo{width:40px;height:40px;border-radius:12px;background:#0f172a;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:900}
.brand-title{font-weight:900;font-size:18px;line-height:1.1}
.brand-sub{font-size:12px;color:#64748b;margin-top:2px}
.actions{display:flex;gap:10px;flex-wrap:wrap}
.btn{border:1px solid transparent;background:#fff;color:#0f172a;border-radius:12px;padding:10px 14px;font-weight:800;font-size:14px;cursor:pointer}
.btn:disabled{opacity:.6;cursor:not-allowed}
.btn-ghost{background:#fff;border-color:#e2e8f0}
.btn-primary{background:#0f172a;color:#fff}
.btn-danger{background:#ef4444;color:#fff}
.btn-sm{padding:8px 12px;font-size:13px}
.btn-block{width:100%}

.notice{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 12px;border-radius:12px;border:1px solid #e2e8f0;background:#fff;margin-bottom:12px}
.notice-info{border-left:4px solid #3b82f6}
.notice-ok{border-left:4px solid #10b981}
.notice-err{border-left:4px solid #ef4444}
.notice-text{font-size:14px}
.notice-close{border:0;background:none;font-size:20px;cursor:pointer;color:#64748b}

.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:12px}
.kpi{background:#fff;border:1px solid #e2e8f0;border-radius:16px;padding:12px}
.kpi-label{font-size:12px;color:#64748b;font-weight:800}
.kpi-value{font-size:20px;font-weight:900;margin-top:4px}

.card{background:#fff;border:1px solid #e2e8f0;border-radius:16px;padding:14px;margin-bottom:12px}
.card-title{font-size:14px;font-weight:900;margin-bottom:10px}
.form{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.field{display:flex;flex-direction:column;gap:8px}
.field-full{grid-column:1/-1}
label{font-size:12px;font-weight:900;color:#334155}
.input{width:100%;padding:11px 12px;border:1px solid #cbd5e1;border-radius:12px;outline:none;font-size:14px;background:#fff}
.textarea{resize:vertical}

.tabs{display:flex;background:#f1f5f9;padding:4px;border-radius:12px;gap:6px;margin-bottom:10px}
.tab{flex:1;border:0;background:transparent;padding:10px;border-radius:10px;font-weight:900;color:#64748b;cursor:pointer}
.tab.active{background:#fff;color:#0f172a;border:1px solid #e2e8f0}

.toolbar{margin-bottom:10px;display:flex;gap:10px}
.table-wrap{overflow-x:auto;border:1px solid #e2e8f0;border-radius:12px}
.table{width:100%;border-collapse:collapse;min-width:760px}
.table th{background:#f8fafc;text-align:left;padding:12px;font-size:12px;font-weight:900;color:#475569;border-bottom:1px solid #e2e8f0}
.table td{padding:12px;border-bottom:1px solid #f1f5f9;font-size:14px}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,Liberation Mono,Courier New,monospace;font-size:13px}
.empty{text-align:center;color:#94a3b8;padding:28px !important}
.pill{display:inline-flex;align-items:center;justify-content:center;padding:5px 10px;border-radius:999px;font-size:12px;font-weight:900}
.pill-ok{background:rgba(16,185,129,.12);color:#065f46}
.pill-bad{background:rgba(239,68,68,.12);color:#7f1d1d}
.footer{text-align:center;color:#94a3b8;font-size:12px;margin-top:6px}
.muted{color:#64748b;font-size:12px;font-weight:700}

.ck{width:16px;height:16px;cursor:pointer;margin-right:6px}
.batch-bar{display:flex;gap:8px;padding:10px;background:#fff;border-radius:12px;border:1px solid #e2e8f0;margin-bottom:10px;align-items:center;flex-wrap:wrap}
.batch-info{font-weight:900;color:#0f172a;font-size:14px}

.modal{position:fixed;z-index:999;left:0;top:0;width:100%;height:100%;overflow:auto;background-color:rgba(0,0,0,0.4)}
.modal-content{background-color:#fefefe;margin:10% auto;padding:20px;border:1px solid #888;width:90%;max-width:520px;border-radius:12px}
.modal-title{font-weight:900;margin-bottom:10px}
.modal-message{margin:10px 0;color:#334155;font-size:14px}
.modal-buttons{display:flex;justify-content:flex-end;gap:10px;margin-top:12px}
.modal-btn{padding:8px 14px;border:none;border-radius:8px;cursor:pointer;background:#e2e8f0}
.modal-btn.ok{background:#10b981;color:white}

.config-section{margin-top:15px;border-top:1px solid #e2e8f0;padding-top:15px}

.pre{background:#0b1220;color:#e5e7eb;padding:12px;border-radius:12px;overflow:auto;font-size:12px}
.detail{display:flex;flex-direction:column;gap:10px}
.detail-row{display:flex;gap:14px;flex-wrap:wrap}
.detail-block{border:1px solid #e2e8f0;border-radius:12px;padding:12px;background:#fff}
.detail-h{font-weight:900;margin-bottom:8px}

.login-wrap{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.login-card{width:100%;max-width:420px;background:#fff;border:1px solid #e2e8f0;border-radius:16px;padding:18px}
.login-title{font-size:18px;font-weight:900;margin-bottom:6px}
.login-sub{font-size:12px;color:#64748b;margin-bottom:14px}

@media (max-width:768px){
  .grid{grid-template-columns:repeat(2,1fr)}
  .form{grid-template-columns:1fr}
  .actions{width:100%}
  .btn{flex:1}
  .table{min-width:680px}
}
</style>
VUE

  run_task "npm install" bash -lc "cd '$FE' && npm install --silent" || {
    log_warn "npm install 失败，尝试使用淘宝源"
    bash -lc "cd '$FE' && npm config set registry https://registry.npmmirror.com && npm install --silent"
  }
  run_task "构建静态UI" bash -lc "cd '$FE' && npm run build --silent"
  log_info "前端静态文件已输出到：${APPDIR}/static"
}

setupservice(){
  title "配置 systemd 服务（双栈 v4+v6）"

  cat > "${SERVICEAPI4}" <<EOF
[Unit]
Description=Board LAN Hub (IPv4)
After=network.target

[Service]
Type=simple
WorkingDirectory=${APPDIR}
Environment=BMDB=${APPDIR}/data/data.db
Environment=BMSTATIC=${APPDIR}/static
Environment=BMDEVUSER=${SCANUSER}
Environment=BMDEVPASS=${SCANPASS}
Environment=BMUIUSER=admin
Environment=BMUIPASS=${UIPASS}
ExecStart=${APPDIR}/venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port ${APIPORT}
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  cat > "${SERVICEAPI6}" <<EOF
[Unit]
Description=Board LAN Hub (IPv6)
After=network.target

[Service]
Type=simple
WorkingDirectory=${APPDIR}
Environment=BMDB=${APPDIR}/data/data.db
Environment=BMSTATIC=${APPDIR}/static
Environment=BMDEVUSER=${SCANUSER}
Environment=BMDEVPASS=${SCANPASS}
Environment=BMUIUSER=admin
Environment=BMUIPASS=${UIPASS}
ExecStart=${APPDIR}/venv/bin/python -m uvicorn app.main:app --host :: --port ${APIPORT}
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable board-manager-v4.service >/dev/null 2>&1 || true
  systemctl enable board-manager-v6.service >/dev/null 2>&1 || true
  systemctl restart board-manager-v4.service
  systemctl restart board-manager-v6.service
  
  # 等待服务启动
  sleep 2
  if systemctl is-active --quiet board-manager-v4.service && \
     systemctl is-active --quiet board-manager-v6.service; then
    log_info "服务启动成功：board-manager-v4 / board-manager-v6"
  else
    log_warn "服务可能未完全启动，请检查日志"
  fi
}

check_service_health(){
  local max_attempts=10
  local attempt=1
  
  while [[ $attempt -le $max_attempts ]]; do
    if curl -s "http://127.0.0.1:${APIPORT}/api/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

status(){
  log_step "服务状态检查："
  systemctl status board-manager-v4.service board-manager-v6.service --no-pager -l
  
  log_step "端口监听状态："
  ss -ltnp | grep -E ":${APIPORT}|\\[::\\]:${APIPORT}" || log_info "端口 ${APIPORT} 未监听"
  
  log_step "服务健康检查："
  if check_service_health; then
    log_info "API 健康检查: ${GREEN}通过${NC}"
  else
    log_warn "API 健康检查: ${YELLOW}失败${NC}"
  fi
}

logs(){
  local lines="${1:-50}"
  log_step "IPv4 服务日志（最近 ${lines} 行）："
  journalctl -u board-manager-v4.service -n "$lines" --no-pager
  echo ""
  log_step "IPv6 服务日志（最近 ${lines} 行）："
  journalctl -u board-manager-v6.service -n "$lines" --no-pager
}

restart(){
  systemctl restart board-manager-v4.service
  systemctl restart board-manager-v6.service
  sleep 1
  status
}

backup_data(){
  need_root
  title "备份数据"
  
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="${BACKUP_DIR}/board-manager_backup_${timestamp}.tar.gz"
  
  mkdir -p "$BACKUP_DIR"
  
  log_step "备份数据库和配置..."
  tar -czf "$backup_file" \
    -C "${APPDIR}" data \
    "$CONFIG_FILE" \
    "${SERVICEAPI4}" \
    "${SERVICEAPI6}" 2>/dev/null
  
  if [[ $? -eq 0 ]]; then
    log_info "备份成功: $backup_file"
    log_info "大小: $(du -h "$backup_file" | cut -f1)"
  else
    log_err "备份失败"
    return 1
  fi
}

restore_data(){
  need_root
  title "恢复数据"
  
  if [[ -z "${1:-}" ]]; then
    log_step "可用的备份文件："
    ls -lt "${BACKUP_DIR}/"*.tar.gz 2>/dev/null | head -10
    read -p "请输入备份文件路径: " backup_file
  else
    backup_file="$1"
  fi
  
  if [[ ! -f "$backup_file" ]]; then
    log_err "备份文件不存在: $backup_file"
    return 1
  fi
  
  log_step "停止服务..."
  systemctl stop board-manager-v4.service >/dev/null 2>&1 || true
  systemctl stop board-manager-v6.service >/dev/null 2>&1 || true
  
  log_step "解压备份..."
  tar -xzf "$backup_file" -C / 2>/dev/null || {
    log_err "解压失败"
    return 1
  }
  
  log_step "重启服务..."
  systemctl restart board-manager-v4.service
  systemctl restart board-manager-v6.service
  
  log_info "数据恢复完成"
}

uninstall(){
  need_root
  local force_mode=false
  
  if [[ "${1:-}" == "--force" ]]; then
    force_mode=true
  fi
  
  title "安全卸载 Board LAN Hub"
  
  if [[ "$force_mode" != "true" ]]; then
    echo ""
    log_warn "⚠️  即将卸载以下内容："
    log_warn "  - 服务文件: board-manager-v4 / board-manager-v6"
    log_warn "  - 安装目录: ${APPDIR}"
    log_warn "  - 配置文件: ${CONFIG_FILE}"
    log_warn "  - 数据库: ${APPDIR}/data/data.db"
    echo ""
    read -p "是否确认卸载？(输入 'YES' 确认): " confirm
    if [[ "$confirm" != "YES" ]]; then
      log_info "取消卸载"
      exit 0
    fi
    
    read -p "是否备份数据？(y/N): " backup_confirm
    if [[ "$backup_confirm" =~ ^[Yy]$ ]]; then
      backup_data || log_warn "备份失败，继续卸载"
    fi
  fi
  
  log_step "停止服务..."
  for svc in board-manager-v4 board-manager-v6; do
    if systemctl is-active --quiet "$svc.service" 2>/dev/null; then
      log_info "停止 $svc.service"
      systemctl stop "$svc.service"
      # 等待服务停止
      for i in {1..5}; do
        if ! systemctl is-active --quiet "$svc.service" 2>/dev/null; then
          break
        fi
        sleep 1
      done
    fi
  done
  
  log_step "禁用服务..."
  for svc in board-manager-v4 board-manager-v6; do
    systemctl disable "$svc.service" 2>/dev/null || true
  done
  
  log_step "移除服务文件..."
  rm -f "${SERVICEAPI4}" "${SERVICEAPI6}" 2>/dev/null || true
  
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
  
  log_step "清理安装目录..."
  if [[ -d "${APPDIR}" ]]; then
    if [[ "$force_mode" == "true" ]] || safe_delete "${APPDIR}"; then
      log_info "已删除: ${APPDIR}"
    fi
  fi
  
  log_step "清理配置文件..."
  rm -f "$CONFIG_FILE" 2>/dev/null || true
  
  log_step "清理临时文件..."
  cleanup_temp
  
  log_step "清理NPM缓存..."
  if command -v npm >/dev/null 2>&1; then
    npm cache clean --force 2>/dev/null || true
  fi
  
  log_info "✅ 卸载完成！"
  echo ""
  log_warn "注意：日志文件仍存在于 journal 中，可通过以下命令查看："
  log_warn "  journalctl -u board-manager-v4.service"
  log_warn "  journalctl -u board-manager-v6.service"
}

doscan(){
  local cidr="$1"; local user="$2"; local pass="$3"
  local url="http://127.0.0.1:${APIPORT}/api/scan/start"
  if [[ -n "$cidr" ]]; then
    url="${url}?cidr=${cidr}&user=${user}&password=${pass}"
  else
    url="${url}?user=${user}&password=${pass}"
  fi
  run_task "触发扫描" bash -lc "curl -sS -X POST '$url' | head -c 2000; echo"
  echo ""
  log_info "扫描已触发（请在UI查看设备列表）"
}

installall(){
  need_root
  title "安装 绿邮内网群控 安全优化版+密码持久化+增强转发"

  if [[ -z "${APIPORT:-}" ]]; then APIPORT=8000; fi
  echo ""
  read -p "请输入服务端口(默认 8000): " _p || true
  if [[ -n "${_p:-}" ]]; then APIPORT="${_p}"; fi

  echo ""
  if [[ -z "${UIPASS:-}" ]]; then UIPASS=admin; fi
  read -s -p "请输入UI登录密码(默认 admin): " _up || true
  echo ""
  if [[ -n "${_up:-}" ]]; then UIPASS="${_up}"; fi

  log_info "将使用端口：${APIPORT}"
  log_info "UI密码已设置（长度：${#UIPASS}）"

  check_port "${APIPORT}" || exit 1
  install_deps || { log_err "依赖安装失败"; exit 1; }
  install_node || { log_err "Node.js安装失败"; exit 1; }
  ensure_dirs
  write_backend || { log_err "后端部署失败"; exit 1; }
  writefrontendstatic || { log_err "前端部署失败"; exit 1; }
  setupservice
  
  # 等待服务启动
  log_step "等待服务启动..."
  if check_service_health; then
    log_info "服务启动成功！"
  else
    log_warn "服务可能启动较慢，请稍后访问"
  fi

  local ip
  ip=$(get_local_ip)
  log_info "================================"
  log_info "安装完成！"
  log_info "访问地址： http://${ip:-<服务器IP>}:${APIPORT}/"
  log_info "IPv6地址： http://[::]:${APIPORT}/"
  log_info "访问端口：${APIPORT}"
  log_info "登录方式：网页密码框"
  log_info "登录密码：${UIPASS}"
  log_info "密码持久化：已启用（7天内免重复登录）"
  log_info "增强转发：支持12种转发方式"
  log_info "================================"
  log_info "管理命令："
  log_info "  $0 status      # 查看状态"
  log_info "  $0 logs        # 查看日志"
  log_info "  $0 restart     # 重启服务"
  log_info "  $0 backup      # 备份数据"
  log_info "  $0 uninstall   # 安全卸载"
  log_info "================================"
}

CMD="${1:-help}"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) APPDIR="$2"; shift 2 ;;
    --api-port) APIPORT="$2"; shift 2 ;;
    --user) SCANUSER="$2"; shift 2 ;;
    --pass) SCANPASS="$2"; shift 2 ;;
    --cidr) CIDR="$2"; shift 2 ;;
    *) shift ;;
  esac
done

set_ui_pass(){
  need_root
  local newpass="${1:-}"
  if [[ -z "$newpass" ]]; then
    read -s -p "请输入新的UI登录密码: " newpass; echo ""
  fi
  if [[ -z "$newpass" ]]; then
    log_err "密码不能为空"; exit 1
  fi
  UIPASS="$newpass"
  setupservice
  restart
  log_info "UI密码已更新"
}

set_port(){
  need_root
  local newport="${1:-}"
  if [[ -z "$newport" ]]; then
    read -p "请输入新的端口: " newport
  fi
  if [[ -z "$newport" ]]; then
    log_err "端口不能为空"; exit 1
  fi
  
  check_port "$newport" || exit 1
  APIPORT="$newport"
  setupservice
  restart
  log_info "端口已更新：${APIPORT}"
}

case "$CMD" in
  install) installall ;;
  scan)
    need_root
    if [[ -z "${CIDR:-}" ]]; then CIDR=$(auto_detect_cidr); fi
    doscan "$CIDR" "$SCANUSER" "$SCANPASS"
    ;;
  status) status ;;
  restart) restart ;;
  logs) logs "$@" ;;
  uninstall) uninstall "$@" ;;
  backup) backup_data ;;
  restore) restore_data "$@" ;;
  set-ui-pass) set_ui_pass "${1:-}" ;;
  set-port) set_port "${1:-}" ;;
  help|*) help ;;
esac

# 清理临时文件
cleanup_temp
exit 0
