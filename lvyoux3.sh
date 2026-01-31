#!/usr/bin/env bash
# 绿邮开发版 - v2.4 UI+API (默认端口 port 8000)
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
CIDR=""

SERVICEAPI="/etc/systemd/system/board-manager.service"

need_root(){
  if [[ $EUID -ne 0 ]]; then
    log_err "需要root权限，请使用 sudo 运行"
    exit 1
  fi
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

run_task(){
  local desc="$1"; shift
  local start_ts end_ts
  start_ts=$(date +%s)

  echo -ne "${BLUE}[⌛]${NC} ${desc} "
  set +e
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
Board LAN Hub - v2.4 (单端口：8000)
============================================================
用法: $0 <命令> [选项]

命令:
  install              安装系统（UI+API 同端口）
  scan                 触发扫描并添加设备（调用 /api/scan/start）
  status               查看后端服务状态
  restart              重启后端服务
  logs                 查看服务日志
  uninstall            卸载系统
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
  ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src KS+' 2>/dev/null || true)
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
  if ss -ltn 2>/dev/null | grep -q ":${port} "; then
    log_err "端口 ${port} 已被占用！"
    ss -ltnp 2>/dev/null | grep ":${port} " || true
    return 1
  fi
  return 0
}

install_deps(){
  title "安装/检查系统依赖"
  detect_os
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    run_task "apt-get update" bash -lc "apt-get update -y -qq"
    run_task "安装系统依赖" bash -lc "apt-get install -y -qq git curl ca-certificates python3 python3-pip python3-venv sqlite3 iproute2 net-tools"
  else
    run_task "安装系统依赖" bash -lc "$PKG install -y -q git curl ca-certificates python3 python3-pip sqlite iproute net-tools"
  fi
  log_info "系统依赖 OK"
}

install_node(){
  title "安装/检查 Node.js"
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log_info "已存在 node=$(node -v) npm=$(npm -v)"
    return
  fi
  detect_os
  if [[ "$OS_FAMILY" == "debian" ]]; then
    run_task "安装 Node.js 20.x 源" bash -lc "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
    run_task "安装 nodejs" bash -lc "apt-get install -y -qq nodejs"
  else
    run_task "安装 Node.js 20.x 源" bash -lc "curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -"
    run_task "安装 nodejs" bash -lc "$PKG install -y -q nodejs"
  fi
  log_info "Node OK：node=$(node -v) npm=$(npm -v)"
}

ensure_dirs(){
  title "准备目录"
  mkdir -p "${APPDIR}/app" "${APPDIR}/frontend/src" "${APPDIR}/data" "${APPDIR}/static" "${APPDIR}/bak"
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
  tail -n 120 /tmp/pip_ins.log >&2 || true
  return 1
}

write_backend(){
  title "部署后端（FastAPI + SQLite + Static UI）端口: ${APIPORT}"
  local venv="${APPDIR}/venv"

  if [[ ! -d "$venv" ]]; then
    run_task "创建 venv" bash -lc "python3 -m venv '$venv'"
  fi

  run_task "pip 安装 fastapi/uvicorn/requests" bash -lc " \
    $(declare -f pip_install_with_mirrors); \
    pip_install_with_mirrors '$venv/bin/pip' fastapi 'uvicorn[standard]' requests \
  "

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
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

DBPATH = os.environ.get("BMDB", "/opt/board-manager/data/data.db")
STATICDIR = os.environ.get("BMSTATIC", "/opt/board-manager/static")
DEFAULTUSER = os.environ.get("BMDEVUSER", "admin")
DEFAULTPASS = os.environ.get("BMDEVPASS", "admin")

TIMEOUT = float(os.environ.get("BMHTTPTIMEOUT", "2.5"))
CONCURRENCY = int(os.environ.get("BMSCANCONCURRENCY", "96"))
CIDRFALLBACKLIMIT = int(os.environ.get("BMCIDRFALLBACKLIMIT", "1024"))

app = FastAPI(title="Board LAN Hub", version="2.4.0")
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
        m = re.search(r"devs+(S+)", r)
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
}

writefrontendstatic(){
  title "部署前端（发送号码下拉仅显示号码）"
  local FE="${APPDIR}/frontend"
  mkdir -p "${FE}/src"

  cat > "${FE}/package.json" <<'PKG'
{
  "name": "board-lan-ui",
  "version": "2.4.0",
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

  cat > "${FE}/src/App.vue" <<'VUE'
<script setup>
import { ref, onMounted, computed } from 'vue'
import axios from 'axios'
const api = axios.create({ baseURL: '' })

const devices = ref([])
const numbers = ref([])
const loading = ref(false)
const notice = ref({ text: '', type: 'info' })

const activeTab = ref('devices')
const searchText = ref('')

const fromSelected = ref('')
const toPhone = ref('')
const content = ref('')

const onlineCount = computed(() => devices.value.filter(d => d.status === 'online').length)
const offlineCount = computed(() => devices.value.filter(d => d.status !== 'online').length)

const filteredDevices = computed(() => {
  const t = searchText.value.trim().toLowerCase()
  if (!t) return devices.value
  return devices.value.filter(d =>
    (d.devId || '').toLowerCase().includes(t) ||
    (d.ip || '').toLowerCase().includes(t) ||
    (d.mac || '').toLowerCase().includes(t) ||
    (d.sims?.sim1?.number || '').includes(t) ||
    (d.sims?.sim2?.number || '').includes(t)
  )
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

function setNotice(text, type='info') { notice.value = { text, type } }
function clearNotice() { notice.value = { text:'', type:'info' } }

function prettyTime(ts) {
  if (!ts) return '-'
  return new Date(ts * 1000).toLocaleString('zh-CN', { month:'2-digit', day:'2-digit', hour:'2-digit', minute:'2-digit' })
}

async function loadDevices() {
  loading.value = true
  try {
    const { data } = await api.get('/api/devices')
    devices.value = Array.isArray(data) ? data : []
  } catch (e) {
    setNotice('加载设备失败：' + (e?.response?.data?.detail || e.message), 'err')
  } finally {
    loading.value = false
  }
}

async function loadNumbers() {
  loading.value = true
  try {
    const { data } = await api.get('/api/numbers')
    numbers.value = Array.isArray(data) ? data : []
    if (!fromSelected.value && numbers.value.length) {
      const n = numbers.value[0]
      fromSelected.value = `${n.deviceId}|${n.slot}|${n.number}`
    }
  } catch (e) {
    setNotice('加载号码失败：' + (e?.response?.data?.detail || e.message), 'err')
  } finally {
    loading.value = false
  }
}

async function refresh() {
  await loadDevices()
  await loadNumbers()
}

async function startScanAdd() {
  loading.value = true
  setNotice('扫描中…', 'info')
  try {
    const { data } = await api.post('/api/scan/start')
    setNotice(`扫描完成：found=${data.found} cidr=${data.cidr}`, 'ok')
    await refresh()
  } catch (e) {
    setNotice('扫描失败：' + (e?.response?.data?.detail || e.message), 'err')
  } finally {
    loading.value = false
  }
}

async function send() {
  if (!fromSelected.value) { setNotice('请选择发送号码', 'err'); return }
  if (!toPhone.value.trim()) { setNotice('请输入接收号码', 'err'); return }
  if (!content.value.trim()) { setNotice('请输入短信内容', 'err'); return }
  const [deviceId, slot] = fromSelected.value.split('|')
  loading.value = true
  try {
    const payload = { deviceId: Number(deviceId), phone: toPhone.value.trim(), content: content.value.trim(), slot: Number(slot) }
    const { data } = await api.post('/api/sms/send-direct', payload)
    if (data.ok) setNotice('发送成功', 'ok')
    else setNotice('发送失败：' + (data.error || '未知错误'), 'err')
  } catch (e) {
    setNotice('发送失败：' + (e?.response?.data?.error || e?.response?.data?.detail || e.message), 'err')
  } finally {
    loading.value = false
  }
}

async function deleteDevice(id) {
  if (!confirm('确定删除此设备？')) return
  try {
    await api.delete(`/api/devices/${id}`)
    setNotice('设备已删除', 'ok')
    await refresh()
  } catch (e) {
    setNotice('删除失败：' + (e?.response?.data?.detail || e.message), 'err')
  }
}

onMounted(refresh)
</script>

<template>
  <div class="app">
    <div class="topbar">
      <div class="brand">
        <div class="logo">BM</div>
        <div class="brand-text">
          <div class="brand-title">开发板管理系统</div>
          <div class="brand-sub">内网群控 · 单端口</div>
        </div>
      </div>

      <div class="actions">
        <button class="btn btn-ghost" :disabled="loading" @click="refresh">刷新</button>
        <button class="btn btn-primary" :disabled="loading" @click="startScanAdd">扫描添加</button>
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
          <label>发送号码</label>
          <select v-model="fromSelected" class="input">
            <!-- 修改点：只显示号码，不拼其它信息 -->
            <option v-for="n in numbers" :key="`${n.deviceId}-${n.slot}`" :value="`${n.deviceId}|${n.slot}|${n.number}`">
              {{ n.number }}
            </option>
          </select>
        </div>

        <div class="field">
          <label>接收号码</label>
          <input v-model="toPhone" class="input" placeholder="请输入接收手机号" />
        </div>

        <div class="field field-full">
          <label>短信内容</label>
          <textarea v-model="content" class="input textarea" rows="3" placeholder="请输入短信内容"></textarea>
        </div>

        <div class="field field-full">
          <button class="btn btn-primary btn-block" :disabled="loading" @click="send">发送</button>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="card-title">设备列表</div>

      <div class="tabs">
        <button class="tab" :class="{active: activeTab==='devices'}" @click="activeTab='devices'">设备</button>
        <button class="tab" :class="{active: activeTab==='numbers'}" @click="activeTab='numbers'">号码</button>
      </div>

      <div class="toolbar">
        <input v-model="searchText" class="input" placeholder="搜索（DEV_ID / IP / MAC / 号码）..." />
      </div>

      <div v-if="activeTab==='devices'" class="table-wrap">
        <table class="table">
          <thead>
            <tr>
              <th>DEV_ID</th>
              <th>IP</th>
              <th>MAC</th>
              <th>状态</th>
              <th>最后在线</th>
              <th>操作</th>
            </tr>
          </thead>
          <tbody>
            <tr v-if="filteredDevices.length===0">
              <td class="empty" colspan="6">暂无设备，点击“扫描添加”</td>
            </tr>
            <tr v-for="d in filteredDevices" :key="d.id">
              <td>{{ d.devId || '-' }}</td>
              <td class="mono">{{ d.ip }}</td>
              <td class="mono">{{ d.mac || '-' }}</td>
              <td><span class="pill" :class="d.status==='online' ? 'pill-ok' : 'pill-bad'">{{ d.status==='online' ? '在线' : '离线' }}</span></td>
              <td class="mono">{{ prettyTime(d.lastSeen) }}</td>
              <td><button class="btn btn-danger btn-sm" @click="deleteDevice(d.id)">删除</button></td>
            </tr>
          </tbody>
        </table>
      </div>

      <div v-if="activeTab==='numbers'" class="table-wrap">
        <table class="table">
          <thead>
            <tr>
              <th>号码</th>
              <th>卡槽</th>
              <th>运营商</th>
              <th>设备</th>
              <th>IP</th>
            </tr>
          </thead>
          <tbody>
            <tr v-if="filteredNumbers.length===0">
              <td class="empty" colspan="5">暂无号码（扫描后会自动获取）</td>
            </tr>
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

    <div class="footer">Business UI · Mobile responsive</div>
  </div>
</template>

<style scoped>
*{box-sizing:border-box}
.app{min-height:100vh;background:#f6f7fb;padding:14px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#0f172a}
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
.notice-text{font-size:14px;color:#0f172a}
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
.input:focus{border-color:#3b82f6;box-shadow:0 0 0 3px rgba(59,130,246,.12)}
.textarea{resize:vertical}
.tabs{display:flex;background:#f1f5f9;padding:4px;border-radius:12px;gap:6px;margin-bottom:10px}
.tab{flex:1;border:0;background:transparent;padding:10px;border-radius:10px;font-weight:900;color:#64748b;cursor:pointer}
.tab.active{background:#fff;color:#0f172a;border:1px solid #e2e8f0}
.toolbar{margin-bottom:10px}
.table-wrap{overflow-x:auto;border:1px solid #e2e8f0;border-radius:12px}
.table{width:100%;border-collapse:collapse;min-width:760px}
.table th{background:#f8fafc;text-align:left;padding:12px;font-size:12px;font-weight:900;color:#475569;border-bottom:1px solid #e2e8f0}
.table td{padding:12px;border-bottom:1px solid #f1f5f9;font-size:14px;color:#0f172a}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,'Liberation Mono','Courier New',monospace;font-size:13px}
.empty{text-align:center;color:#94a3b8;padding:28px !important}
.pill{display:inline-flex;align-items:center;justify-content:center;padding:5px 10px;border-radius:999px;font-size:12px;font-weight:900}
.pill-ok{background:rgba(16,185,129,.12);color:#065f46}
.pill-bad{background:rgba(239,68,68,.12);color:#7f1d1d}
.footer{text-align:center;color:#94a3b8;font-size:12px;margin-top:6px}
@media (max-width: 768px){
  .grid{grid-template-columns:repeat(2,1fr)}
  .form{grid-template-columns:1fr}
  .actions{width:100%}
  .btn{flex:1}
  .table{min-width:680px}
}
</style>
VUE

  run_task "npm install" bash -lc "cd '$FE' && npm install --silent"
  run_task "构建静态UI" bash -lc "cd '$FE' && npm run build --silent"
  log_info "前端静态文件已输出到：${APPDIR}/static（通过 /static 访问）"
}

setupservice(){
  title "配置 systemd 服务（后端）"
  cat > "${SERVICEAPI}" <<EOF
[Unit]
Description=Board LAN Hub (API+UI)
After=network.target

[Service]
Type=simple
WorkingDirectory=${APPDIR}
Environment=BMDB=${APPDIR}/data/data.db
Environment=BMSTATIC=${APPDIR}/static
Environment=BMDEVUSER=${SCANUSER}
Environment=BMDEVPASS=${SCANPASS}
ExecStart=${APPDIR}/venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port ${APIPORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable board-manager.service >/dev/null 2>&1 || true
  systemctl restart board-manager.service
  log_info "服务已启动：board-manager"
}

status(){ systemctl status board-manager.service --no-pager; }
logs(){ journalctl -u board-manager.service -n 200 --no-pager; }
restart(){ systemctl restart board-manager.service; status; }

uninstall(){
  need_root
  title "卸载"
  systemctl stop board-manager.service >/dev/null 2>&1 || true
  systemctl disable board-manager.service >/dev/null 2>&1 || true
  rm -f "${SERVICEAPI}"
  systemctl daemon-reload
  rm -rf "${APPDIR}"
  log_info "卸载完成"
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
  title "安装 绿邮内网群控 单端口版"
  check_port "${APIPORT}" || exit 1
  install_deps
  install_node
  ensure_dirs
  write_backend
  writefrontendstatic
  setupservice

  local ip
  ip=$(get_local_ip)
  log_info "访问地址： http://${ip:-<服务器IP>}:${APIPORT}/"
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

case "$CMD" in
  install) installall ;;
  scan)
    need_root
    if [[ -z "${CIDR:-}" ]]; then CIDR=$(auto_detect_cidr); fi
    doscan "$CIDR" "$SCANUSER" "$SCANPASS"
    ;;
  status) status ;;
  restart) restart ;;
  logs) logs ;;
  uninstall) uninstall ;;
  help|*) help ;;
esac
