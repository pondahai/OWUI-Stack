# OWUI Stack README

Open‑WebUI + MCPO (Playwright‑MCP) + SearXNG on Ubuntu/WSL

> 一鍵腳本：`owui-stack.sh` 會安裝並啟動三個服務：
>
> - **Open‑WebUI**：本地 Web 介面，支援模型、插件、Web 抓取。
> - **MCPO + Playwright‑MCP**：把 Playwright 工具包成 OpenAPI，給 Open‑WebUI 當工具用。
> - **SearXNG**：自架中繼搜尋（metasearch）。Open‑WebUI 可用其 JSON API 做搜尋與檢索。
>
> 亦同時安裝 **Node 版 Playwright**（給 MCP），與 **Python 版 Playwright**（給 Open‑WebUI 的抓網頁 loader）。

---

## 目錄
- [環境需求](#環境需求)
- [Windows → WSL 初次安裝](#windows--wsl-初次安裝)
- [首次安裝腳本](#首次安裝腳本)
- [服務說明與連接](#服務說明與連接)
- [常用指令](#常用指令)
- [Troubleshooting](#troubleshooting)
- [自訂與進階](#自訂與進階)
- [技術架構簡介](#技術架構簡介)
- [資料夾結構](#資料夾結構)
- [升級與移除](#升級與移除)
- [安全性備註](#安全性備註)

---

## 環境需求
- Windows 10/11，建議 11（已安裝 **WSL**）
- WSL 發行版：Ubuntu 22.04+（含 `systemd` 支援亦可）
- 至少 8 GB RAM、20 GB 可用磁碟
- 可存取網際網路（下載套件、瀏覽器等）

### 預設使用的埠
- **Open‑WebUI**：`8080`（`http://127.0.0.1:8080`）
- **MCPO（Playwright OpenAPI）**：`8000`（`http://127.0.0.1:8000/playwright/openapi.json`）
- **SearXNG**：`8888`（HTML：`/`；JSON：`/search?format=json&q=...`）

> 可用環境變數覆寫：`PORT_OWUI`、`PORT_MCPO`、`PORT_SXNG`。

---

## Windows → WSL 初次安裝
1. **以系統管理員開啟 PowerShell**，執行：
   ```powershell
   wsl --install -d Ubuntu
   ```
   安裝完成會提示重新開機，並進入 Ubuntu 初始設定（建立 Linux 使用者）。

2. **更新 Ubuntu**（在 Ubuntu 終端機）：
   ```bash
   sudo apt-get update -y && sudo apt-get upgrade -y
   ```

3. （可選）啟用 WSL 的 systemd：
   - 編輯 `/etc/wsl.conf`：
     ```ini
     [boot]
     systemd=true
     ```
   - 在 Windows PowerShell 執行 `wsl --shutdown` 後再打開 Ubuntu。

---

## 首次安裝腳本
1. 把 `owui-stack.sh` 放到 Ubuntu 家目錄，例如：`~/owui-stack.sh`。
2. 讓腳本可執行：
   ```bash
   chmod +x ~/owui-stack.sh
   ```
3. 一鍵安裝 + 啟動（首次建議用預設）：
   ```bash
   ~/owui-stack.sh
   # 等同：~/owui-stack.sh all
   ```
   腳本會安裝：
   - 基本套件、nvm/Node 22、Node 版 Playwright（含瀏覽器）
   - Python venv（Open‑WebUI / MCPO / SearXNG）
   - Open‑WebUI、MCPO、SearXNG
   - Python 版 Playwright（安裝於 Open‑WebUI venv）

4. 完成後，瀏覽器開啟：`http://localhost:8080`（Open‑WebUI）。

---

## 服務說明與連接
### Open‑WebUI ↔ Playwright‑MCP（MCPO）
- 在 **Open‑WebUI → Settings → Tools / OpenAPI servers → Add**：
  - URL：`http://127.0.0.1:8000/playwright/openapi.json`
- 之後在對話中即可呼叫 Playwright 工具（例如自動開啟網頁、截圖等）。

### Open‑WebUI ↔ SearXNG
- Open‑WebUI 的 Web 檢索/抓取可直接用內建 Playwright loader。
- 另外，若要使用 SearXNG 作為「搜尋來源」，可將請求指向：
  - `http://127.0.0.1:8888/search?q={query}&format=json&pageno=1&safesearch=1&language=zh`

### 驗證 SearXNG
```bash
curl -I http://127.0.0.1:8888/
curl -s "http://127.0.0.1:8888/search?q=hello&format=json" | jq '.results[:3]'
```

---

## 常用指令
在 Ubuntu 終端機（**WSL**）執行：

```bash
# 啟動全部
./owui-stack.sh start

# 停止全部
./owui-stack.sh stop

# 狀態/埠檢查 + 快速健康檢查
./owui-stack.sh status

# 查看各服務尾端日誌
./owui-stack.sh logs

# 只控管 SearXNG
./owui-stack.sh searx-start | searx-stop | searx-status | searx-logs
```

常見環境變數（執行前臨時覆寫）：
```bash
PORT_OWUI=8081 PORT_SXNG=9999 ./owui-stack.sh start
DEBUG_PW=1 MCP_BROWSER_CHANNEL=chromium ./owui-stack.sh start
```

---

## Troubleshooting
### 1) Open‑WebUI：`playwright package not found`
- 代表 **Python 版 Playwright**未安裝在 Open‑WebUI venv。
- 腳本已自動安裝；若遇到升級或手動破壞環境，可重跑：
  ```bash
  source ~/owui-stack/venv-openwebui/bin/activate
  pip install -U playwright
  sudo ~/owui-stack/venv-openwebui/bin/playwright install-deps chromium
  ~/owui-stack/venv-openwebui/bin/playwright install chromium
  deactivate
  ./owui-stack.sh restart
  ```

### 2) SearXNG：首頁/JSON 回 500（`default_locale` 錯）
- 將 `~/owui-stack/searxng/settings.yml` 的 `ui.default_locale` 設為 `en` 或 `zh`（**不要**用 `zh-TW`）。

### 3) SearXNG：`server.secret_key is not changed`
- 代表未帶設定檔啟動；腳本的正式設定已生成隨機 `secret_key`，請用：
  ```bash
  ./owui-stack.sh searx-stop && ./owui-stack.sh searx-start
  ```

### 4) SearXNG：`X-Forwarded-For nor X-Real-IP header is set!`
- 直接連後端（非反向代理）時的提示，**無害**。已將日誌等級調整。

### 5) SearXNG：某些引擎 timeout / 噪音多
- 預設已關閉 `startpage`、`wikidata`、`yacy images`、`ahmia`、`torch` 等；如需啟用，編輯 `settings.yml` 將該引擎的 `disabled` 註解掉或改為 `false`。
- `search.timeout` 預設 8 秒，可依需要調整。

### 6) Gunicorn `WORKER TIMEOUT`
- 已把超時拉高（`--timeout 120`），若環境較慢可再增大或減少 worker 數（`-w`）。

### 7) 埠被佔用
- `status` 會列出監聽埠；改用環境變數指定其他埠重新啟動。

### 8) `not a git repository` 訊息
- 來自 SearXNG 讀取 git 版本資訊失敗；因為使用 pip snapshot，**無害**。

### 9) SearXNG JSON 用 jq 解析錯誤 `Cannot index object with object`
- SearXNG 回傳的是**物件**；用：`jq '.results[:3]'`。

---

## 自訂與進階
### 調整埠與 Playwright 參數
- 執行前設定環境變數覆寫：
  - `PORT_MCPO`、`PORT_OWUI`、`PORT_SXNG`
  - `MCP_BROWSER_CHANNEL=chromium`（Node 版 Playwright 預設改為 Chromium）
  - `DEBUG_PW=1` 或 `pw:*`（Playwright 除錯輸出）

### 對外提供 SearXNG（WSL → Windows/其他裝置）
1. 編輯 `~/owui-stack/searxng/settings.yml`：
   ```yaml
   server:
     bind_address: "0.0.0.0"
   ```
2. 重新啟動：`./owui-stack.sh searx-stop && ./owui-stack.sh searx-start`
3. **Windows 防火牆**允許該埠（例如 8888），及網路環境的 ACL/防火牆策略。

> 安全考量：SearXNG 預設 `public_instance: false`，建議仍只在本機或可信網段使用。

### 以 systemd 管理（WSL 新版支援）
- 若 WSL 啟用 systemd，可把 `owui-stack.sh start` 的流程拆成三個 service；本文不贅述，建議先確認手動流程穩定。

---

## 技術架構簡介
- **Open‑WebUI**：FastAPI + 前端 Web；提供聊天、工具、Web 抓取（透過 LangChain loader；此處使用 **Python 版 Playwright**）。
- **MCPO**：將 **Playwright‑MCP**（Node 版 Playwright 的 MCP 伺服器）透過 **MCPO Proxy** 暴露為 OpenAPI，Open‑WebUI 以「OpenAPI Tool」方式呼叫。
- **SearXNG**：Python/Flask 應用，以多引擎聚合回傳 HTML/JSON；本方案用 **gunicorn** 啟動，並整合簡易日誌與超時設定。
- **雙 Playwright 架構**：
  - Node 版：供 MCP 工具（`@playwright/mcp`）使用，nvm 管理版本。
  - Python 版：供 Open‑WebUI 的 `SafePlaywrightURLLoader` 等使用。

---

## 資料夾結構
預設根目錄：`~/owui-stack`。
```
~/owui-stack/
  ├─ venv-openwebui/      # Open‑WebUI 的 Python venv（含 Python 版 Playwright）
  ├─ venv-mcpo/           # MCPO 的 Python venv
  ├─ venv-searxng/        # SearXNG 的 Python venv
  ├─ searxng/
  │   └─ settings.yml     # SearXNG 設定檔
  ├─ mcpo_config.json     # MCPO 設定（Playwright OpenAPI）
  ├─ *.log                # 各服務日誌
  └─ owui-stack.sh        # 這個一鍵腳本
```

---

## 升級與移除
### 升級
```bash
# 重新跑 install（會保留設定與 venv，必要時升級套件）
./owui-stack.sh install
# 或手動進 venv 升級特定套件（例如 open-webui）：
source ~/owui-stack/venv-openwebui/bin/activate && pip install -U open-webui && deactivate
```

### 移除
```bash
./owui-stack.sh stop
rm -rf ~/owui-stack
# （可選）移除 nvm / Node：刪除 ~/.nvm 並清 shell 啟動腳本的 nvm 相關行
```

---

## 安全性備註
- Open‑WebUI 預設綁 `0.0.0.0`（方便本機與 LAN 存取），請務必在受信環境使用或加上反向代理/驗證。
- SearXNG 預設綁 `127.0.0.1`；若改為 `0.0.0.0` 對外，請做好防火牆限制。
- MCPO 預設僅在 `127.0.0.1`：`8000`；若要對外，建議放在反向代理之後並限制來源。

---

## 範例：Quick Start（最短路徑）
```bash
# Windows PowerShell（管理員）
wsl --install -d Ubuntu

# Ubuntu（WSL）
sudo apt-get update -y && sudo apt-get upgrade -y
chmod +x ~/owui-stack.sh
~/owui-stack.sh                # 安裝 + 啟動

# 驗證
curl -I http://127.0.0.1:8080  # Open‑WebUI
curl -I http://127.0.0.1:8000/playwright/openapi.json  # MCPO OpenAPI
curl -s "http://127.0.0.1:8888/search?q=hello&format=json" | jq '.results[:3]' # SearXNG JSON
```

祝使用順利！若要加上更多一鍵選項（例如 `EXPOSE_SXNG=1`、Redis/限流、自動反代），可以在 issue/需求裡提出後續擴充。

