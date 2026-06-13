#!/usr/bin/env bash
# Re-exec under bash if started by a non-bash shell (sh/dash choke on the arrays below).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
# =============================================================================
#  LOCAL AI WORKSTATION  —  fresh-Mac bootstrap  (Apple Silicon / M5 Pro / 64GB)
# -----------------------------------------------------------------------------
#  GOAL: a fully local-first AI workstation that can:
#    1. Build web apps / native apps / scripts using LOCAL models (Aider, Continue,
#       Antigravity, Copilot CLI).
#    2. Answer questions with UP-TO-DATE info from the internet (SearXNG web search
#       wired into Open WebUI and the agent).
#    3. Be driven from your phone over Telegram (OpenClaw agent).
#    4. Make changes to the Mac & control GUI apps (OpenClaw + Peekaboo) — with a
#       human-approval gate on every high-impact action.
#    5. Show a live DASHBOARD of every service + recent agent activity.
#
#  EVERYTHING HERE IS FREE / OPEN-SOURCE OR HAS A FREE TIER. No paid keys required.
#
#  LOCAL IS PRIMARY. The local Ollama models are the default brain for every task.
#  Cloud / GUI tools (Antigravity, Microsoft 365 Copilot, GitHub Copilot CLI, optional
#  Gemini key) are BACKUP only — used when you explicitly reach for them, never by default.
#  Nothing in the default path sends your data off the machine.
#
#  RE-RUNNABLE: run this script as many times as you like. Every step checks whether it
#  already succeeded and skips it; half-finished/broken pieces are rolled back and redone.
#  No step duplicates config, re-downloads existing models, or double-creates containers.
#
#  WHAT A SCRIPT CANNOT DO (you finish these in the GUI — the script guides you):
#    - Drag-install .app bundles (Antigravity, LM Studio): brew --cask handles most.
#    - Grant macOS Accessibility / Screen Recording (TCC) — protected by macOS;
#      the script pauses and walks you through System Settings.
#    - OpenClaw onboarding wizard (channels, model) — run interactively at the end.
#
#  HONEST LIMITS (read README_AI.md for the long version):
#    - Goal #4 (mouse/app control from a text command) is the LEAST reliable part of
#      any agent stack today. Local models drive GUI automation worse than frontier
#      cloud models. Expect to supervise, approve, and correct. Keep the approval gate.
#    - "Code as good as Codex/Claude" locally: the best FREE local models get close
#      for many tasks but won't fully match frontier cloud models on hard agentic work.
#    - SECURITY: a 2026 audit found ~41% of community OpenClaw "skills" had vulns and
#      ~18% had malware indicators. This script installs ONLY OpenClaw core. Do NOT
#      install third-party skills without reading their source first.
#
#  CONTROL:  --status | --start | --stop | --restart | --reset | --help
#
#  OFFICIAL SOURCES (verify before trusting; look-alikes exist):
#    Ollama ollama.com  ·  Open WebUI github.com/open-webui/open-webui
#    Aider aider.chat  ·  Continue continue.dev  ·  LM Studio lmstudio.ai
#    OpenClaw github.com/openclaw/openclaw  ·  Peekaboo peekaboo.boo
#    SearXNG github.com/searxng/searxng  ·  Langfuse github.com/langfuse/langfuse
#    LiteLLM github.com/BerriAI/litellm  ·  Colima github.com/abiosoft/colima
#    Antigravity antigravity.google  ·  Copilot CLI github.com/github/copilot-cli
# =============================================================================
set -uo pipefail   # NOT -e: optional steps must continue on failure.

# ----------------------------- USER CONFIG -----------------------------------
WORKDIR="${WORKDIR:-$HOME/ai-workstation}"
ENV_FILE="$WORKDIR/.env"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

# Colima (Docker VM). 64GB unified mem is SHARED with the GPU/models — keep this lean
# so big local models have room. 8GB VM is plenty for the containers used here.
COLIMA_CPU="${COLIMA_CPU:-4}"
COLIMA_MEM="${COLIMA_MEM:-8}"
COLIMA_DISK="${COLIMA_DISK:-60}"

# Keep at most one heavy model resident at a time (protects unified memory).
OLLAMA_MAX_LOADED="${OLLAMA_MAX_LOADED:-1}"

# Ports (all bound to 127.0.0.1 only)
PORT_OLLAMA=11434; PORT_OPENWEBUI=3001; PORT_LANGFUSE=3000
PORT_SEARXNG=8888; PORT_GATEWAY=4000;  PORT_DASHBOARD=8800

# Models — ACCURACY-FIRST selection for an M5 Pro / 64GB (speed is secondary; you said
# you can wait). These are the most accurate FREE local models that ACTUALLY FIT in 64GB
# unified memory, leaving room for macOS + Docker. EDIT tags at https://ollama.com/library.
#
# WHY NOT Kimi K2.6 or Qwen3.5-122B? They do NOT fit 64GB and are intentionally excluded:
#   - Kimi K2.6 is a 1T-parameter MoE; even its smallest Q2 quant needs ~350GB RAM (all
#     experts must sit in memory). It needs a server, not a laptop.
#   - Qwen3.5 122B-A10B is ~74-81GB at Q4 — over your 64GB once the OS/Docker take their cut.
# The picks below are the accuracy ceiling that runs well on 64GB.
MODELS=(
  # --- reasoning / orchestrator brain ---
  "qwen3.5:35b-a3b|MAX-ACCURACY reasoning that fits 64GB (MoE 35B/3B active, ~22GB); near-frontier quality"
  # --- coding (accuracy-first) ---
  "qwen3.6:27b|PRIMARY coder: best DENSE model (77.2% SWE-bench, ~22GB at Q6) — most accurate coder that fits"
  "qwen3-coder-next|dedicated agentic coding (80B MoE, ~46GB); fits 64GB for code-only sessions"
  "devstral:24b|agentic coding: multi-file edits, tool calls, test-fix loops (~16GB)"
  "codestral:22b|fast FIM autocomplete for the IDE"
  # --- support models ---
  "qwen2.5vl:7b|vision: reads screenshots so the agent can 'see' the UI"
  "nomic-embed-text|embeddings for memory / RAG / web-search reranking"
)
# Memory note: with OLLAMA_MAX_LOADED_MODELS=1 only one heavy model is resident at a time,
# so these don't all load at once — Ollama swaps them in on demand. Even so, don't run the
# 46GB coder-next at the same time as Docker-heavy services. Comment out any line you don't
# need; failed/oversized pulls just skip. For the BEST accuracy that fits, lead with
# qwen3.6:27b (coding) and qwen3.5:35b-a3b (reasoning).

# ----------------------------- PRETTY LOGGING --------------------------------
c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_cyn=$'\033[1;36m'
log()  { printf "\n%s %s\n" "${c_blue}==>${c_reset}" "$*"; }
ok()   { printf "%s %s\n" "${c_grn}  ok${c_reset}" "$*"; }
warn() { printf "%s %s\n" "${c_yel}  ! ${c_reset}" "$*"; }
err()  { printf "%s %s\n" "${c_red}  x ${c_reset}" "$*" 1>&2; }
have() { command -v "$1" >/dev/null 2>&1; }
opt()  { "$@" || warn "non-fatal failure: $*"; }
hr()   { printf "%s\n" "${c_cyn}--------------------------------------------------------------------${c_reset}"; }

# ----------------------------- .env helpers ----------------------------------
ensure_env_file() { mkdir -p "$WORKDIR"; [ -f "$ENV_FILE" ] || : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
get_env() { ensure_env_file; sed -n "s/^$1=//p" "$ENV_FILE" | head -n1; }
set_env() {
  ensure_env_file
  local key="$1" val="$2" tmp; tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"; export "$key=$val"
}
load_env() { ensure_env_file; set -a; . "$ENV_FILE"; set +a; }

# ----------------------------- validators / prompts --------------------------
validate_telegram() { have curl || return 0; curl -fsS "https://api.telegram.org/bot$1/getMe" 2>/dev/null | grep -q '"ok":true'; }
validate_gemini()   { have curl || return 0; [ "$(curl -s -o /dev/null -w '%{http_code}' "https://generativelanguage.googleapis.com/v1beta/models?key=$1" 2>/dev/null)" = "200" ]; }
press_enter() { printf "\n%sPress Enter when ready to continue...%s" "$c_yel" "$c_reset"; read -r _; }

prompt_secret() {  # prompt_secret VAR "Title" validator_fn tutorial_fn
  local var="$1" title="$2" validator="$3" tut_fn="$4" current
  current="$(get_env "$var")"
  if [ -n "$current" ]; then
    if [ -z "$validator" ] || "$validator" "$current"; then ok "$title already set."; return 0; fi
    warn "$title set but failed validation; re-enter."
  fi
  [ -n "$tut_fn" ] && { hr; "$tut_fn"; hr; }
  local tries=0 val=""
  while :; do
    printf "%sPaste %s and press Enter (or 'skip'): %s" "$c_cyn" "$title" "$c_reset"; read -r val
    case "$val" in skip|SKIP) warn "Skipped $title."; return 0 ;; esac
    [ -z "$val" ] && { warn "Empty - try again."; continue; }
    if [ -z "$validator" ] || "$validator" "$val"; then break; fi
    tries=$((tries+1)); [ "$tries" -ge 3 ] && { warn "Couldn't validate; saving as-is."; break; }
    warn "Didn't validate. Try again."
  done
  set_env "$var" "$val"; ok "$title saved."
}

tut_telegram() {
cat <<TUT
${c_cyn}#############  ACTION: TELEGRAM BOT TOKEN  #############${c_reset}
  1. Open Telegram, search @BotFather (official, blue check).
  2. Send /newbot ; give it a name and a username ending in 'bot'.
  3. Copy the token it returns (looks like 123456789:ABCdEf...).
  (After setup you DM this bot to command your agent.)
${c_cyn}#######################################################${c_reset}
TUT
}
tut_gemini() {
cat <<TUT
${c_cyn}#############  ACTION: GOOGLE GEMINI FREE API KEY (optional)  #############${c_reset}
  1. Open https://aistudio.google.com/apikey  -> sign in.
  2. "Create API key" (free tier; rate-limited but free).
  3. Copy the key (starts AIza...). Used only for hard tasks; local stays default.
${c_cyn}#########################################################################${c_reset}
TUT
}

# ----------------------------- health probes ---------------------------------
http_ok()  { have curl && curl -fsS -m 4 "$1" >/dev/null 2>&1; }
docker_up(){ have docker && docker info >/dev/null 2>&1; }
container_running(){ docker_up && [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
dc() { if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi; }

# Re-run-safe container launcher.
#   - if the named container is already running -> leave it (skip)
#   - if it exists but is stopped/half-created -> remove it, then create fresh (rollback)
#   - otherwise -> run it
# Usage: ensure_container NAME docker run -d --name NAME ...
ensure_container() {
  local name="$1"; shift
  if container_running "$name"; then return 0; fi
  docker rm -f "$name" >/dev/null 2>&1 || true   # clears Exited/Created leftovers
  "$@"
}

# =============================================================================
#  PHASE 0 — PREFLIGHT
# =============================================================================
preflight() {
  log "Preflight"
  [ "$(uname -s)" = "Darwin" ] || { err "macOS only."; exit 1; }
  [ "$(uname -m)" = "arm64" ] || warn "Expected Apple Silicon; got $(uname -m)."
  ok "macOS $(sw_vers -productVersion 2>/dev/null) on $(uname -m)"
  ensure_env_file
  cat <<BANNER

${c_yel}This builds a local AI workstation in: ${WORKDIR}
It installs dev tools, several GB of models, Docker services, coding agents, and the
OpenClaw phone-driven agent. You'll be asked for your password (Homebrew) and a few
free tokens. Re-running is safe; --reset removes what it creates.

IMPORTANT: Update macOS first (Apple menu > System Settings > General > Software
Update). New M5 Macs shipped with an early Tahoe build that had an M5 shutdown bug
fixed in a later patch.${c_reset}
BANNER
  printf "Proceed? [y/N] "; read -r r; case "$r" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
}

setup_xcode_clt() {
  log "Xcode Command Line Tools"
  if xcode-select -p >/dev/null 2>&1; then ok "Already installed."; return; fi
  warn "Installer popup will appear — click Install and wait."
  xcode-select --install >/dev/null 2>&1 || true
  printf "Waiting for Xcode CLT"; while ! xcode-select -p >/dev/null 2>&1; do printf "."; sleep 5; done
  printf "\n"; ok "Xcode CLT installed."
}

setup_homebrew() {
  log "Homebrew"
  if ! have brew; then
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || { err "Homebrew install failed."; exit 1; }
  fi
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || \
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
  ok "$(brew --version | head -n1)"
}

setup_core_tools() {
  log "Core CLI tools"
  # node 22+ required by OpenClaw and Copilot CLI; uv for python; jq/git/etc utilities.
  local pkgs="ollama colima docker docker-compose node git jq wget lazydocker uv"
  for p in $pkgs; do
    if brew list "$p" >/dev/null 2>&1; then ok "$p present"; else opt brew install "$p"; fi
  done
  have node && ok "node $(node -v)"
  have uv && ok "uv $(uv --version 2>/dev/null)"
}

setup_java() {
  log "Java for development (Eclipse Temurin — latest free OpenJDK LTS)"
  # Temurin is the recommended free OpenJDK build (same source Oracle uses, no license
  # restrictions). The plain 'temurin' cask tracks the latest release.
  if brew list --cask temurin >/dev/null 2>&1 || /usr/libexec/java_home >/dev/null 2>&1; then
    ok "Java already installed: $(java -version 2>&1 | head -n1)"
  else
    opt brew install --cask temurin
  fi
  # Set JAVA_HOME in .zprofile (guarded so re-runs don't duplicate the line).
  if ! grep -q 'JAVA_HOME' "$HOME/.zprofile" 2>/dev/null; then
    echo 'export JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null)"' >> "$HOME/.zprofile"
  fi
  export JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null)"
  have java && ok "java: $(java -version 2>&1 | head -n1)" || warn "java not on PATH yet; open a new terminal."
}

setup_ides() {
  log "IDEs (VS Code + IntelliJ IDEA Community Edition)"
  # VS Code
  if brew list --cask visual-studio-code >/dev/null 2>&1; then ok "VS Code present"
  else opt brew install --cask visual-studio-code; fi
  # IntelliJ Community Edition. The standalone CE cask is 'intellij-idea-ce'
  # ('intellij-idea' is the paid Ultimate edition). Try CE; warn if the name drifted.
  if brew list --cask intellij-idea-ce >/dev/null 2>&1 || [ -d "/Applications/IntelliJ IDEA CE.app" ]; then
    ok "IntelliJ IDEA CE present"
  else
    brew install --cask intellij-idea-ce 2>/dev/null && ok "IntelliJ IDEA CE installed" \
      || warn "IntelliJ CE cask unavailable — get the free Community edition from https://www.jetbrains.com/idea/download (choose the Community .dmg)."
  fi
}

setup_gui_apps() {
  log "GUI apps via Homebrew Cask (LM Studio, Antigravity, Copilot CLI)"
  # These are .app bundles; cask drag-installs them. If a cask name has drifted,
  # the step warns and the final summary tells you the manual download URL.
  if brew list --cask lm-studio >/dev/null 2>&1; then ok "lm-studio present"
  else opt brew install --cask lm-studio; fi
  # Antigravity: try cask; fall back to manual instructions in summary.
  if brew list --cask antigravity >/dev/null 2>&1; then ok "antigravity present"
  else brew install --cask antigravity 2>/dev/null && ok "antigravity installed" \
       || warn "Antigravity cask unavailable — download the .dmg from https://antigravity.google (free preview)."; fi
  # GitHub Copilot CLI (free tier available; optional login later).
  if brew list copilot-cli >/dev/null 2>&1 || have copilot; then ok "copilot-cli present"
  else brew install copilot-cli 2>/dev/null && ok "copilot-cli installed" \
       || opt npm install -g @github/copilot; fi
}

# =============================================================================
#  PHASE 1 — OLLAMA + LOCAL MODELS
# =============================================================================
setup_ollama() {
  log "Ollama service + local models"
  # Persist the loaded-model cap so unified memory isn't overcommitted.
  if ! grep -q OLLAMA_MAX_LOADED_MODELS "$HOME/.zprofile" 2>/dev/null; then
    echo "export OLLAMA_MAX_LOADED_MODELS=$OLLAMA_MAX_LOADED" >> "$HOME/.zprofile"
  fi
  export OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_LOADED"
  if ! http_ok "http://localhost:$PORT_OLLAMA/api/tags"; then
    opt brew services start ollama
    for _ in $(seq 1 15); do http_ok "http://localhost:$PORT_OLLAMA/api/tags" && break; sleep 1; done
  fi
  http_ok "http://localhost:$PORT_OLLAMA/api/tags" && ok "Ollama up on :$PORT_OLLAMA" \
    || warn "Ollama not responding; run 'ollama serve' in another terminal, then re-run."
  local installed; installed="$(ollama list 2>/dev/null)"
  for entry in "${MODELS[@]}"; do
    local tag="${entry%%|*}" role="${entry#*|}"
    # A model is "present" only if ollama can actually show its manifest (guards against
    # a partially-downloaded blob from an interrupted earlier run).
    if printf "%s" "$installed" | grep -q "^${tag%%:*}" && ollama show "$tag" >/dev/null 2>&1; then
      ok "model present: $tag"
    else
      printf "    pulling %s (%s)\n" "$tag" "$role"
      ollama pull "$tag" || warn "pull failed for '$tag' — check the tag at ollama.com/library."
    fi
  done
}

# =============================================================================
#  PHASE 2 — PYTHON ENVS  (gateway venv + isolated Aider)
#  WHY TWO ENVS: Aider hard-pins an EXACT litellm version, while the LiteLLM proxy needs
#  a current litellm. In one venv they conflict and the gateway's litellm ends up broken
#  (this was the cause of the gateway being down). The fix:
#    - Gateway + dashboard  -> dedicated $WORKDIR/.venv  (litellm[proxy] + flask; NO aider)
#    - Aider                -> ISOLATED via `uv tool install` (its own env + its own pin)
# =============================================================================
# Gateway/dashboard packages — deliberately NO aider here so nothing pins litellm.
GW_PKGS='"litellm[proxy]" openai langfuse python-dotenv flask requests rich'
venv_ok() { [ -x "$WORKDIR/.venv/bin/python" ] && [ -x "$WORKDIR/.venv/bin/litellm" ] \
            && "$WORKDIR/.venv/bin/python" -c "import litellm, flask, requests" >/dev/null 2>&1; }
setup_python() {
  log "Gateway/dashboard Python env (litellm proxy + flask; Aider kept separate)"
  if venv_ok; then ok "Gateway venv healthy."
  else
    [ -d "$WORKDIR/.venv" ] && { warn "venv incomplete — rebuilding."; rm -rf "$WORKDIR/.venv"; }
    ( cd "$WORKDIR" && opt uv venv --python 3.12 .venv \
        && opt uv pip install --python "$WORKDIR/.venv/bin/python" $GW_PKGS )
    venv_ok && ok "Gateway venv ready (litellm proxy + flask)." \
            || warn "Gateway venv incomplete; re-run to retry (this is what the gateway needs)."
  fi

  log "Aider — isolated install via uv tool (its pinned litellm stays out of the gateway)"
  if have aider || [ -x "$HOME/.local/bin/aider" ]; then ok "Aider already installed."
  else
    # Official isolated method: aider gets its own python 3.12 and its own litellm pin.
    opt uv tool install --force --python python3.12 --with pip aider-chat@latest
    ( have aider || [ -x "$HOME/.local/bin/aider" ] ) && ok "Aider installed (isolated)." \
      || warn "Aider install incomplete; retry later: uv tool install aider-chat@latest"
  fi
  # Make sure uv tool's bin dir is on PATH for future shells.
  if ! grep -q '.local/bin' "$HOME/.zprofile" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
  fi
}

# =============================================================================
#  PHASE 3 — DOCKER (Colima) + web services
# =============================================================================
setup_colima() {
  log "Docker engine (Colima)"
  if docker_up; then ok "Docker already up."; return; fi
  opt colima start --cpu "$COLIMA_CPU" --memory "$COLIMA_MEM" --disk "$COLIMA_DISK"
  for _ in $(seq 1 25); do docker_up && break; sleep 1; done
  docker_up && ok "Docker up via Colima" || warn "Docker down; Open WebUI/SearXNG/Langfuse skipped (re-run later)."
}

setup_openwebui() {
  log "Open WebUI — local ChatGPT-style chat over your models (:$PORT_OPENWEBUI)"
  docker_up || { warn "Docker down; skipping."; return; }
  if container_running open-webui && http_ok "http://localhost:$PORT_OPENWEBUI/"; then ok "Open WebUI already running."; return; fi
  opt docker volume create open-webui
  # host.docker.internal lets the container reach Ollama running natively on the Mac.
  ensure_container open-webui docker run -d --name open-webui --restart unless-stopped \
    -p "127.0.0.1:$PORT_OPENWEBUI:8080" \
    -e OLLAMA_BASE_URL="http://host.docker.internal:$PORT_OLLAMA" \
    --add-host=host.docker.internal:host-gateway \
    -v open-webui:/app/backend/data \
    ghcr.io/open-webui/open-webui:main
  ok "Open WebUI starting -> http://localhost:$PORT_OPENWEBUI (create a local account on first open)."
}

searxng_ok() { http_ok "http://localhost:$PORT_SEARXNG/"; }
setup_searxng() {
  log "SearXNG — private web search (gives agents live, up-to-date knowledge) (:$PORT_SEARXNG)"
  docker_up || { warn "Docker down; skipping."; return; }
  if container_running searxng && searxng_ok; then ok "SearXNG already running."; return; fi
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
  ensure_container searxng docker run -d --name searxng --restart unless-stopped \
    -p "127.0.0.1:$PORT_SEARXNG:8080" -v "$SX:/etc/searxng" searxng/searxng:latest
  for _ in $(seq 1 20); do searxng_ok && break; sleep 1; done
  searxng_ok && ok "SearXNG up (JSON API: /search?q=...&format=json)" || warn "SearXNG slow; check lazydocker."
}

langfuse_ok() { http_ok "http://localhost:$PORT_LANGFUSE/api/public/health"; }
setup_langfuse() {
  log "Langfuse — agent trace/log dashboard (:$PORT_LANGFUSE)"
  docker_up || { warn "Docker down; skipping."; return; }
  local LF="$WORKDIR/langfuse"
  if langfuse_ok; then ok "Langfuse running."
  else
    [ -d "$LF/.git" ] && ( cd "$LF" && dc down >/dev/null 2>&1 || true )
    [ -d "$LF/.git" ] || opt git clone --depth=1 https://github.com/langfuse/langfuse.git "$LF"
    ( cd "$LF" && opt dc up -d )
    printf "Waiting for Langfuse"; for _ in $(seq 1 60); do langfuse_ok && break; printf "."; sleep 2; done; printf "\n"
    langfuse_ok && ok "Langfuse up." || warn "Langfuse slow to start; check later in lazydocker."
  fi
  # Re-run safe: if keys already saved and authenticate, skip the whole prompt.
  load_env
  local epk esk; epk="$(get_env LANGFUSE_PUBLIC_KEY)"; esk="$(get_env LANGFUSE_SECRET_KEY)"
  if [ -n "$epk" ] && [ -n "$esk" ] && \
     [ "$(curl -s -o /dev/null -w '%{http_code}' -u "$epk:$esk" "http://localhost:$PORT_LANGFUSE/api/public/projects" 2>/dev/null)" = "200" ]; then
    ok "Langfuse API keys already configured and valid — skipping."; return
  fi
  cat <<TUT

${c_cyn}#############  ACTION: LANGFUSE API KEYS  #############${c_reset}
  1. Open http://localhost:$PORT_LANGFUSE  -> Sign up (local account).
  2. Create an Organization, then a Project.
  3. Settings -> API Keys -> Create. Copy PUBLIC (pk-lf-...) and SECRET (sk-lf-...).
${c_cyn}######################################################${c_reset}
TUT
  press_enter
  local pk sk
  printf "%sPaste PUBLIC key (or 'skip'): %s" "$c_cyn" "$c_reset"; read -r pk
  case "$pk" in skip|SKIP|"") warn "Skipped Langfuse keys (dashboard will show services only)."; return ;; esac
  printf "%sPaste SECRET key: %s" "$c_cyn" "$c_reset"; read -r sk
  set_env LANGFUSE_PUBLIC_KEY "$pk"; set_env LANGFUSE_SECRET_KEY "$sk"
  set_env LANGFUSE_HOST "http://localhost:$PORT_LANGFUSE"; ok "Langfuse keys saved."
}

# =============================================================================
#  PHASE 4 — LiteLLM GATEWAY (one OpenAI-style endpoint over all local models)
# =============================================================================
setup_cloud_optional() {
  log "Optional BACKUP cloud model (Gemini free tier) — local stays the default brain"
  [ -n "$(get_env GEMINI_API_KEY)" ] && { ok "Gemini backup key already set."; return; }
  printf "Add an optional free Gemini key as a BACKUP for hard tasks? Local stays primary. [y/N] "
  read -r r; case "$r" in y|Y|yes) prompt_secret GEMINI_API_KEY "Gemini API key" validate_gemini tut_gemini ;; *) ok "Staying fully local (no cloud backup)." ;; esac
}

setup_litellm() {
  log "LiteLLM gateway (:$PORT_GATEWAY) — friendly model names; logs to Langfuse"
  load_env
  local CFG="$WORKDIR/litellm.config.yaml"
  # PRESERVE a hand-edited config. The script only writes a default if none exists,
  # so re-runs never clobber your custom litellm.config.yaml.
  if [ -f "$CFG" ]; then
    ok "Existing litellm.config.yaml found — keeping it as-is (not overwritten)."
    # Helpful nudge: Langfuse logging powers the dashboard's "recent activity" panel.
    if ! grep -q 'success_callback' "$CFG"; then
      warn "Your config has no Langfuse callback; the dashboard activity panel will stay empty."
      warn "To enable it, add at the end of $CFG:"
      printf '       litellm_settings:\n         success_callback: ["langfuse"]\n         failure_callback: ["langfuse"]\n'
    fi
  else
    warn "No litellm.config.yaml in $WORKDIR — writing a default (your alias names)."
    cat > "$CFG" <<'YAMLEOF'
model_list:
  # Accuracy-first, sized to fit 64GB. Names match the user's chosen aliases.
  - model_name: qwen3.5
    litellm_params: { model: ollama/qwen3.5:35b-a3b,   api_base: http://127.0.0.1:11434 }
  - model_name: qwen3.6-coder
    litellm_params: { model: ollama/qwen3.6:27b,       api_base: http://127.0.0.1:11434 }
  - model_name: qwen3-coder-next
    litellm_params: { model: ollama/qwen3-coder-next,  api_base: http://127.0.0.1:11434 }
  - model_name: devstral
    litellm_params: { model: ollama/devstral:24b,      api_base: http://127.0.0.1:11434 }
  - model_name: codestral
    litellm_params: { model: ollama/codestral:22b,     api_base: http://127.0.0.1:11434 }
  - model_name: qwen2.5vl
    litellm_params: { model: ollama/qwen2.5vl:7b,      api_base: http://127.0.0.1:11434 }
  - model_name: nomic-embed-text
    litellm_params: { model: ollama/nomic-embed-text,  api_base: http://127.0.0.1:11434 }
litellm_settings:
  success_callback: ["langfuse"]
  failure_callback: ["langfuse"]
  drop_params: true
  request_timeout: 1200   # accuracy-first: allow long generations from big models
YAMLEOF
    ok "Default litellm.config.yaml written."
  fi
  cat > "$WORKDIR/start_gateway.sh" <<SHEOF
#!/usr/bin/env bash
# Launched by launchd, so use ABSOLUTE paths (no reliance on cwd or login PATH).
set -a; [ -f "$WORKDIR/.env" ] && . "$WORKDIR/.env"; set +a
LITELLM="$WORKDIR/.venv/bin/litellm"
CONFIG="$WORKDIR/litellm.config.yaml"
if [ ! -x "\$LITELLM" ]; then
  echo "ERROR: \$LITELLM not found. Run setup_python (the gateway venv is missing)." >&2
  exit 1
fi
exec "\$LITELLM" --config "\$CONFIG" --port $PORT_GATEWAY --host 127.0.0.1
SHEOF
  chmod +x "$WORKDIR/start_gateway.sh"; ok "Gateway launcher written (absolute paths)."
}

# =============================================================================
#  PHASE 5 — CONTINUE (VS Code extension wired to local models)
# =============================================================================
setup_continue() {
  log "Continue — VS Code AI extension using your LOCAL models"
  if have code; then
    code --install-extension continue.continue >/dev/null 2>&1 && ok "Continue extension installed." \
      || warn "Could not auto-install; in VS Code, Extensions -> search 'Continue'."
  else
    warn "'code' CLI not on PATH yet. In VS Code run: Cmd+Shift+P -> 'Shell Command: Install code command', then re-run."
  fi
  mkdir -p "$HOME/.continue"
  if [ ! -f "$HOME/.continue/config.yaml" ]; then
    cat > "$HOME/.continue/config.yaml" <<'YAMLEOF'
name: Local AI
version: 1.0.0
models:
  - name: Coder (Qwen 3.6 27B — most accurate that fits 64GB)
    provider: ollama
    model: qwen3.6:27b
    roles: [chat, edit, apply]
  - name: Coder Next (Qwen3-Coder-Next — heavy, code-only)
    provider: ollama
    model: qwen3-coder-next
    roles: [chat, edit, apply]
  - name: Autocomplete (Codestral)
    provider: ollama
    model: codestral:22b
    roles: [autocomplete]
  - name: Embeddings
    provider: ollama
    model: nomic-embed-text
    roles: [embed]
YAMLEOF
    ok "Continue config written (~/.continue/config.yaml)."
  else ok "Continue config already exists."; fi
}

# =============================================================================
#  PHASE 6 — LIVE DASHBOARD (service health + recent agent activity)
# =============================================================================
write_dashboard() {
  log "Custom live dashboard (:$PORT_DASHBOARD)"
  local D="$WORKDIR/dashboard"; mkdir -p "$D"
  cat > "$D/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""Live status board: service health + recent agent traces from Langfuse."""
import os, requests
from flask import Flask, jsonify
from dotenv import load_dotenv
HOME = os.environ.get("AI_HOME", os.path.expanduser("~/ai-workstation"))
load_dotenv(os.path.join(HOME, ".env"))
LF = os.environ.get("LANGFUSE_HOST", "http://localhost:3000")
PK = os.environ.get("LANGFUSE_PUBLIC_KEY", ""); SK = os.environ.get("LANGFUSE_SECRET_KEY", "")
SERVICES = [
    ("Ollama (models)",     "http://localhost:11434/api/tags",         "http://localhost:11434"),
    ("LiteLLM (gateway)",   "http://localhost:4000/health/liveliness",            "http://localhost:4000"),
    ("Open WebUI (chat)",   "http://localhost:3001/",                  "http://localhost:3001"),
    ("SearXNG (web search)","http://localhost:8888/",                  "http://localhost:8888"),
    ("Langfuse (traces)",   "http://localhost:3000/api/public/health", "http://localhost:3000"),
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
        except Exception: pass
    return jsonify({"services": svc, "traces": traces})
PAGE = """<!doctype html><html><head><meta charset=utf-8><title>AI Workstation - Mission Control</title>
<style>
 :root{--bg:#0a0e14;--card:#121823;--line:#1e2a3a;--ink:#e6edf3;--dim:#7d8896;--up:#2ea043;--down:#f85149;--accent:#4c8dff}
 *{box-sizing:border-box} body{background:var(--bg);color:var(--ink);font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;padding:32px;max-width:1100px;margin:0 auto}
 h1{font-size:22px;margin:0 0 2px;letter-spacing:-.3px} .sub{color:var(--dim);font-size:13px;margin-bottom:26px}
 .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px;margin-bottom:30px}
 .card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px}
 .row{display:flex;align-items:center;gap:9px} .dot{height:9px;width:9px;border-radius:50%;flex:none}
 .up{background:var(--up);box-shadow:0 0 8px var(--up)} .down{background:var(--down)}
 .name{font-weight:600;font-size:14px} a{color:var(--accent);text-decoration:none;font-size:12px} a:hover{text-decoration:underline}
 .state{font-size:11px;text-transform:uppercase;letter-spacing:.5px;margin-left:auto} .s-up{color:var(--up)} .s-down{color:var(--down)}
 h3{font-size:14px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim);margin:0 0 12px}
 table{width:100%;border-collapse:collapse;font-size:13px} th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line)}
 th{color:var(--dim);font-weight:600;font-size:11px;text-transform:uppercase;letter-spacing:.5px} .muted{color:var(--dim)}
</style></head><body>
<h1>AI Workstation</h1><div class="sub">Mission control — auto-refreshes every 5s — everything runs locally on this Mac</div>
<div id="svc" class="grid"></div>
<h3>Recent agent activity</h3>
<table><thead><tr><th>When</th><th>Agent / call</th><th>Latency (s)</th></tr></thead>
<tbody id="tr"><tr><td colspan=3 class="muted">loading...</td></tr></tbody></table>
<script>
async function tick(){
 try{ const d=await (await fetch('/api/status')).json();
  document.getElementById('svc').innerHTML=d.services.map(s=>
   '<div class="card"><div class="row"><span class="dot '+(s.ok?'up':'down')+'"></span>'+
   '<span class="name">'+s.name+'</span><span class="state '+(s.ok?'s-up':'s-down')+'">'+(s.ok?'live':'down')+'</span></div>'+
   '<div style="margin-top:9px"><a href="'+s.url+'" target="_blank">'+s.url+'</a></div></div>').join('');
  document.getElementById('tr').innerHTML = d.traces.length ? d.traces.map(t=>
   '<tr><td class="muted">'+(t.time||'')+'</td><td>'+t.name+'</td><td>'+t.latency+'</td></tr>').join('')
   : '<tr><td colspan=3 class="muted">No traces yet — run an agent through the gateway.</td></tr>';
 }catch(e){}
}
tick(); setInterval(tick,5000);
</script></body></html>"""
@app.route("/")
def home(): return PAGE
if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8800, threaded=True)
PYEOF
  ok "Dashboard written."
}

# =============================================================================
#  PHASE 7 — ALWAYS-ON SERVICES (launchd)
# =============================================================================
install_launch_agent() {
  local label="${1:-}" prog="${2:-}" plist
  if [ -z "$label" ] || [ -z "$prog" ]; then warn "install_launch_agent: missing label/program — skipping."; return; fi
  plist="$LAUNCH_DIR/$label.plist"
  mkdir -p "$LAUNCH_DIR"; launchctl unload "$plist" >/dev/null 2>&1 || true
  cat > "$plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-lc</string><string>$prog</string></array>
  <key>EnvironmentVariables</key><dict><key>AI_HOME</key><string>$WORKDIR</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$WORKDIR/logs/$label.out.log</string>
  <key>StandardErrorPath</key><string>$WORKDIR/logs/$label.err.log</string>
</dict></plist>
PLISTEOF
  launchctl load "$plist" >/dev/null 2>&1 && ok "service loaded: $label" || warn "could not load $label"
}
setup_services() {
  log "Registering always-on services (launchd)"
  mkdir -p "$WORKDIR/logs"
  install_launch_agent "com.aiws.colima"    "/opt/homebrew/bin/colima start || true; while true; do sleep 86400; done"
  install_launch_agent "com.aiws.litellm"   "$WORKDIR/start_gateway.sh"
  install_launch_agent "com.aiws.dashboard" "$WORKDIR/.venv/bin/python $WORKDIR/dashboard/app.py"
  ok "Gateway + dashboard auto-start now and at login."
}

# =============================================================================
#  PHASE 8 — OPENCLAW (phone-driven agent) + Peekaboo (GUI control)
# =============================================================================
collect_chat_tokens() {
  log "Telegram token for your phone-driven agent"
  prompt_secret TELEGRAM_BOT_TOKEN "Telegram bot token" validate_telegram tut_telegram
}
openclaw_ok() { have openclaw && openclaw --version >/dev/null 2>&1; }
setup_openclaw() {
  log "OpenClaw — the agent you command from Telegram"
  have npm || { warn "npm missing; skipping OpenClaw."; return; }
  if openclaw_ok; then ok "OpenClaw present ($(openclaw --version 2>/dev/null))."
  else
    npm ls -g openclaw >/dev/null 2>&1 && opt npm uninstall -g openclaw
    # Known macOS gotcha: the 'sharp' image dep can fail if Homebrew libvips is present.
    # The env var forces prebuilt binaries and avoids the native build.
    SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install -g openclaw@latest \
      || opt npm install -g openclaw@latest
  fi
  openclaw_ok && ok "openclaw $(openclaw --version 2>/dev/null)" || { warn "OpenClaw install failed; run 'openclaw doctor' to diagnose, then re-run."; return; }
  cat <<TUT

${c_cyn}#############  FINISH OPENCLAW (interactive)  #############${c_reset}
 Run the official onboarding (the script can launch it for you below):
     ${c_grn}openclaw onboard --install-daemon${c_reset}
 In onboarding:
   - Provider: ollama   Model: qwen3.5:35b-a3b   Endpoint: http://localhost:$PORT_OLLAMA
   - Channel: Telegram -> paste TELEGRAM_BOT_TOKEN from $WORKDIR/.env
   - For Mac control, macOS will prompt for permissions. Grant ONLY what you want:
       System Settings > Privacy & Security > Accessibility   (enable OpenClaw)
       System Settings > Privacy & Security > Screen Recording (enable OpenClaw)
   These TCC toggles are protected by macOS and CANNOT be set by a script.

 SECURITY: keep the human-approval rule in agents/SOUL.orchestrator.md. Do NOT install
 third-party OpenClaw "skills" without reading their source — a 2026 audit found many
 community skills contained vulnerabilities or malware.
${c_cyn}#########################################################${c_reset}
TUT
  printf "Run 'openclaw onboard --install-daemon' now? [Y/n] "
  read -r r; case "$r" in n|N|no) warn "Skipped — run it yourself when ready." ;; *) openclaw onboard --install-daemon || warn "Onboarding exited; re-run anytime." ;; esac
}
setup_peekaboo() {
  log "Peekaboo — lets the agent see the screen & control mouse/keyboard/apps (optional)"
  printf "Install Peekaboo (needed for GUI/app control, goal #4)? [y/N] "
  read -r r; case "$r" in y|Y|yes) ;; *) ok "Skipped (agent can still do shell/file/code tasks)."; return ;; esac
  brew install steipete/tap/peekaboo 2>/dev/null && ok "Peekaboo installed." \
    || warn "Auto-install failed; try: brew install steipete/tap/peekaboo  (docs: https://peekaboo.boo)"
  warn "After install, grant Peekaboo/OpenClaw Accessibility + Screen Recording in System Settings."
}

# =============================================================================
#  PHASE 9 — WORKSPACE SCAFFOLD (agent SOUL files, web-search tool, README)
# =============================================================================
scaffold_workspace() {
  log "Workspace scaffold (agent rules, web-search helper, README)"
  local A="$WORKDIR/agents"; mkdir -p "$A"
  cat > "$A/SOUL.orchestrator.md" <<'MDEOF'
# SOUL: Orchestrator
You are the user's lead AI operator, running locally on their Mac. The user commands you
over Telegram. You plan, delegate to sub-agents, control the Mac when needed, and report back.

## HARD RULES (never break)
- LOCAL FIRST. Use the local models (via the gateway at http://localhost:4000) for every
  task by default. Only use a cloud/backup model (the "cloud" alias, Antigravity, or
  Copilot) when the user explicitly asks you to escalate. Never send data off-machine on
  your own initiative.
- BEFORE any high-impact action — running shell that changes the system, installing
  software, spinning up containers, deleting/overwriting files, controlling mouse/keyboard,
  opening apps, posting anything, or spending money — summarise the plan in ONE message and
  WAIT for the user to reply "yes"/"approve". Read-only analysis needs no approval.
- For anything "latest" or time-sensitive, USE the web-search tool (SearXNG at
  http://localhost:8888) — your built-in knowledge has a cutoff.
- Prefer real APIs and code over GUI clicking. Only fall back to mouse/keyboard control
  (Peekaboo) when there is no scriptable path. GUI control is brittle — verify with a
  screenshot after each step and stop if the screen isn't what you expected.

## Sub-agents (call by model alias on the gateway at http://localhost:4000)
- qwen3.6-coder    : qwen3.6:27b — writes web apps, scripts, services (primary coder)
- qwen3-coder-next : heavy agentic coding; multi-file, repo-level (run alone, ~46GB)
- devstral         : multi-file edits, runs tests, tool calls
- qwen2.5vl        : reads screenshots to locate UI elements before clicking
- qwen3.5          : planning / routing (orchestrator brain)

## Style: concise. State assumptions. Surface risks. Ask one question only when blocked.
## Accuracy over speed: prefer the most accurate model (qwen3.6-coder for code,
## qwen3.5 for reasoning) even if slower.
MDEOF
  cat > "$A/websearch.py" <<'PYEOF'
#!/usr/bin/env python3
"""Private web search via local SearXNG -> up-to-date answers for agents.
Usage: python websearch.py "your query"
Wrap as an OpenClaw skill so the agent can call it as a tool."""
import sys, requests
q = " ".join(sys.argv[1:]) or "latest local LLM news"
try:
    r = requests.get("http://localhost:8888/search", params={"q": q, "format": "json"}, timeout=8)
    for it in r.json().get("results", [])[:8]:
        print("- " + it.get("title", "")); print("  " + it.get("url", "")); print("  " + it.get("content", "")[:200])
except Exception as e:
    print("search failed:", e)
PYEOF
  chmod +x "$A/websearch.py"
  cat > "$WORKDIR/README_AI.md" <<MDEOF
# Local AI workstation — quick reference
Everything lives in \`$WORKDIR\`. Secrets in \`.env\` (chmod 600).

## What does what (mapped to your 5 goals)
| Goal | Tool | How |
|---|---|---|
| 1. Build apps / scripts | Aider, Continue (VS Code), Antigravity, Copilot CLI | local models write code |
| 2. Up-to-date answers | Open WebUI + SearXNG | chat that searches the live web |
| 3. Command from phone | OpenClaw + Telegram | DM your bot; it executes tasks |
| 4. Control the Mac/GUI | OpenClaw + Peekaboo | mouse/keyboard/app control (supervise!) |
| 5. Monitor everything | Live dashboard + Langfuse | health + agent activity |

## URLs (all local-only)
- Dashboard      http://localhost:$PORT_DASHBOARD
- Open WebUI     http://localhost:$PORT_OPENWEBUI   (chat + web search)
- Langfuse       http://localhost:$PORT_LANGFUSE    (agent traces)
- SearXNG        http://localhost:$PORT_SEARXNG     (web search API)
- LiteLLM        http://localhost:$PORT_GATEWAY     (model routing)
- Ollama         http://localhost:$PORT_OLLAMA      (model server)

## Build code (goal 1)
- Terminal:  \`cd <project> && aider --model ollama/qwen3.6:27b\`
- VS Code:   open the Continue panel; it uses your local models.
- Antigravity: open the app (free Gemini 3 preview) for autonomous multi-file agents.
- Copilot CLI: run \`copilot\` in a repo, then \`/login\` (free tier has limited credits).

## Up-to-date answers (goal 2)
Open WebUI -> turn on Web Search in Settings, point it at SearXNG
(query URL: http://localhost:$PORT_SEARXNG/search?q=<q>&format=json).

## Command from phone + control Mac (goals 3 & 4)
DM your Telegram bot. Example: "spin up a MySQL container, scaffold a library
microservice, and create an Angular front end." The agent will PROPOSE a plan and wait
for your "approve" before acting. GUI control (opening apps, moving the mouse) is the
least reliable part — watch it and keep approvals on.

## Monitor (goal 5)
Dashboard shows live service health + recent agent runs. Langfuse has full traces.
Containers: \`lazydocker\`.

## Manage services
- Status:  \`bash setup_ai_workstation.sh --status\`
- Start:   \`--start\`   Stop: \`--stop\`   Restart: \`--restart\`   Reset: \`--reset\`
- Auto-start at login via launchd. Stopping preserves all data/models/configs.

## Notes & honest limits
- Local models are strong but won't fully match frontier cloud coders on hard agentic work.
- If an \`ollama pull\` failed, the tag drifted — check https://ollama.com/library and edit
  the MODELS array + litellm.config.yaml aliases.
- SECURITY: never install third-party OpenClaw skills without reading the source. Keep the
  approval gate in agents/SOUL.orchestrator.md. Never expose any port to the public internet.
MDEOF
  ok "Workspace ready at $WORKDIR/agents"
}

# =============================================================================
#  SERVICE CONTROL
# =============================================================================
LABELS="com.aiws.colima com.aiws.litellm com.aiws.dashboard"
brew_env() { [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null; }
state()   { "$@" >/dev/null 2>&1 && echo up || echo down; }
svc_row() { if [ "$2" = up ]; then printf "  %-30s %sRUNNING%s\n" "$1" "$c_grn" "$c_reset"; else printf "  %-30s %sSTOPPED%s\n" "$1" "$c_red" "$c_reset"; fi; }
svc_status() {
  brew_env; log "Service status"
  svc_row "Docker engine (Colima)"        "$(state docker_up)"
  svc_row "Ollama        :$PORT_OLLAMA"    "$(state http_ok "http://localhost:$PORT_OLLAMA/api/tags")"
  svc_row "LiteLLM gw    :$PORT_GATEWAY"    "$(state http_ok "http://localhost:$PORT_GATEWAY/health/liveliness")"
  svc_row "Open WebUI    :$PORT_OPENWEBUI"  "$(state http_ok "http://localhost:$PORT_OPENWEBUI/")"
  svc_row "SearXNG       :$PORT_SEARXNG"    "$(state searxng_ok)"
  svc_row "Langfuse      :$PORT_LANGFUSE"   "$(state langfuse_ok)"
  svc_row "Live dashboard:$PORT_DASHBOARD"  "$(state http_ok "http://localhost:$PORT_DASHBOARD/")"
  printf "\n  Dashboard: %shttp://localhost:%s%s\n" "$c_cyn" "$PORT_DASHBOARD" "$c_reset"
}
svc_start() {
  brew_env; log "Starting all services"
  opt colima start; for _ in $(seq 1 25); do docker_up && break; sleep 1; done
  opt brew services start ollama
  if docker_up; then
    docker start open-webui searxng >/dev/null 2>&1 || true
    [ -d "$WORKDIR/langfuse" ] && ( cd "$WORKDIR/langfuse" && opt dc up -d )
  fi
  for l in $LABELS; do launchctl load "$LAUNCH_DIR/$l.plist" >/dev/null 2>&1 || true; done
  ok "Start requested. Verify: bash setup_ai_workstation.sh --status"
}
svc_stop() {
  brew_env; log "Stopping all services (data/models/configs preserved)"
  for l in $LABELS; do launchctl unload "$LAUNCH_DIR/$l.plist" >/dev/null 2>&1 || true; done
  if docker_up; then
    [ -d "$WORKDIR/langfuse" ] && ( cd "$WORKDIR/langfuse" && dc stop >/dev/null 2>&1 || true )
    docker stop open-webui searxng >/dev/null 2>&1 || true
  fi
  opt brew services stop ollama; opt colima stop; ok "All services stopped."
}
do_reset() {
  printf "%sRemove containers, services, OpenClaw config, and %s? [y/N] %s" "$c_yel" "$WORKDIR" "$c_reset"
  read -r r; case "$r" in y|Y|yes) ;; *) echo "Aborted."; exit 0 ;; esac
  for l in $LABELS; do launchctl unload "$LAUNCH_DIR/$l.plist" >/dev/null 2>&1 || true; rm -f "$LAUNCH_DIR/$l.plist"; done
  if docker_up; then
    [ -d "$WORKDIR/langfuse" ] && ( cd "$WORKDIR/langfuse" && dc down -v >/dev/null 2>&1 || true )
    docker rm -f open-webui searxng >/dev/null 2>&1 || true
    docker volume rm open-webui >/dev/null 2>&1 || true
  fi
  npm ls -g openclaw >/dev/null 2>&1 && opt npm uninstall -g openclaw
  rm -rf "$HOME/.openclaw" "$WORKDIR"
  ok "Reset complete. Homebrew, Xcode CLT, GUI apps, Ollama models, and Colima left intact."
  echo "  (To also remove models/engine: brew services stop ollama; colima delete; brew uninstall ollama colima ...)"
  exit 0
}

# =============================================================================
#  FINAL SUMMARY
# =============================================================================
summary() {
  load_env
  brew_env
  local tg; tg="$(get_env TELEGRAM_BOT_TOKEN)"; local tgs; [ -n "$tg" ] && tgs="configured" || tgs="(not set)"
  local gem; gem="$(get_env GEMINI_API_KEY)"; local gems; [ -n "$gem" ] && gems="configured (backup)" || gems="(not set — staying fully local)"
  local lfk; lfk="$(get_env LANGFUSE_PUBLIC_KEY)"; local lfs; [ -n "$lfk" ] && lfs="configured" || lfs="(not set)"
  # live check helper for the summary
  up() { "$@" >/dev/null 2>&1 && printf "%sLIVE%s" "$c_grn" "$c_reset" || printf "%sdown%s" "$c_red" "$c_reset"; }

  cat <<SUM

${c_grn}===================================================================${c_reset}
${c_grn}              INSTALL COMPLETE — SUMMARY                            ${c_reset}
${c_grn}===================================================================${c_reset}
Workspace:  $WORKDIR
Reference:  $WORKDIR/README_AI.md   (full how-to)
Secrets:    $WORKDIR/.env           (chmod 600 — keep private)

${c_cyn}-------------------------------------------------------------------
 1) WHAT WAS INSTALLED
-------------------------------------------------------------------${c_reset}
 System & dev tools
   • Homebrew, Xcode Command Line Tools
   • node $(node -v 2>/dev/null), uv (python), git, jq, wget, lazydocker
   • Java (Temurin): $(java -version 2>&1 | head -n1)
   • IDEs: VS Code$( [ -d "/Applications/IntelliJ IDEA CE.app" ] && echo ", IntelliJ IDEA CE" || echo " (IntelliJ CE — see README if missing)")
 AI engine (LOCAL — your primary brain)
   • Ollama + models: $(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | paste -sd, - 2>/dev/null)
 Local coding tools
   • Aider (terminal pair-programmer, isolated via uv tool — run 'aider')
   • Continue (VS Code extension, config at ~/.continue/config.yaml)
 Backup / cloud coding tools (used only when you choose them)
   • VS Code, LM Studio (GUI)
   • Antigravity $( [ -d "/Applications/Antigravity.app" ] && echo "(installed)" || echo "(install .dmg from antigravity.google if missing)")
   • GitHub Copilot CLI $( have copilot && echo "(installed — run 'copilot' then /login)" || echo "(see README)")
 Phone-driven agent & GUI control
   • OpenClaw $( openclaw_ok && echo "$(openclaw --version 2>/dev/null)" || echo "(re-run if it failed — 'openclaw doctor')")
   • Peekaboo $( have peekaboo && echo "(installed)" || echo "(optional; not installed)")
 Containers (via Colima/Docker)
   • Open WebUI, SearXNG, Langfuse

${c_cyn}-------------------------------------------------------------------
 2) WHAT WAS CONFIGURED
-------------------------------------------------------------------${c_reset}
   • LiteLLM gateway → model aliases (qwen3.5, qwen3.6-coder, qwen3-coder-next,
     devstral, codestral, qwen2.5vl); logs every call to Langfuse.   Cloud backup: $gems
   • Ollama capped at $OLLAMA_MAX_LOADED loaded model(s) to protect unified memory.
   • Continue + Aider pointed at local models (no data leaves the Mac).
   • Open WebUI pointed at Ollama (enable Web Search in its Settings to use SearXNG).
   • Telegram bot: $tgs        Langfuse API keys: $lfs
   • Agent rules in $WORKDIR/agents/SOUL.orchestrator.md (LOCAL-FIRST + approval gate).
   • Auto-start at login (launchd): Colima, LiteLLM gateway, dashboard.

${c_cyn}-------------------------------------------------------------------
 3) WHAT'S RUNNING RIGHT NOW   (all local-only)
-------------------------------------------------------------------${c_reset}
   Live dashboard   http://localhost:$PORT_DASHBOARD    [$(up http_ok "http://localhost:$PORT_DASHBOARD/")]   services + recent agent activity
   Open WebUI       http://localhost:$PORT_OPENWEBUI    [$(up http_ok "http://localhost:$PORT_OPENWEBUI/")]   chat with web search
   Langfuse         http://localhost:$PORT_LANGFUSE    [$(up langfuse_ok)]   agent traces / logs
   SearXNG          http://localhost:$PORT_SEARXNG    [$(up searxng_ok)]   private web search
   LiteLLM gateway  http://localhost:$PORT_GATEWAY    [$(up http_ok "http://localhost:$PORT_GATEWAY/health/liveliness")]   model routing
   Ollama           http://localhost:$PORT_OLLAMA   [$(up http_ok "http://localhost:$PORT_OLLAMA/api/tags")]   local models

${c_cyn}-------------------------------------------------------------------
 4) NEXT STEPS
-------------------------------------------------------------------${c_reset}
   1. Open the dashboard:  http://localhost:$PORT_DASHBOARD
   2. Open WebUI → Settings → enable Web Search → point at SearXNG (goal: fresh answers).
   3. If you skipped it:  openclaw onboard --install-daemon  (provider ollama, model qwen3.5:35b-a3b).
   4. For Mac/GUI control: System Settings → Privacy & Security → grant OpenClaw/Peekaboo
      Accessibility + Screen Recording (macOS-protected; can't be scripted).
   5. Code now:  cd <repo> && aider --model ollama/qwen3.6:27b
   6. DM your Telegram bot:  "web-search today's date and tell me, to prove search works."

${c_cyn}-------------------------------------------------------------------
 5) MANAGING / RE-RUNNING
-------------------------------------------------------------------${c_reset}
   • Re-run this script anytime — healthy steps are skipped, broken ones are repaired.
   • Status:  bash setup_ai_workstation.sh --status
   • Start | Stop | Restart | Reset:  --start | --stop | --restart | --reset
   • Auto-start at login is on. Stopping preserves all data, models, and configs.

${c_yel}-------------------------------------------------------------------
 HONEST LIMITS
-------------------------------------------------------------------${c_reset}
   • GUI/app control (mouse, opening apps) is the least reliable part of any agent today
     and local models drive it worse than frontier cloud models — supervise; keep approvals on.
   • Free local coders get close to, but won't fully match, frontier cloud coders on hard
     multi-step work. Reach for Antigravity / Copilot (backup) when you need more muscle.
   • SECURITY: never install third-party OpenClaw "skills" without reading the source first;
     never expose any of these ports to the public internet.
${c_grn}===================================================================${c_reset}
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
  setup_homebrew
  setup_core_tools
  setup_java
  setup_ides
  setup_gui_apps
  setup_ollama
  setup_python
  setup_colima
  setup_openwebui
  setup_searxng
  setup_langfuse
  setup_cloud_optional
  setup_litellm
  setup_continue
  write_dashboard
  setup_services
  collect_chat_tokens
  setup_openclaw
  setup_peekaboo
  scaffold_workspace
  summary
}
main "$@"
