#!/usr/bin/env bash
# =============================================================================
#  LOCAL AI WORKSTATION  —  fresh-Mac, re-runnable bootstrap (Apple Silicon / M5 Pro)
# -----------------------------------------------------------------------------
#  Designed for a BRAND-NEW macOS account with nothing installed.
#
#  Installs (all free / open-source, local-first):
#    base    : Xcode Command Line Tools, (optional) Rosetta 2, Homebrew
#    tools   : ollama, colima+docker+compose, node, uv(python), git, jq, lazydocker
#    models  : local LLMs on the Apple GPU (Metal) via Ollama
#    docker  : Colima engine  +  PORTAINER web GUI to monitor containers (:9000)
#    monitor : Langfuse self-hosted dashboard for agent traces/logs (:3000)
#    search  : SearXNG self-hosted private web search, gives agents live knowledge (:8888)
#    gateway : LiteLLM, one OpenAI-compatible endpoint over Ollama, auto-logs to Langfuse (:4000)
#    UI      : a custom LIVE DASHBOARD showing all services + recent agent activity (:8800)
#    agent   : OpenClaw — the main agent: Telegram/Discord, shell/files/browser,
#              self-scheduling, orchestrates sub-agents.  https://openclaw.ai
#    extras  : Peekaboo (macOS GUI automation), workspace scaffold (SOUL.md configs,
#              self-healing dev loop, browser helper, web-search tool, README)
#
#  KEY BEHAVIOURS YOU ASKED FOR:
#    * INLINE TOKEN TUTORIALS: before any step needing a key/token (Langfuse, Telegram,
#      Discord, optional cloud model) the script prints step-by-step instructions, waits
#      for you to paste the value, VALIDATES it live, then proceeds automatically.
#    * RE-RUNNABLE + ROLLBACK: every step checks whether it already succeeded. If yes it
#      skips. If it's half-done/broken it rolls that piece back, then redoes it.
#    * START/STOP/STATUS: `bash setup_local_ai.sh --status` shows what's running;
#      `--start` / `--stop` / `--restart` control ALL services at once.
#    * RESET: run  `bash setup_local_ai.sh --reset`  to tear down everything this script
#      created (containers, services, workspace, OpenClaw) for a clean slate. It does NOT
#      remove Homebrew or Xcode CLT (shared system tools).
#    * FINAL SUMMARY: prints everything installed, all URLs, and what to do next.
#
#  HONEST LIMITS:
#    - No agent is "flawless", especially desktop/GUI control + open-web automation. You
#      supervise and improve it over time. Keep the human-approval rule in SOUL files.
#    - macOS Accessibility / Screen-Recording grants are GUI-only (TCC); the script pauses
#      and guides you through System Settings for that one step.
#    - Ollama model tags drift; a failed pull = the tag changed (see README to fix).
#    - Bash syntax validated; macOS-specific steps could not be executed by the author.
#
#  OFFICIAL SOURCES (verify before trusting — scam look-alikes exist):
#    OpenClaw github.com/openclaw/openclaw | openclaw.ai      Peekaboo github.com/steipete/peekaboo
#    Langfuse github.com/langfuse/langfuse                    SearXNG  github.com/searxng/searxng
#    Portainer github.com/portainer/portainer                 Ollama   ollama.com (tags: /library)
#    browser-use github.com/browser-use/browser-use           LiteLLM  github.com/BerriAI/litellm
#    Colima   github.com/abiosoft/colima
# =============================================================================

set -uo pipefail   # intentionally NOT -e: optional steps must continue on failure.

# ----------------------------- USER CONFIG -----------------------------------
WORKDIR="${WORKDIR:-$HOME/local-ai}"
ENV_FILE="$WORKDIR/.env"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

COLIMA_CPU="${COLIMA_CPU:-6}"
COLIMA_MEM="${COLIMA_MEM:-14}"     # GiB for the Docker VM; leaves ~45GB for native models
COLIMA_DISK="${COLIMA_DISK:-80}"   # GiB

# Ports (all bound to 127.0.0.1 / localhost only)
PORT_OLLAMA=11434; PORT_PORTAINER=9000; PORT_LANGFUSE=3000
PORT_SEARXNG=8888; PORT_GATEWAY=4000; PORT_DASHBOARD=8800

# Models — EDIT to match current tags at https://ollama.com/library (failed pulls are skipped).
MODELS=(
  "qwen3:32b|orchestrator / general reasoning brain (dense, fits 64GB)"
  "devstral|agentic coding + self-healing dev loops"
  "codestral|fast code autocomplete / FIM"
  "qwen2.5vl:7b|vision: reads screenshots for GUI control"
  "qwen3:8b|small fast router for cheap sub-tasks"
  "nomic-embed-text|embeddings for agent memory / RAG"
)

# ----------------------------- PRETTY LOGGING --------------------------------
c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_cyn=$'\033[1;36m'
log()  { printf "\n%s %s\n" "${c_blue}==>${c_reset}" "$*"; }
ok()   { printf "%s %s\n" "${c_grn}  ✓${c_reset}" "$*"; }
warn() { printf "%s %s\n" "${c_yel}  !${c_reset}" "$*"; }
err()  { printf "%s %s\n" "${c_red}  ✗${c_reset}" "$*" 1>&2; }
have() { command -v "$1" >/dev/null 2>&1; }
opt()  { "$@" || warn "non-fatal failure: $*"; }
hr()   { printf "%s\n" "${c_cyn}--------------------------------------------------------------------${c_reset}"; }

# ----------------------------- .env helpers ----------------------------------
ensure_env_file() { mkdir -p "$WORKDIR"; [ -f "$ENV_FILE" ] || : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
get_env() { ensure_env_file; sed -n "s/^$1=//p" "$ENV_FILE" | head -n1; }
set_env() {  # set_env KEY VALUE  (persists to .env and exports to current shell)
  ensure_env_file
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
  export "$key=$val"
}
load_env() { ensure_env_file; set -a; . "$ENV_FILE"; set +a; }

# ----------------------------- token validators -----------------------------
# These run on YOUR Mac (open network). If curl is unavailable they accept the value.
validate_telegram() { have curl || return 0; curl -fsS "https://api.telegram.org/bot$1/getMe" 2>/dev/null | grep -q '"ok":true'; }
validate_discord()  { have curl || return 0; [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bot $1" https://discord.com/api/v10/users/@me 2>/dev/null)" = "200" ]; }
validate_gemini()   { have curl || return 0; [ "$(curl -s -o /dev/null -w '%{http_code}' "https://generativelanguage.googleapis.com/v1beta/models?key=$1" 2>/dev/null)" = "200" ]; }

# ----------------------------- generic secret prompt -------------------------
# prompt_secret VARNAME "Title" validator_fn_or_empty "tutorial text"
prompt_secret() {
  local var="$1" title="$2" validator="$3" tutorial="$4"
  local current; current="$(get_env "$var")"
  if [ -n "$current" ]; then
    if [ -z "$validator" ] || "$validator" "$current"; then
      ok "$title already configured — skipping."; return 0
    fi
    warn "$title is set but failed validation; let's re-enter it."
  fi
  hr; printf "%s\n" "$tutorial"; hr
  local tries=0 val=""
  while :; do
    printf "%sPaste %s and press Enter (or type 'skip'): %s" "$c_cyn" "$title" "$c_reset"
    read -r val
    case "$val" in skip|SKIP) warn "Skipped $title."; return 0 ;; esac
    if [ -z "$val" ]; then warn "Empty — try again."; continue; fi
    if [ -z "$validator" ] || "$validator" "$val"; then break; fi
    tries=$((tries+1)); [ "$tries" -ge 3 ] && { warn "Couldn't validate after 3 tries; saving as-is."; break; }
    warn "That value didn't validate. Check it and try again."
  done
  set_env "$var" "$val"; ok "$title saved to .env"
}

press_enter() { printf "\n%sPress Enter when you're ready to continue...%s" "$c_yel" "$c_reset"; read -r _; }

# ----------------------------- health probes ---------------------------------
http_ok() { have curl && curl -fsS -m 4 "$1" >/dev/null 2>&1; }
docker_up() { have docker && docker info >/dev/null 2>&1; }
container_running() { docker_up && [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
# Use whichever compose is available (plugin 'docker compose' or standalone 'docker-compose')
dc() { if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi; }

# =============================================================================
#  PHASE 0 — PREFLIGHT (fresh Mac)
# =============================================================================
preflight() {
  log "Preflight"
  [ "$(uname -s)" = "Darwin" ] || { err "macOS only."; exit 1; }
  [ "$(uname -m)" = "arm64" ] || warn "Expected Apple Silicon; got $(uname -m). Continuing."
  ok "macOS $(sw_vers -productVersion 2>/dev/null) on $(uname -m)"
  ensure_env_file
  cat <<BANNER

${c_yel}This sets up a complete local-AI workstation in: ${WORKDIR}
It installs developer tools, several GB of models, Docker services, and the OpenClaw
agent, and will ask for your password (Homebrew) and a few API tokens along the way.
Re-running is safe. Use  --reset  to remove everything it creates.${c_reset}
BANNER
  printf "Proceed with install? [y/N] "; read -r r
  case "$r" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
}

setup_xcode_clt() {
  log "Xcode Command Line Tools (compilers, git, make)"
  if xcode-select -p >/dev/null 2>&1; then ok "Already installed."; return; fi
  warn "Launching the Xcode CLT installer popup — click 'Install' and wait for it to finish."
  xcode-select --install >/dev/null 2>&1 || true
  printf "Waiting for Xcode CLT to finish installing"
  while ! xcode-select -p >/dev/null 2>&1; do printf "."; sleep 5; done
  printf "\n"; ok "Xcode CLT installed."
}

setup_rosetta() {
  log "Rosetta 2 (lets you run occasional Intel-only apps; optional)"
  if /usr/bin/pgrep -q oahd 2>/dev/null || [ -d /Library/Apple/usr/share/rosetta ]; then
    ok "Already installed."; return; fi
  printf "Install Rosetta 2 now? Most of this stack is ARM-native and doesn't need it. [y/N] "
  read -r r; case "$r" in y|Y|yes) opt softwareupdate --install-rosetta --agree-to-license ;; *) ok "Skipped Rosetta." ;; esac
}

setup_homebrew() {
  log "Homebrew package manager"
  if ! have brew; then
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || { err "Homebrew install failed."; exit 1; }
  fi
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || \
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
  ok "brew $(brew --version | head -n1)"
}

setup_core_tools() {
  log "Core tools (ollama, colima, docker, node, uv, git, jq, lazydocker)"
  local pkgs="ollama colima docker docker-compose node git jq lazydocker"
  for p in $pkgs; do
    if brew list "$p" >/dev/null 2>&1; then ok "$p present"; else opt brew install "$p"; fi
  done
  have uv || opt brew install uv
  have node && ok "node $(node -v)"
  have uv && ok "uv $(uv --version 2>/dev/null)"
}

# =============================================================================
#  PHASE 1 — OLLAMA + MODELS
# =============================================================================
setup_ollama() {
  log "Ollama service + models"
  if ! http_ok "http://localhost:$PORT_OLLAMA/api/tags"; then
    opt brew services start ollama
    for _ in $(seq 1 15); do http_ok "http://localhost:$PORT_OLLAMA/api/tags" && break; sleep 1; done
  fi
  http_ok "http://localhost:$PORT_OLLAMA/api/tags" && ok "Ollama up on :$PORT_OLLAMA" \
    || warn "Ollama not responding; try 'ollama serve' in another terminal, then re-run."

  local installed; installed="$(ollama list 2>/dev/null)"
  for entry in "${MODELS[@]}"; do
    local tag="${entry%%|*}" role="${entry#*|}"
    if printf "%s" "$installed" | grep -q "^${tag%%:*}"; then
      ok "model present: $tag"
    else
      printf "    pulling %s (%s)\n" "$tag" "$role"
      ollama pull "$tag" || warn "pull failed for '$tag' — verify the tag at ollama.com/library."
    fi
  done
}

# =============================================================================
#  PHASE 2 — PYTHON ENV (with self-heal on broken venv)
# =============================================================================
PY_PKGS='browser-use langchain-openai playwright "litellm[proxy]" openai langfuse python-dotenv flask requests rich'
venv_healthy() { [ -x "$WORKDIR/.venv/bin/python" ] && "$WORKDIR/.venv/bin/python" -c "import litellm, openai, flask, requests" >/dev/null 2>&1; }
setup_python() {
  log "Python venv + automation libraries"
  if venv_healthy; then ok "venv healthy — skipping."; return; fi
  [ -d "$WORKDIR/.venv" ] && { warn "venv incomplete — rebuilding (rollback)."; rm -rf "$WORKDIR/.venv"; }
  ( cd "$WORKDIR" && opt uv venv --python 3.12 .venv \
      && opt uv pip install --python "$WORKDIR/.venv/bin/python" $PY_PKGS \
      && opt "$WORKDIR/.venv/bin/python" -m playwright install chromium )
  venv_healthy && ok "Python env ready" || warn "venv setup incomplete; re-run to retry."
}

# =============================================================================
#  PHASE 3 — DOCKER ENGINE (Colima) + PORTAINER GUI
# =============================================================================
setup_colima() {
  log "Docker engine (Colima)"
  if docker_up; then ok "Docker daemon already up."; return; fi
  opt colima start --cpu "$COLIMA_CPU" --memory "$COLIMA_MEM" --disk "$COLIMA_DISK"
  for _ in $(seq 1 20); do docker_up && break; sleep 1; done
  docker_up && ok "Docker up via Colima" || warn "Docker still down; Langfuse/Portainer/SearXNG will be skipped."
}

setup_portainer() {
  log "Portainer — web GUI to monitor Docker (:$PORT_PORTAINER)"
  docker_up || { warn "Docker down; skipping Portainer."; return; }
  if container_running portainer && http_ok "http://localhost:$PORT_PORTAINER/"; then
    ok "Portainer already running."; return; fi
  docker rm -f portainer >/dev/null 2>&1 || true   # rollback any dead container
  opt docker volume create portainer_data
  opt docker run -d --name portainer --restart unless-stopped \
    -p "127.0.0.1:$PORT_PORTAINER:9000" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data portainer/portainer-ce:latest
  ok "Portainer starting → http://localhost:$PORT_PORTAINER (set the admin password on first open, promptly)."
}

# =============================================================================
#  PHASE 4 — LANGFUSE DASHBOARD (+ interactive API keys)
# =============================================================================
langfuse_healthy() { http_ok "http://localhost:$PORT_LANGFUSE/api/public/health"; }
setup_langfuse() {
  log "Langfuse — agent trace/log dashboard (:$PORT_LANGFUSE)"
  docker_up || { warn "Docker down; skipping Langfuse."; return; }
  local LF="$WORKDIR/langfuse"
  if langfuse_healthy; then ok "Langfuse already running."
  else
    [ -d "$LF/.git" ] && ( cd "$LF" && dc down >/dev/null 2>&1 || true )  # rollback half-state
    [ -d "$LF/.git" ] || opt git clone --depth=1 https://github.com/langfuse/langfuse.git "$LF"
    ( cd "$LF" && opt dc up -d )
    printf "Waiting for Langfuse to become healthy"
    for _ in $(seq 1 60); do langfuse_healthy && break; printf "."; sleep 2; done; printf "\n"
    langfuse_healthy && ok "Langfuse is up." || warn "Langfuse slow to start; check Portainer logs later."
  fi
  collect_langfuse_keys
}

collect_langfuse_keys() {
  load_env
  local PK SK; PK="$(get_env LANGFUSE_PUBLIC_KEY)"; SK="$(get_env LANGFUSE_SECRET_KEY)"
  if [ -n "$PK" ] && [ -n "$SK" ] && \
     [ "$(curl -s -o /dev/null -w '%{http_code}' -u "$PK:$SK" "http://localhost:$PORT_LANGFUSE/api/public/projects" 2>/dev/null)" = "200" ]; then
    ok "Langfuse API keys already configured and valid — skipping."; return; fi

  cat <<TUT

${c_cyn}######################  ACTION NEEDED: LANGFUSE API KEYS  ######################${c_reset}
 The dashboard needs two keys. Do this now in your browser:
   1. Open   http://localhost:$PORT_LANGFUSE
   2. Click  "Sign up"  and create a LOCAL account (email + password; it stays on your Mac).
   3. Create an Organization, then a Project (any names).
   4. In the project, go to  Settings  ->  API Keys  ->  "Create new API key".
   5. Copy the PUBLIC KEY (starts pk-lf-...) and the SECRET KEY (starts sk-lf-...).
${c_cyn}###############################################################################${c_reset}
TUT
  press_enter
  local pk sk
  while :; do
    printf "%sPaste PUBLIC key (pk-lf-...): %s" "$c_cyn" "$c_reset"; read -r pk
    printf "%sPaste SECRET key (sk-lf-...): %s" "$c_cyn" "$c_reset"; read -r sk
    { [ -z "$pk" ] || [ -z "$sk" ]; } && { warn "Both keys are required."; continue; }
    if [ "$(curl -s -o /dev/null -w '%{http_code}' -u "$pk:$sk" "http://localhost:$PORT_LANGFUSE/api/public/projects" 2>/dev/null)" = "200" ]; then
      break; else warn "Those keys didn't authenticate against Langfuse. Try again (or Ctrl-C to abort)."; fi
  done
  set_env LANGFUSE_PUBLIC_KEY "$pk"; set_env LANGFUSE_SECRET_KEY "$sk"
  set_env LANGFUSE_HOST "http://localhost:$PORT_LANGFUSE"
  ok "Langfuse keys saved and validated."
}

# =============================================================================
#  PHASE 5 — SEARXNG (private web search → live knowledge for agents)
# =============================================================================
searxng_healthy() { http_ok "http://localhost:$PORT_SEARXNG/"; }
setup_searxng() {
  log "SearXNG — private web search (:$PORT_SEARXNG)"
  docker_up || { warn "Docker down; skipping SearXNG."; return; }
  if container_running searxng && searxng_healthy; then ok "SearXNG already running."; return; fi
  docker rm -f searxng >/dev/null 2>&1 || true
  local SX="$WORKDIR/searxng"; mkdir -p "$SX"
  if [ ! -f "$SX/settings.yml" ]; then
    local secret; secret="$(openssl rand -hex 24)"
    cat > "$SX/settings.yml" <<YAMLEOF
use_default_settings: true
server:
  secret_key: "$secret"
  bind_address: "0.0.0.0"
  limiter: false
search:
  formats:
    - html
    - json
YAMLEOF
  fi
  opt docker run -d --name searxng --restart unless-stopped \
    -p "127.0.0.1:$PORT_SEARXNG:8080" \
    -v "$SX:/etc/searxng" searxng/searxng:latest
  for _ in $(seq 1 20); do searxng_healthy && break; sleep 1; done
  searxng_healthy && ok "SearXNG up (JSON API: http://localhost:$PORT_SEARXNG/search?q=...&format=json)" \
    || warn "SearXNG slow to start; check Portainer."
}

# =============================================================================
#  PHASE 6 — LITELLM GATEWAY (model routing + Langfuse logging) + optional cloud model
# =============================================================================
setup_cloud_model_optional() {
  log "Optional: add a FREE cloud model for the hardest tasks (local stays default)"
  if [ -n "$(get_env GEMINI_API_KEY)" ]; then ok "Cloud (Gemini) key already set."; return; fi
  printf "Add an optional free cloud model (Google Gemini free tier) for hard tasks? [y/N] "
  read -r r; case "$r" in y|Y|yes) ;; *) ok "Skipping cloud model (staying fully local)."; return ;; esac
  prompt_secret GEMINI_API_KEY "Google Gemini API key" validate_gemini "$(cat <<TUT
${c_cyn}#################  ACTION NEEDED: GOOGLE GEMINI FREE API KEY  #################${c_reset}
   1. Open   https://aistudio.google.com/apikey
   2. Sign in with a Google account.
   3. Click  "Create API key"  (the free tier is rate-limited but free).
   4. Copy the key (starts with AIza...).
${c_cyn}#############################################################################${c_reset}
TUT
)"
}

setup_litellm() {
  log "LiteLLM gateway (:$PORT_GATEWAY) — friendly model names, logs to Langfuse"
  load_env
  # Base config (local models)
  cat > "$WORKDIR/litellm.config.yaml" <<'YAMLEOF'
model_list:
  - model_name: orchestrator
    litellm_params: { model: ollama/qwen3:32b,    api_base: http://localhost:11434 }
  - model_name: coder
    litellm_params: { model: ollama/devstral,     api_base: http://localhost:11434 }
  - model_name: autocomplete
    litellm_params: { model: ollama/codestral,    api_base: http://localhost:11434 }
  - model_name: vision
    litellm_params: { model: ollama/qwen2.5vl:7b, api_base: http://localhost:11434 }
  - model_name: router
    litellm_params: { model: ollama/qwen3:8b,     api_base: http://localhost:11434 }
litellm_settings:
  success_callback: ["langfuse"]
  failure_callback: ["langfuse"]
  drop_params: true
YAMLEOF
  # Append cloud model if a key exists
  if [ -n "$(get_env GEMINI_API_KEY)" ]; then
    cat >> "$WORKDIR/litellm.config.yaml" <<'YAMLEOF'
  # Optional cloud escalation model (free tier):
  - model_name: cloud
    litellm_params: { model: gemini/gemini-1.5-flash }
YAMLEOF
  fi

  cat > "$WORKDIR/start_gateway.sh" <<'SHEOF'
#!/usr/bin/env bash
cd "$(dirname "$0")" || exit 1
set -a; [ -f .env ] && . ./.env; set +a
exec "./.venv/bin/litellm" --config litellm.config.yaml --port 4000 --host 127.0.0.1
SHEOF
  chmod +x "$WORKDIR/start_gateway.sh"
  ok "Gateway configured."
}

# =============================================================================
#  PHASE 7 — CUSTOM LIVE DASHBOARD (services health + recent agent activity)
# =============================================================================
write_dashboard() {
  log "Custom live dashboard (:$PORT_DASHBOARD)"
  local D="$WORKDIR/dashboard"; mkdir -p "$D"
  cat > "$D/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""Live status board for the local AI stack: service health + recent agent traces."""
import os, requests
from flask import Flask, jsonify
from dotenv import load_dotenv

HOME = os.environ.get("LOCAL_AI_HOME", os.path.expanduser("~/local-ai"))
load_dotenv(os.path.join(HOME, ".env"))
LF = os.environ.get("LANGFUSE_HOST", "http://localhost:3000")
PK = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
SK = os.environ.get("LANGFUSE_SECRET_KEY", "")

SERVICES = [
    ("Ollama (models)",     "http://localhost:11434/api/tags",         "http://localhost:11434"),
    ("LiteLLM (gateway)",   "http://localhost:4000/health",            "http://localhost:4000"),
    ("Langfuse (traces)",   "http://localhost:3000/api/public/health", "http://localhost:3000"),
    ("SearXNG (search)",    "http://localhost:8888/",                  "http://localhost:8888"),
    ("Portainer (docker)",  "http://localhost:9000/",                  "http://localhost:9000"),
]

app = Flask(__name__)

def probe(url):
    try: return requests.get(url, timeout=3).status_code < 500
    except Exception: return False

@app.route("/api/status")
def status():
    svc = [{"name": n, "url": link, "ok": probe(h)} for (n, h, link) in SERVICES]
    traces = []
    if PK and SK:
        try:
            r = requests.get(f"{LF}/api/public/traces", params={"limit": 15}, auth=(PK, SK), timeout=4)
            for t in r.json().get("data", []):
                traces.append({"name": t.get("name") or "(trace)",
                               "time": (t.get("timestamp") or "")[:19].replace("T", " "),
                               "latency": round((t.get("latency") or 0), 2)})
        except Exception:
            pass
    return jsonify({"services": svc, "traces": traces})

PAGE = """<!doctype html><html><head><meta charset=utf-8>
<title>Local AI - Mission Control</title>
<style>
 body{background:#0b0f17;color:#e6edf3;font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:28px}
 h1{font-size:20px;margin:0 0 4px} .sub{color:#8b949e;font-size:13px;margin-bottom:22px}
 .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-bottom:26px}
 .card{background:#111826;border:1px solid #1f2a3a;border-radius:12px;padding:14px 16px}
 .dot{height:9px;width:9px;border-radius:50%;display:inline-block;margin-right:8px}
 .up{background:#2ea043}.down{background:#f85149}
 a{color:#58a6ff;text-decoration:none;font-size:13px} a:hover{text-decoration:underline}
 table{width:100%;border-collapse:collapse;font-size:13px}
 th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #1f2a3a}
 th{color:#8b949e;font-weight:600} .muted{color:#8b949e}
</style></head><body>
<h1>Local AI - Mission Control</h1>
<div class="sub">auto-refreshes every 5s - all services are local-only</div>
<div id="svc" class="grid"></div>
<h3>Recent agent activity (from Langfuse)</h3>
<table><thead><tr><th>When</th><th>Agent / call</th><th>Latency (s)</th></tr></thead>
<tbody id="tr"><tr><td colspan=3 class="muted">waiting for data...</td></tr></tbody></table>
<script>
async function tick(){
 try{
  const d = await (await fetch('/api/status')).json();
  document.getElementById('svc').innerHTML = d.services.map(s=>
   '<div class="card"><div><span class="dot '+(s.ok?'up':'down')+'"></span><b>'+s.name+'</b></div>'+
   '<div style="margin-top:6px"><a href="'+s.url+'" target="_blank">'+s.url+'</a></div></div>').join('');
  const rows = d.traces.length ? d.traces.map(t=>
   '<tr><td class="muted">'+(t.time||'')+'</td><td>'+t.name+'</td><td>'+t.latency+'</td></tr>').join('')
   : '<tr><td colspan=3 class="muted">No traces yet - run an agent through the gateway.</td></tr>';
  document.getElementById('tr').innerHTML = rows;
 }catch(e){}
}
tick(); setInterval(tick,5000);
</script></body></html>"""

@app.route("/")
def home(): return PAGE

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8800, threaded=True)
PYEOF
  ok "Dashboard app written."
}

# =============================================================================
#  PHASE 8 — KEEP THINGS RUNNING (launchd user agents) — idempotent
# =============================================================================
install_launch_agent() {  # install_launch_agent label "program-and-args"
  local label="$1" prog="$2" plist="$LAUNCH_DIR/$label.plist"
  mkdir -p "$LAUNCH_DIR"
  launchctl unload "$plist" >/dev/null 2>&1 || true   # rollback previous version
  cat > "$plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-lc</string><string>$prog</string></array>
  <key>EnvironmentVariables</key><dict><key>LOCAL_AI_HOME</key><string>$WORKDIR</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$WORKDIR/logs/$label.out.log</string>
  <key>StandardErrorPath</key><string>$WORKDIR/logs/$label.err.log</string>
</dict></plist>
PLISTEOF
  launchctl load "$plist" >/dev/null 2>&1 && ok "service loaded: $label" || warn "could not load $label"
}

setup_services() {
  log "Registering always-on services (launchd)"
  mkdir -p "$WORKDIR/logs"
  install_launch_agent "com.localai.colima"    "/opt/homebrew/bin/colima start || true; while true; do sleep 86400; done"
  install_launch_agent "com.localai.litellm"   "$WORKDIR/start_gateway.sh"
  install_launch_agent "com.localai.dashboard" "$WORKDIR/.venv/bin/python $WORKDIR/dashboard/app.py"
  ok "Gateway and dashboard will auto-start now and at login."
}

# =============================================================================
#  PHASE 9 — OPENCLAW (main agent) + interactive Telegram/Discord tokens
# =============================================================================
collect_chat_tokens() {
  log "Messaging tokens for your main agent"
  prompt_secret TELEGRAM_BOT_TOKEN "Telegram bot token" validate_telegram "$(cat <<TUT
${c_cyn}#################  ACTION NEEDED: TELEGRAM BOT TOKEN  #################${c_reset}
   1. Open Telegram and search for the user  @BotFather  (the official one, blue check).
   2. Send  /newbot
   3. Give it a display name (e.g. "My Local AI").
   4. Give it a username ending in 'bot' (e.g. my_local_ai_bot).
   5. BotFather replies with a token like  123456789:ABCdEf...  — copy that whole token.
   (After setup, you'll DM this bot to talk to your agent.)
${c_cyn}#####################################################################${c_reset}
TUT
)"
  prompt_secret DISCORD_BOT_TOKEN "Discord bot token" validate_discord "$(cat <<TUT
${c_cyn}#################  ACTION NEEDED: DISCORD BOT TOKEN  #################${c_reset}
   1. Open  https://discord.com/developers/applications  and log in.
   2. "New Application" -> name it -> Create.
   3. Left menu -> "Bot" -> "Reset Token" -> "Yes, do it!" -> "Copy" the token.
   4. On the same Bot page, enable  "MESSAGE CONTENT INTENT"  (toggle ON) and Save.
   5. Left menu -> "OAuth2" -> "URL Generator": tick scope 'bot', tick perms
      'Send Messages' + 'Read Message History', copy the generated URL, open it,
      and invite the bot to YOUR server.
   (Optional — type 'skip' if you only want Telegram.)
${c_cyn}#####################################################################${c_reset}
TUT
)"
}

openclaw_healthy() { have openclaw && openclaw --version >/dev/null 2>&1; }
setup_openclaw() {
  log "OpenClaw — the main agent (npm, auditable)"
  have npm || { warn "npm missing; skipping OpenClaw."; return; }
  if openclaw_healthy; then ok "OpenClaw already installed ($(openclaw --version 2>/dev/null))."
  else
    npm ls -g openclaw >/dev/null 2>&1 && opt npm uninstall -g openclaw   # rollback broken install
    opt npm install -g openclaw@latest
  fi
  openclaw_healthy && ok "openclaw $(openclaw --version 2>/dev/null)" || { warn "OpenClaw install failed; re-run to retry."; return; }

  load_env
  cat <<TUT

${c_cyn}######################  FINISH OPENCLAW SETUP  ######################${c_reset}
 Your tokens are saved in $WORKDIR/.env. Now run the official onboarding once:

     ${c_grn}openclaw onboard --install-daemon${c_reset}

 During onboarding:
   - Choose provider  ollama   and model  qwen3:32b  (endpoint http://localhost:$PORT_OLLAMA).
   - Connect Telegram (paste TELEGRAM_BOT_TOKEN) and/or Discord (paste DISCORD_BOT_TOKEN)
     from $WORKDIR/.env.
   - macOS will ask for permissions. To let the agent control your Mac, open:
       System Settings -> Privacy & Security -> Accessibility  (add/enable OpenClaw)
       System Settings -> Privacy & Security -> Screen Recording (add/enable OpenClaw)
       System Settings -> Privacy & Security -> Full Disk Access  (optional, for file ops)
     These toggles are protected by macOS and CANNOT be set by a script — grant only
     what you're comfortable with.
${c_cyn}###################################################################${c_reset}
TUT
  printf "Run 'openclaw onboard --install-daemon' for you now? [Y/n] "
  read -r r; case "$r" in n|N|no) warn "Skipped — run it yourself when ready." ;; *) openclaw onboard --install-daemon || warn "Onboarding exited; you can re-run it anytime." ;; esac
}

setup_peekaboo() {
  log "Peekaboo — macOS screenshot + GUI automation for agents (optional)"
  printf "Install Peekaboo? [y/N] "; read -r r; case "$r" in y|Y|yes) ;; *) ok "Skipped."; return ;; esac
  brew install --cask peekaboo 2>/dev/null && ok "Peekaboo installed." \
    || warn "Auto-install failed; see https://github.com/steipete/peekaboo for the current method."
}

# =============================================================================
#  PHASE 10 — WORKSPACE SCAFFOLD (agents, helpers, README)
# =============================================================================
scaffold_workspace() {
  log "Workspace scaffold (SOUL.md, self-heal loop, browser + web-search helpers, README)"
  local A="$WORKDIR/agents"; mkdir -p "$A"

  cat > "$A/SOUL.orchestrator.md" <<'MDEOF'
# SOUL: Orchestrator
You are the user's lead AI operator, running locally. You talk to the user on
Telegram/Discord, plan work, delegate to sub-agents, and report back concisely.

## Hard rules
- BEFORE any high-impact action (sending a message, deleting/overwriting files,
  installing software, posting publicly, submitting a web form, spending money, or
  controlling mouse/keyboard outside a sandbox): summarise the action in ONE line and
  WAIT for the user to reply "yes"/"approve". Read-only/analysis needs no confirmation.
- For anything time-sensitive or "latest", use the web-search tool (SearXNG at
  http://localhost:8888) — your built-in knowledge is out of date.
- When automating any website, respect that site's terms. Some sites (e.g. LinkedIn)
  forbid automated actions and may ban accounts; prefer draft-then-confirm and let the
  user perform the final click on such sites.

## Sub-agents (delegate by naming the model alias on the gateway)
- coder  : writes/fixes code, runs tests (self-healing loop)
- web    : browses sites and fills forms (draft-then-confirm)
- vision : reads screenshots to locate UI elements
- router : quick/cheap classification and routing

## Style
Concise. State assumptions. Surface risks. Ask one question only when truly blocked.
MDEOF

  cat > "$A/SOUL.coder.md" <<'MDEOF'
# SOUL: Coder
Implement and repair code. Loop: write -> run the given test command -> on failure read
the error and fix -> repeat until green or max iterations. Never push to a remote or
delete files without the orchestrator's approval.
MDEOF

  cat > "$A/websearch.py" <<'PYEOF'
#!/usr/bin/env python3
"""Private web search via local SearXNG -> gives agents up-to-date knowledge.
Usage: python websearch.py "your query"  ->  prints top results.
Wrap this as an OpenClaw skill (see github.com/openclaw/openclaw skills docs) so the
main agent can call it as a tool."""
import sys, requests
q = " ".join(sys.argv[1:]) or "latest AI news"
try:
    r = requests.get("http://localhost:8888/search", params={"q": q, "format": "json"}, timeout=8)
    for item in r.json().get("results", [])[:8]:
        print("- " + item.get("title", ""))
        print("  " + item.get("url", ""))
        print("  " + item.get("content", "")[:200])
except Exception as e:
    print("search failed:", e)
PYEOF

  cat > "$A/selfheal.py" <<'PYEOF'
#!/usr/bin/env python3
"""Self-healing dev loop: generate -> test -> fix -> repeat, using your LOCAL coder model
through the LiteLLM gateway. Starter scaffold — tune prompts/versions to taste.
Usage: python selfheal.py "write fizzbuzz(n) in app.py" "python -m pytest -q" """
import os, sys, subprocess, pathlib
from openai import OpenAI
client = OpenAI(base_url=os.getenv("OPENAI_BASE_URL", "http://localhost:4000"),
                api_key=os.getenv("OPENAI_API_KEY", "sk-local"))
TASK = sys.argv[1] if len(sys.argv) > 1 else "write fizzbuzz(n) in app.py"
TEST = sys.argv[2] if len(sys.argv) > 2 else "python -m pytest -q"
MAX  = int(os.getenv("MAX_ITERS", "6")); FILE = pathlib.Path("app.py")
def ask(msgs): return client.chat.completions.create(model="coder", messages=msgs, temperature=0.1).choices[0].message.content
hist = [{"role": "system", "content": "You are a precise coder. Output ONLY the full contents of app.py, no fences."},
        {"role": "user", "content": "Task: " + TASK + "\nWrite app.py to pass: " + TEST}]
for i in range(1, MAX + 1):
    code = ask(hist).strip().removeprefix("```python").removeprefix("```").removesuffix("```").strip()
    FILE.write_text(code + "\n"); print("\n--- iter %d: wrote app.py, testing ---" % i)
    p = subprocess.run(TEST, shell=True, capture_output=True, text=True); print(p.stdout, p.stderr)
    if p.returncode == 0:
        print("\nPASS on iter %d" % i); sys.exit(0)
    hist += [{"role": "assistant", "content": code},
             {"role": "user", "content": "FAILED:\n" + p.stdout + "\n" + p.stderr + "\nFix app.py. Output full file only."}]
print("\nStill failing after %d iters — needs a human." % MAX); sys.exit(1)
PYEOF

  cat > "$A/browser_helper.py" <<'PYEOF'
#!/usr/bin/env python3
"""General browser automation via browser-use, driven by your LOCAL model.
DRAFT MODE by default: it reads a page / form and PROPOSES actions but does not submit.
Set ALLOW_SUBMIT=1 to let it act. Always respect each site's terms of service.
Usage: python browser_helper.py "https://example.com/careers"
Starter scaffold — the browser-use API changes between versions; confirm against
github.com/browser-use/browser-use."""
import os, sys, asyncio
URL = sys.argv[1] if len(sys.argv) > 1 else "https://example.com"
SUBMIT = os.getenv("ALLOW_SUBMIT", "0") == "1"
async def main():
    from langchain_openai import ChatOpenAI
    from browser_use import Agent
    llm = ChatOpenAI(model="orchestrator",
                     base_url=os.getenv("OPENAI_BASE_URL", "http://localhost:4000"),
                     api_key=os.getenv("OPENAI_API_KEY", "sk-local"))
    task = "Go to " + URL + ". Describe the page and any form fields, and propose values. Do NOT submit."
    if SUBMIT:
        task += " The human approved acting — proceed carefully."
    print(await Agent(task=task, llm=llm).run())
if __name__ == "__main__":
    asyncio.run(main())
PYEOF

  chmod +x "$A/websearch.py" "$A/selfheal.py" "$A/browser_helper.py"

  cat > "$WORKDIR/README_LOCAL_AI.md" <<MDEOF
# Local AI workstation — quick reference

Everything lives in: \`$WORKDIR\`  · secrets in \`.env\` (chmod 600).

## URLs (all local-only)
| Service | URL | What it's for |
|---|---|---|
| Live dashboard | http://localhost:$PORT_DASHBOARD | services health + recent agent activity |
| Langfuse | http://localhost:$PORT_LANGFUSE | detailed agent traces, logs, tokens, latency |
| Portainer | http://localhost:$PORT_PORTAINER | GUI to monitor/restart Docker containers |
| SearXNG | http://localhost:$PORT_SEARXNG | private web search (agents' live knowledge) |
| LiteLLM gateway | http://localhost:$PORT_GATEWAY | model routing endpoint (logs to Langfuse) |
| Ollama | http://localhost:$PORT_OLLAMA | local model server |

## Daily use
- Talk to your main agent by DMing your Telegram bot (or your Discord server bot).
- Watch what it's doing on the live dashboard and in Langfuse.
- Manage containers in Portainer (set its admin password on first open).

## Helpers (gateway must be running)
\`cd $WORKDIR && source .venv/bin/activate\`
- Web search:        \`python agents/websearch.py "latest local LLM benchmarks"\`
- Self-healing code: \`python agents/selfheal.py "write fizzbuzz(n) in app.py" "python -m pytest -q"\`
- Browser (draft):   \`python agents/browser_helper.py "https://boards.greenhouse.io/<company>"\`
  (Set \`ALLOW_SUBMIT=1\` only when you've reviewed and the site permits it.)

## Re-run / repair / reset
- Re-run \`bash setup_local_ai.sh\` anytime — healthy steps are skipped, broken ones are
  rolled back and redone.
- \`bash setup_local_ai.sh --reset\` removes everything this script created.

## Monitor / start / stop services
- Status in the terminal:   \`bash setup_local_ai.sh --status\`
- Visual dashboard:         http://localhost:$PORT_DASHBOARD  (live health + recent activity)
- Docker containers GUI:    http://localhost:$PORT_PORTAINER  (Portainer)
- Stop everything:          \`bash setup_local_ai.sh --stop\`
- Start everything:         \`bash setup_local_ai.sh --start\`
- Restart everything:       \`bash setup_local_ai.sh --restart\`
- Services also auto-start at login (launchd). Stopping preserves all data and configs.
- Manual equivalents if you prefer: \`colima start|stop\`, \`brew services start|stop ollama\`,
  \`launchctl load|unload ~/Library/LaunchAgents/com.localai.*.plist\`,
  \`docker start|stop portainer searxng\`, and in \`$WORKDIR/langfuse\`: \`docker compose up -d|stop\`.

## Notes
- Local models have a fixed knowledge cutoff; currency comes from the SearXNG tool.
- Keep OpenClaw updated (\`npm update -g openclaw\`); never expose services to the public
  internet; review any community OpenClaw skill's source before installing it.
- If an \`ollama pull\` failed, the tag changed — check https://ollama.com/library and edit
  the MODELS array in setup_local_ai.sh and the aliases in litellm.config.yaml.
- Trust only the official sources listed at the top of setup_local_ai.sh.
MDEOF
  ok "Workspace ready at $WORKDIR/agents"
}

# =============================================================================
#  SERVICE CONTROL (status / start / stop) — monitor and manage everything
# =============================================================================
LAUNCH_LABELS="com.localai.colima com.localai.litellm com.localai.dashboard"
brew_env() { [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null; }
state()    { "$@" >/dev/null 2>&1 && echo up || echo down; }
svc_row()  { if [ "$2" = up ]; then printf "  %-28s %sRUNNING%s\n" "$1" "$c_grn" "$c_reset";
             else printf "  %-28s %sSTOPPED%s\n" "$1" "$c_red" "$c_reset"; fi; }

svc_status() {
  brew_env
  log "Service status"
  svc_row "Docker engine (Colima)"      "$(state docker_up)"
  svc_row "Ollama        :$PORT_OLLAMA"    "$(state http_ok "http://localhost:$PORT_OLLAMA/api/tags")"
  svc_row "LiteLLM gw    :$PORT_GATEWAY"    "$(state http_ok "http://localhost:$PORT_GATEWAY/health")"
  svc_row "Langfuse      :$PORT_LANGFUSE"    "$(state langfuse_healthy)"
  svc_row "SearXNG       :$PORT_SEARXNG"    "$(state searxng_healthy)"
  svc_row "Portainer GUI :$PORT_PORTAINER"    "$(state container_running portainer)"
  svc_row "Live dashboard:$PORT_DASHBOARD"    "$(state http_ok "http://localhost:$PORT_DASHBOARD/")"
  printf "\n  Visual dashboard: %shttp://localhost:%s%s   (start/stop: this script --start/--stop)\n" "$c_cyn" "$PORT_DASHBOARD" "$c_reset"
}

svc_start() {
  brew_env
  log "Starting all services"
  opt colima start
  for _ in $(seq 1 20); do docker_up && break; sleep 1; done
  opt brew services start ollama
  if docker_up; then
    docker start portainer searxng >/dev/null 2>&1 || true
    [ -d "$WORKDIR/langfuse" ] && ( cd "$WORKDIR/langfuse" && opt dc up -d )
  fi
  for l in $LAUNCH_LABELS; do launchctl load "$LAUNCH_DIR/$l.plist" >/dev/null 2>&1 || true; done
  ok "Start requested. Verify with:  bash setup_local_ai.sh --status"
}

svc_stop() {
  brew_env
  log "Stopping all services (models, configs, and data are preserved)"
  for l in $LAUNCH_LABELS; do launchctl unload "$LAUNCH_DIR/$l.plist" >/dev/null 2>&1 || true; done
  if docker_up; then
    [ -d "$WORKDIR/langfuse" ] && ( cd "$WORKDIR/langfuse" && dc stop >/dev/null 2>&1 || true )
    docker stop portainer searxng >/dev/null 2>&1 || true
  fi
  opt brew services stop ollama
  opt colima stop
  ok "All services stopped."
}


do_reset() {
  printf "%sThis removes the local-AI containers, services, OpenClaw, and %s. Continue? [y/N] %s" "$c_yel" "$WORKDIR" "$c_reset"
  read -r r; case "$r" in y|Y|yes) ;; *) echo "Aborted."; exit 0 ;; esac
  log "Stopping launchd services"
  for l in com.localai.colima com.localai.litellm com.localai.dashboard; do
    launchctl unload "$LAUNCH_DIR/$l.plist" >/dev/null 2>&1 || true; rm -f "$LAUNCH_DIR/$l.plist"
  done
  log "Removing Docker containers/volumes"
  if docker_up; then
    [ -d "$WORKDIR/langfuse" ] && ( cd "$WORKDIR/langfuse" && dc down -v >/dev/null 2>&1 || true )
    docker rm -f portainer searxng >/dev/null 2>&1 || true
    docker volume rm portainer_data >/dev/null 2>&1 || true
  fi
  log "Uninstalling OpenClaw + config"
  npm ls -g openclaw >/dev/null 2>&1 && opt npm uninstall -g openclaw
  rm -rf "$HOME/.openclaw"
  log "Removing workspace"
  rm -rf "$WORKDIR"
  ok "Reset complete. Homebrew, Xcode CLT, Ollama models, and Colima itself were left intact."
  echo "  (To also remove those:  brew services stop ollama; colima delete; brew uninstall ollama colima ...)"
  exit 0
}

# =============================================================================
#  FINAL SUMMARY
# =============================================================================
summary() {
  load_env
  local tg dc; tg="$(get_env TELEGRAM_BOT_TOKEN)"; dc="$(get_env DISCORD_BOT_TOKEN)"
  local tg_state dc_state
  [ -n "$tg" ] && tg_state="configured" || tg_state="(not set)"
  [ -n "$dc" ] && dc_state="configured" || dc_state="(not set)"
  cat <<SUM

${c_grn}=====================  INSTALL COMPLETE  =====================${c_reset}
Workspace: $WORKDIR    Reference: $WORKDIR/README_LOCAL_AI.md

INSTALLED & RUNNING (all local-only):
  • Models (Ollama)        http://localhost:$PORT_OLLAMA      — run 'ollama list'
  • LiteLLM gateway        http://localhost:$PORT_GATEWAY      — model routing, logs to Langfuse
  • Langfuse dashboard     http://localhost:$PORT_LANGFUSE      — agent traces / logs / tokens
  • SearXNG web search     http://localhost:$PORT_SEARXNG      — agents' live knowledge
  • Portainer (Docker GUI) http://localhost:$PORT_PORTAINER      — monitor/restart containers
  • Live status dashboard  http://localhost:$PORT_DASHBOARD      — services + recent activity
  • OpenClaw main agent    Telegram: $tg_state   Discord: $dc_state

WHAT YOU CAN DO NEXT:
  1. Open the live dashboard:   http://localhost:$PORT_DASHBOARD
  2. If you skipped it, finish the agent:   openclaw onboard --install-daemon
  3. DM your Telegram bot (or your Discord-server bot) and say hi — ask it to introduce
     its sub-agents and to web-search something current to prove the search tool works.
  4. Try the self-healing coder and browser helper (see the README).
  5. Open Portainer once to set its admin password.

MANAGING SERVICES (monitor / start / stop):
  • See what's running (terminal):   bash setup_local_ai.sh --status
  • Visual dashboard (health + logs): http://localhost:$PORT_DASHBOARD
  • Docker containers GUI:            http://localhost:$PORT_PORTAINER  (Portainer)
  • Stop everything:                  bash setup_local_ai.sh --stop
  • Start everything:                 bash setup_local_ai.sh --start
  • Restart everything:               bash setup_local_ai.sh --restart
  (Services also auto-start at login via launchd. Stopping preserves all data/configs.)

REMINDERS:
  • No agent is flawless — keep the human-approval rule in agents/SOUL.orchestrator.md.
  • Grant macOS Accessibility/Screen-Recording to OpenClaw only as far as you're comfortable.
  • Re-run this script to repair; '--reset' to start over.
${c_grn}=============================================================${c_reset}
SUM
}

# =============================================================================
#  MAIN
# =============================================================================
case "${1:-}" in
  --status)  svc_status; exit 0 ;;
  --start)   svc_start;  exit 0 ;;
  --stop)    svc_stop;   exit 0 ;;
  --restart) svc_stop; svc_start; exit 0 ;;
  --reset)   do_reset ;;
  -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
esac

main() {
  preflight
  setup_xcode_clt
  setup_rosetta
  setup_homebrew
  setup_core_tools
  setup_ollama
  setup_python
  setup_colima
  setup_portainer
  setup_langfuse              # includes interactive Langfuse keys
  setup_searxng
  setup_cloud_model_optional  # optional free cloud model
  setup_litellm
  write_dashboard
  setup_services              # launchd: gateway + dashboard + colima autostart
  collect_chat_tokens         # interactive Telegram/Discord tokens
  setup_openclaw              # install + guided onboarding
  setup_peekaboo
  scaffold_workspace
  summary
}
main "$@"
