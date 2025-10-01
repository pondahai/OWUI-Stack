#!/usr/bin/env bash
set -euo pipefail

# =================== Open-WebUI + MCPO + Playwright-MCP + SearXNG (WSL/Ubuntu) ===================
# 可用環境變數：
#   PORT_MCPO=8000               # MCPO 服務埠（OpenAPI）
#   PORT_OWUI=8080               # Open-WebUI Web UI 埠
#   PORT_SXNG=8888               # SearXNG 埠（JSON: /search?format=json&q=...）
#   MCP_BROWSER_CHANNEL=chromium # 強制 Playwright 走 chromium（預設 chrome）
#   DEBUG_PW=1|pattern           # 例如 1 → 'pw:*'；或自訂 'pw:browser*'
#   USER_AGENT=...               # 給外部抓取工具使用（可選）
# =================================================================================================

# ---------- 可調參數 ----------
BASE_DIR="${HOME}/owui-stack"

VENV_MCPO="${BASE_DIR}/venv-mcpo"
VENV_OWUI="${BASE_DIR}/venv-openwebui"
VENV_SXNG="${BASE_DIR}/venv-searxng"

MCPO_CFG="${BASE_DIR}/mcpo_config.json"
SXNG_CFG_DIR="${BASE_DIR}/searxng"
SXNG_CFG="${SXNG_CFG_DIR}/settings.yml"

LOG_MCPO="${BASE_DIR}/mcpo.log"
PID_MCPO="${BASE_DIR}/mcpo.pid"
LOG_OWUI="${BASE_DIR}/openwebui.log"
PID_OWUI="${BASE_DIR}/openwebui.pid"
LOG_SXNG="${BASE_DIR}/searxng.log"
PID_SXNG="${BASE_DIR}/searxng.pid"

PORT_MCPO="${PORT_MCPO:-8000}"
PORT_OWUI="${PORT_OWUI:-8080}"
PORT_SXNG="${PORT_SXNG:-8888}"
MCP_BROWSER_CHANNEL="${MCP_BROWSER_CHANNEL:-}"
# -------------------------------

banner(){ echo; echo "== $* =="; }
rotate_log(){ [ -f "$1" ] && mv "$1" "$1.$(date +%F-%H%M%S)" 2>/dev/null || true; }

ensure_basics(){
  banner "安裝基本套件"
  sudo apt-get update -y
  sudo apt-get install -y \
    curl git ca-certificates python3-venv python3-pip build-essential jq \
    iproute2 procps xvfb ffmpeg \
    libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev
}

load_nvm(){ export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; }

ensure_node(){
  banner "安裝/啟用 nvm + Node 22（針對當前使用者）"
  if [ ! -d "$HOME/.nvm" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi
  load_nvm
  nvm install 22 >/dev/null
  nvm alias default 22 >/dev/null
  nvm use 22 >/dev/null
  echo "Node: $(node -v), npm: $(npm -v), npx: $(command -v npx)"
}

install_playwright_bits(){
  banner "安裝『Node 版』Playwright 系統依賴與瀏覽器（供 MCP Playwright 用）"
  load_nvm
  local NODE_BIN NPX_BIN NODE_DIR
  NODE_BIN="$(command -v node)"
  NPX_BIN="$(command -v npx)"
  NODE_DIR="$(dirname "$NODE_BIN")"
  sudo env "PATH=$NODE_DIR:$PATH" "$NPX_BIN" --yes playwright install-deps
  "$NPX_BIN" playwright install chrome chromium
  sudo apt-get install -y xvfb >/dev/null 2>&1 || true
}

ensure_mcpo(){
  banner "建立/啟用 venv（MCPO）並安裝 mcpo"
  mkdir -p "$BASE_DIR"
  [ -d "$VENV_MCPO" ] || python3 -m venv "$VENV_MCPO"
  # shellcheck disable=SC1091
  source "$VENV_MCPO/bin/activate"
  pip install -U pip mcpo
  deactivate
}

ensure_openwebui(){
  banner "建立/啟用 venv（Open-WebUI）並安裝 open-webui + 『Python 版』Playwright"
  [ -d "$VENV_OWUI" ] || python3 -m venv "$VENV_OWUI"
  # shellcheck disable=SC1091
  source "$VENV_OWUI/bin/activate"
  pip install -U pip open-webui
  # Python Playwright（供 Web 抓取/渲染）
  pip install -U playwright
  sudo "$VENV_OWUI/bin/playwright" install-deps chromium
  "$VENV_OWUI/bin/playwright" install chromium
  deactivate
}

# ----------------- SearXNG 安裝（Git 來源 + 依賴 + 健檢） -----------------
ensure_searxng(){
  banner "建立/啟用 venv（SearXNG）並安裝套件（Git 來源 + 前置依賴 + gunicorn）"
  mkdir -p "$SXNG_CFG_DIR"
  local PY=python3
  command -v python3.11 >/dev/null 2>&1 && PY=python3.11
  [ -d "$VENV_SXNG" ] || "$PY" -m venv "$VENV_SXNG"

  # shellcheck disable=SC1091
  source "$VENV_SXNG/bin/activate"
  pip install -U pip wheel setuptools "setuptools_scm[toml]" \
    PyYAML Babel Jinja2 "Werkzeug>=3.0" lxml gunicorn
  # 移除可能誤裝的同名 MCP 套件
  pip uninstall -y searxng >/dev/null 2>&1 || true
  # 安裝 SearXNG 本體 + redis client
  pip install "git+https://github.com/searxng/searxng.git#egg=searxng" redis

  # ---- 健檢：帶「極簡且完全靜音」的臨時設定，且不真正 import 引擎 ----
  TMP_SXNG_CFG=""
  if [ -f "$SXNG_CFG" ]; then
    export SEARXNG_SETTINGS_PATH="$SXNG_CFG"
  else
    TMP_SXNG_CFG="$(mktemp)"
    cat > "$TMP_SXNG_CFG" <<'YAML'
use_default_settings: true
server:
  bind_address: "127.0.0.1"
  port: 0
  base_url: "http://127.0.0.1/"
  secret_key: "tmp-health-check-secret"
  public_instance: false
  debug: false
ui:
  default_locale: "en"
search:
  formats: [html, json]
engines: []
logging:
  version: 1
  disable_existing_loggers: false
  root:
    level: WARNING
    handlers: [console]
  handlers:
    console:
      class: logging.StreamHandler
      level: WARNING
      formatter: simple
      stream: ext://sys.stderr
  formatters:
    simple:
      format: "%(levelname)s:%(name)s:%(message)s"
YAML
    export SEARXNG_SETTINGS_PATH="$TMP_SXNG_CFG"
  fi

  python - <<'PY'
import importlib.util, sys
ok = all(importlib.util.find_spec(m) is not None for m in ('searx', 'searx.webapp'))
if not ok:
    print("FATAL: searx or searx.webapp spec not found", file=sys.stderr); sys.exit(1)
print("OK - searx modules discoverable")
PY
  deactivate
  [ -n "${TMP_SXNG_CFG:-}" ] && rm -f "$TMP_SXNG_CFG" || true
}

gen_secret(){
python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
}

write_searxng_config(){
  banner "產生 SearXNG 設定檔（settings.yml，單一 server 區塊）"
  mkdir -p "$SXNG_CFG_DIR"
  if [ -f "$SXNG_CFG" ]; then
    echo "已存在設定：$SXNG_CFG"; return 0
  fi
  local SECRET; SECRET="$(gen_secret)"
  cat > "$SXNG_CFG" <<YAML
use_default_settings: true

server:
  bind_address: "127.0.0.1"
  port: ${PORT_SXNG}
  base_url: "http://127.0.0.1:${PORT_SXNG}/"
  secret_key: "${SECRET}"
  public_instance: false
  debug: false
  image_proxy: true

ui:
  default_locale: "en"        # UI 語系使用簡碼（en/zh/...），避免 zh-TW 造成驗證失敗
  query_in_title: true
  infinite_scroll: false
  default_theme: "simple"

search:
  safe_search: 1
  autocomplete: "duckduckgo"
  formats: [html, json]
  timeout: 8

# 關閉幾個常見噪音/易出錯引擎（需要時再逐一打開）
engines:
  - name: startpage
    disabled: true
  - name: wikidata
    disabled: true
  - name: ahmia
    disabled: true
  - name: torch
    disabled: true
  - name: yacy images
    disabled: true

# 降噪：botdetection / startpage
logging:
  version: 1
  disable_existing_loggers: false
  loggers:
    searx.botdetection:
      level: WARNING
    searx.engines.startpage:
      level: WARNING

# （可選）Redis 快取 / 限流：安裝 redis-server 後取消以下註解
# redis:
#   url: "redis://127.0.0.1:6379/0"
# limiter:
#   backend: "redis"
#   redis_url: "redis://127.0.0.1:6379/0"
#   per_minute: 120
#   burst: 60
YAML
}

write_mcpo_config(){
  banner "產生 MCPO 設定（合法 JSON，且補 PATH/HOME/NVM_DIR）"
  load_nvm
  local NPX_BIN NODE_DIR ENV_OBJ DEBUG_PATTERN
  NPX_BIN="$(command -v npx)"
  NODE_DIR="$(dirname "$(command -v node)")"

  DEBUG_PATTERN=""
  if [ -n "${DEBUG_PW:-}" ]; then
    DEBUG_PATTERN=$([ "$DEBUG_PW" = "1" ] && echo "pw:*" || echo "$DEBUG_PW")
  fi

  ENV_OBJ="{\"PATH\":\"${NODE_DIR}:${PATH}\",\"HOME\":\"${HOME}\",\"NVM_DIR\":\"${NVM_DIR:-$HOME/.nvm}\""
  [ -n "$MCP_BROWSER_CHANNEL" ] && ENV_OBJ="${ENV_OBJ},\"MCP_BROWSER_CHANNEL\":\"${MCP_BROWSER_CHANNEL}\""
  [ -n "$DEBUG_PATTERN" ] && ENV_OBJ="${ENV_OBJ},\"DEBUG\":\"${DEBUG_PATTERN}\""
  [ -n "${USER_AGENT:-}" ] && ENV_OBJ="${ENV_OBJ},\"USER_AGENT\":\"${USER_AGENT}\""
  ENV_OBJ="${ENV_OBJ}}"

  cat > "$MCPO_CFG" <<JSON
{
  "mcpServers": {
    "playwright": {
      "type": "stdio",
      "command": "${NPX_BIN}",
      "args": ["-y", "@playwright/mcp@latest", "--isolated"],
      "env": ${ENV_OBJ}
    }
  },
  "port": ${PORT_MCPO},
  "name": "MCP OpenAPI Proxy",
  "description": "Automatically generated API from MCP Tool Schemas",
  "version": "1.0",
  "corsAllowOrigins": ["*"]
}
JSON

  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$MCPO_CFG" >/dev/null
  elif command -v jq >/dev/null 2>&1; then
    jq . "$MCPO_CFG" >/dev/null
  fi
}

start_mcpo_bg(){
  banner "背景啟動 MCPO（附 PATH 注入）"
  load_nvm
  local NODE_DIR; NODE_DIR="$(dirname "$(command -v node)")"
  ss -lntp | grep -q ":${PORT_MCPO}\b" && { echo "PORT_MCPO=${PORT_MCPO} 已被佔用"; exit 1; }
  [ -f "$PID_MCPO" ] && ps -p "$(cat "$PID_MCPO")" >/dev/null 2>&1 && kill "$(cat "$PID_MCPO")" || true
  rotate_log "$LOG_MCPO"
  env PATH="$NODE_DIR:$PATH" nohup "$VENV_MCPO/bin/mcpo" \
    --config "$MCPO_CFG" --host 127.0.0.1 --port "$PORT_MCPO" > "$LOG_MCPO" 2>&1 &
  echo $! > "$PID_MCPO"
  sleep 2
  echo "MCPO PID: $(cat "$PID_MCPO")"
  echo "MCPO Playwright OpenAPI: http://127.0.0.1:${PORT_MCPO}/playwright/openapi.json"
}

start_openwebui_bg(){
  banner "背景啟動 Open-WebUI"
  ss -lntp | grep -q ":${PORT_OWUI}\b" && { echo "PORT_OWUI=${PORT_OWUI} 已被佔用"; exit 1; }
  [ -f "$PID_OWUI" ] && ps -p "$(cat "$PID_OWUI")" >/dev/null 2>&1 && kill "$(cat "$PID_OWUI")" || true
  rotate_log "$LOG_OWUI"
  local OWUI_BIN
  if [ -x "$VENV_OWUI/bin/open-webui" ]; then
    OWUI_BIN="$VENV_OWUI/bin/open-webui"
    nohup "$OWUI_BIN" serve --host 0.0.0.0 --port "$PORT_OWUI" > "$LOG_OWUI" 2>&1 &
  else
    nohup "$VENV_OWUI/bin/python3" -m open_webui serve --host 0.0.0.0 --port "$PORT_OWUI" > "$LOG_OWUI" 2>&1 &
  fi
  echo $! > "$PID_OWUI"; sleep 3
  echo "Open-WebUI PID: $(cat "$PID_OWUI")  URL: http://127.0.0.1:${PORT_OWUI}"
}

start_searxng_bg(){
  banner "背景啟動 SearXNG"
  ss -lntp | grep -q ":${PORT_SXNG}\b" && { echo "PORT_SXNG=${PORT_SXNG} 已被佔用"; exit 1; }
  [ -f "$PID_SXNG" ] && ps -p "$(cat "$PID_SXNG")" >/dev/null 2>&1 && kill "$(cat "$PID_SXNG")" || true
  rotate_log "$LOG_SXNG"

  local GUNI_BIN="$VENV_SXNG/bin/gunicorn"
  if [ ! -x "$GUNI_BIN" ]; then
    echo "WARN: $GUNI_BIN 不存在，改用 python -m gunicorn 啟動"
    nohup "$VENV_SXNG/bin/python3" -m gunicorn --timeout 120 --graceful-timeout 20 --keep-alive 2 \
          -w 2 -b 127.0.0.1:"$PORT_SXNG" searx.webapp:app > "$LOG_SXNG" 2>&1 &
  else
    SEARXNG_SETTINGS_PATH="$SXNG_CFG" \
    nohup "$GUNI_BIN" --timeout 120 --graceful-timeout 20 --keep-alive 2 \
          -w 2 -b 127.0.0.1:"$PORT_SXNG" searx.webapp:app > "$LOG_SXNG" 2>&1 &
  fi

  echo $! > "$PID_SXNG"; sleep 2
  echo "SearXNG PID: $(cat "$PID_SXNG")"
  echo "SearXNG HTML: http://127.0.0.1:${PORT_SXNG}/"
  echo "SearXNG JSON: http://127.0.0.1:${PORT_SXNG}/search?q=hello&format=json"
}

stop_searxng(){ banner "停止 SearXNG"; [ -f "$PID_SXNG" ] && kill "$(cat "$PID_SXNG")" 2>/dev/null || true; rm -f "$PID_SXNG"; }
logs_searxng(){ banner "SearXNG Log (tail)"; tail -n 160 "$LOG_SXNG" 2>/dev/null || echo "(no searxng log)"; }

stop_all(){
  banner "停止 Open-WebUI"; [ -f "$PID_OWUI" ] && kill "$(cat "$PID_OWUI")" 2>/dev/null || true; rm -f "$PID_OWUI" || true
  stop_searxng
  banner "停止 MCPO"; [ -f "$PID_MCPO" ] && kill "$(cat "$PID_MCPO")" 2>/dev/null || true; rm -f "$PID_MCPO" || true
  echo "All stopped."
}

status(){
  banner "狀態檢查"
  if [ -f "$PID_MCPO" ] && ps -p "$(cat "$PID_MCPO")" >/dev/null 2>&1; then echo "MCPO running (PID $(cat "$PID_MCPO"))"; else echo "MCPO not running"; fi
  if [ -f "$PID_OWUI" ] && ps -p "$(cat "$PID_OWUI")" >/dev/null 2>&1; then echo "Open-WebUI running (PID $(cat "$PID_OWUI"))"; else echo "Open-WebUI not running"; fi
  if [ -f "$PID_SXNG" ] && ps -p "$(cat "$PID_SXNG")" >/dev/null 2>&1; then echo "SearXNG running (PID $(cat "$PID_SXNG"))"; else echo "SearXNG not running"; fi
  echo; echo "Ports:"; ss -lntp | grep -E ":${PORT_MCPO}\b|:${PORT_OWUI}\b|:${PORT_SXNG}\b" || true
  echo; echo "Check MCPO tool schema:"; curl -s "http://127.0.0.1:${PORT_MCPO}/playwright/openapi.json" | jq '.info, .paths' | head || true
  echo; echo "Check SearXNG JSON endpoint:"; curl -s -o /dev/null -w "/search?format=json&q=test -> HTTP %{http_code}\n" "http://127.0.0.1:${PORT_SXNG}/search?format=json&q=test" || true
}

logs(){
  banner "MCPO Log (tail)"; tail -n 160 "$LOG_MCPO" 2>/dev/null || echo "(no mcpo log)"
  banner "Open-WebUI Log (tail)"; tail -n 160 "$LOG_OWUI" 2>/dev/null || echo "(no open-webui log)"
  logs_searxng
}

doctor(){
  banner "環境診斷"
  load_nvm
  echo "Node: $(command -v node) -> $(node -v 2>/dev/null || echo N/A)"
  echo "npx : $(command -v npx)"
  echo "venv(mcpo): $VENV_MCPO  mcpo: $([ -x "$VENV_MCPO/bin/mcpo" ] && echo ok || echo missing)"
  echo "venv(owui): $VENV_OWUI  open-webui: $([ -x "$VENV_OWUI/bin/open-webui" ] && echo ok || echo missing)"
  echo "venv(sxng): $VENV_SXNG  gunicorn: $([ -x "$VENV_SXNG/bin/gunicorn" ] && echo ok || echo missing)"
  echo "MCPO config: $MCPO_CFG"
  status
}

install_all(){
  ensure_basics
  ensure_node
  install_playwright_bits

  # 先有設定檔，健康檢查就不會用到預設 ultrasecretkey
  write_searxng_config
  ensure_searxng

  ensure_mcpo
  ensure_openwebui
  write_mcpo_config
}

start_all(){
  start_mcpo_bg
  start_openwebui_bg
  start_searxng_bg
  echo
  echo ">>> 在 Open-WebUI → Settings → Tools / OpenAPI servers → Add"
  echo "    填入： http://127.0.0.1:${PORT_MCPO}/playwright/openapi.json"
  echo
  echo ">>> 若要讓 Open-WebUI 使用本機 SearXNG JSON："
  echo "    http://127.0.0.1:${PORT_SXNG}/search?q={query}&format=json&pageno=1&safesearch=1&language=zh"
}

usage(){
  cat <<USAGE

用法：
  bash $(basename "$0") all           # 安裝 + 啟動（預設）
  bash $(basename "$0") install       # 只安裝/產生設定
  bash $(basename "$0") start         # 啟動 MCPO + Open-WebUI + SearXNG
  bash $(basename "$0") stop          # 停止全部
  bash $(basename "$0") restart       # 重啟全部
  bash $(basename "$0") status        # 狀態檢查
  bash $(basename "$0") logs          # 查看尾端日誌
  bash $(basename "$0") doctor        # 一鍵診斷

SearXNG 獨立控制：
  bash $(basename "$0") searx-start   # 啟動 SearXNG
  bash $(basename "$0") searx-stop    # 停止 SearXNG
  bash $(basename "$0") searx-status  # SearXNG 狀態（埠/HTTP）
  bash $(basename "$0") searx-logs    # 看 SearXNG 日誌

環境變數：
  PORT_MCPO=8000               # MCPO 埠
  PORT_OWUI=8080               # Open-WebUI 埠
  PORT_SXNG=8888               # SearXNG 埠
  MCP_BROWSER_CHANNEL=chromium  # 強制 Playwright 走 chromium
  DEBUG_PW=1|pattern           # 1=‘pw:*’，或自訂如‘pw:browser*’
  USER_AGENT=...               # （可選）給外部抓取工具使用

USAGE
}

cmd="${1:-all}"
case "$cmd" in
  all)           install_all; start_all ;;
  install)       install_all ;;
  start)         start_all ;;
  stop)          stop_all ;;
  restart)       stop_all; start_all ;;
  status)        status ;;
  logs)          logs ;;
  doctor)        doctor ;;
  searx-start)   start_searxng_bg ;;
  searx-stop)    stop_searxng ;;
  searx-status)  banner "SearXNG 狀態"
                 if [ -f "$PID_SXNG" ] && ps -p "$(cat "$PID_SXNG")" >/dev/null 2>&1; then echo "SearXNG running (PID $(cat "$PID_SXNG"))"; else echo "SearXNG not running"; fi
                 echo; echo "Ports:"; ss -lntp | grep -E ":${PORT_SXNG}\b" || true
                 echo; echo "Quick check:"
                 curl -s -o /dev/null -w "GET / -> HTTP %{http_code}\n" "http://127.0.0.1:${PORT_SXNG}/" || true
                 curl -s -o /dev/null -w "GET /search?format=json&q=test -> HTTP %{http_code}\n" "http://127.0.0.1:${PORT_SXNG}/search?format=json&q=test" || true
                 ;;
  searx-logs)    logs_searxng ;;
  *)             usage ;;
esac
