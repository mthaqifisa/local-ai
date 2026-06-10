# Local AI Workstation

A single shell script that turns a **brand-new MacBook Pro (Apple Silicon)** into a complete, **free, local-first AI agent workstation** — local models, a self-healing coding loop, browser automation, monitoring dashboards, and a chat-driven main agent you control from Telegram/Discord. No paid APIs required, and everything runs on your own machine.

Built and tested against a MacBook Pro **M5 Pro / 64 GB**, but it works on any Apple Silicon Mac with enough RAM (see [Adjusting for your hardware](#adjusting-for-your-hardware)).

---

## What it does

The script (`setup_local_ai.sh`) bootstraps everything from a bare macOS account:

- Installs the base toolchain (Xcode Command Line Tools, optional Rosetta 2, Homebrew).
- Installs local LLMs that run on the Apple GPU via **Ollama**.
- Stands up a private model gateway, monitoring dashboards, and a web-search engine — all as local services.
- Installs **OpenClaw** as the main agent: you talk to it on Telegram/Discord, it plans work, controls the shell/files/browser, and delegates to sub-agents.
- Scaffolds a workspace with agent instructions, a self-healing dev loop, a browser helper, and a web-search tool.
- Pauses at each point where it needs a token and walks you through getting it.

It is **re-runnable** (safe to run again; finished steps are skipped, broken ones are repaired) and ships with **start/stop/status** controls and a full **reset**.

---

## Prerequisites

- A Mac with **Apple Silicon** (M-series).
- macOS that's reasonably current. A fresh Mac ships with **bash 3.2** — that's fine, the script handles it.
- An internet connection. The models are **several GB**, so use good Wi-Fi and leave time.
- Your user account password (Homebrew asks for it once).
- Roughly **40–60 GB free disk** for models, the Docker VM, and containers.

You do **not** need Homebrew, Docker, Python, or anything else installed beforehand — the script installs it all.

---

## How to run it

1. Put `setup_local_ai.sh` in a folder.
2. Open **Terminal** and `cd` into that folder.
3. Run it with **bash** (not `sh`, and don't double-click):

   ```bash
   bash setup_local_ai.sh
   ```

   > If you renamed the file (e.g. `setup.sh`), use that name instead.

The run is interactive and fairly long. Stay nearby — it pauses a few times to walk you through getting tokens; you follow the on-screen steps, paste the value, and it continues. If it stops or you close the window, just run the same command again.

When it finishes it prints a summary with every local URL and the management commands. The first thing to open is the dashboard at **http://localhost:8800**.

### Commands

| Command | What it does |
|---|---|
| `bash setup_local_ai.sh` | Install / repair everything (safe to re-run) |
| `bash setup_local_ai.sh --status` | Show which services are up/down |
| `bash setup_local_ai.sh --start` | Start all services |
| `bash setup_local_ai.sh --stop` | Stop all services (data preserved) |
| `bash setup_local_ai.sh --restart` | Stop then start everything |
| `bash setup_local_ai.sh --reset` | Remove everything the script created (clean slate) |
| `bash setup_local_ai.sh --help` | Print the header / usage |

---

## Tokens you'll be asked for

The script pauses and explains each of these when it needs them. You can type `skip` for the optional ones.

| Token | Where it comes from | Required? |
|---|---|---|
| **Langfuse keys** (public + secret) | Sign up in your browser at the local Langfuse (`localhost:3000`), create a project, then Settings → API Keys | Yes (for tracing) |
| **Telegram bot token** | Telegram → `@BotFather` → `/newbot` | Recommended |
| **Discord bot token** | Discord Developer Portal → New Application → Bot → Reset Token | Optional |
| **Google Gemini key** | `aistudio.google.com/apikey` (free tier) | Optional cloud model |

Tokens are saved to `~/local-ai/.env` (permissions locked to your user). On a re-run, ones that are already present and valid are not asked for again.

---

## What gets installed

**Base & tools**

- Xcode Command Line Tools, optional Rosetta 2, Homebrew
- `ollama`, `colima` + `docker` + `docker-compose`, `node`, `uv` (Python), `git`, `jq`, `lazydocker`

**Local models (via Ollama, on the Apple GPU)**

| Alias | Model | Role |
|---|---|---|
| orchestrator | `qwen3:32b` | lead reasoning / planning brain |
| coder | `devstral` | agentic coding + self-healing loop |
| autocomplete | `codestral` | fast code completion |
| vision | `qwen2.5vl:7b` | reads screenshots for GUI control |
| router | `qwen3:8b` | cheap/fast routing of small tasks |
| (embeddings) | `nomic-embed-text` | memory / retrieval |

> Model tags drift over time. If a pull fails, the tag changed — see [Troubleshooting](#troubleshooting).

**Services (all bound to localhost only)**

| Service | URL | Purpose |
|---|---|---|
| Live dashboard | http://localhost:8800 | service health + recent agent activity, auto-refreshing |
| Langfuse | http://localhost:3000 | detailed agent traces, logs, latency, token usage |
| Portainer | http://localhost:9000 | web GUI to monitor / restart Docker containers |
| SearXNG | http://localhost:8888 | private web search → gives agents up-to-date knowledge |
| LiteLLM gateway | http://localhost:4000 | one OpenAI-compatible endpoint over the local models; logs to Langfuse |
| Ollama | http://localhost:11434 | local model server |

**Agent & extras**

- **OpenClaw** — the main agent (Telegram/Discord, shell/files/browser, scheduling, sub-agents)
- **Peekaboo** (optional) — macOS screenshot + GUI automation so agents can "see" and click
- **Workspace** at `~/local-ai/` (see below)

---

## How it fits together

```
                 you (Telegram / Discord)
                          │
                     ┌────▼─────┐      delegates to sub-agents
                     │ OpenClaw │      (coder / web / vision / router)
                     │  agent   │
                     └────┬─────┘
              calls models │            uses tools
                           ▼                  │
                  ┌──────────────┐            ├── SearXNG  (live web search)
                  │   LiteLLM    │            ├── browser_helper.py (browser-use)
                  │   gateway    │            └── shell / files
                  └──────┬───────┘
                  routes │ + logs every call
            ┌────────────┼───────────────┐
            ▼                             ▼
       ┌─────────┐                  ┌──────────┐
       │ Ollama  │                  │ Langfuse │  ◄── visible in the :8800 dashboard
       │ (models)│                  │ (traces) │      and Portainer (containers)
       └─────────┘                  └──────────┘
```

- **Ollama** runs the models on the GPU. **LiteLLM** puts a single, friendly endpoint in front of them (so "coder", "vision", etc. are just names) and logs every call to **Langfuse**.
- **OpenClaw** is the brain you talk to. It uses the gateway for thinking and tools (search, browser, shell) for acting.
- You watch everything in three places: the **live dashboard** (quick health + activity), **Langfuse** (deep traces), and **Portainer** (the Docker containers).

---

## The workspace (`~/local-ai/`)

| Path | What it is |
|---|---|
| `.env` | your tokens and keys (locked to your user) |
| `agents/SOUL.orchestrator.md` | instructions for the main agent, incl. the human-approval rule |
| `agents/SOUL.coder.md` | instructions for the coding sub-agent |
| `agents/websearch.py` | private web search via SearXNG (wrap as an OpenClaw skill) |
| `agents/selfheal.py` | self-healing dev loop: generate → test → fix → repeat |
| `agents/browser_helper.py` | general browser automation (draft-then-confirm by default) |
| `dashboard/app.py` | the live status dashboard |
| `litellm.config.yaml` | the model gateway config (edit to add/rename models) |
| `langfuse/`, `searxng/` | the self-hosted services |
| `logs/` | service logs |
| `README_LOCAL_AI.md` | a short in-workspace quick reference |

---

## Daily use

1. Open the dashboard at **http://localhost:8800** to confirm everything is green.
2. DM your **Telegram bot** (or the bot in your Discord server) and talk to your agent. A good first test: ask it to introduce its sub-agents and to **web-search something current** to prove the search tool works.
3. Try the helpers (the gateway must be running):

   ```bash
   cd ~/local-ai && source .venv/bin/activate
   python agents/websearch.py "latest local LLM benchmarks"
   python agents/selfheal.py "write fizzbuzz(n) in app.py" "python -m pytest -q"
   python agents/browser_helper.py "https://example.com/careers"   # draft mode
   ```

   The browser helper **does not submit** by default; set `ALLOW_SUBMIT=1` only after you've reviewed what it will do and the site permits automation.

Services auto-start at login, so this is all available after a reboot. Use `--status` / `--stop` / `--start` for manual control.

---

## Re-running, repair, and reset

- **Re-run anytime.** Each step checks whether it already succeeded. If it did, it's skipped. If it's half-done or broken, the script rolls that piece back and redoes it. This makes it safe to run again after a failure, a reboot, or an interruption.
- **Reset** with `--reset` removes the containers, services, workspace, and OpenClaw for a clean slate. It deliberately leaves Homebrew, Xcode CLT, the Ollama models, and Colima in place (those are shared/expensive). The reset output tells you how to remove those too if you really want to.

---

## Troubleshooting

**`syntax error near unexpected token '('`**
You're either running it with `sh` instead of `bash`, or on a fresh Mac's bash 3.2. Run it with `bash setup_local_ai.sh`. The current script already handles bash 3.2; if you still see this, verify your file is intact:

```bash
bash -n setup_local_ai.sh   # prints nothing if the file parses cleanly
```

If that names a line, your download was likely corrupted or has Windows line endings — re-download, or normalize line endings with `tr -d '\r' < setup_local_ai.sh > fixed.sh && mv fixed.sh setup_local_ai.sh`.

**An `ollama pull` failed**
The model tag changed since this was written. Check the current tags at https://ollama.com/library, then edit the `MODELS=( … )` array near the top of the script (and the matching alias in `~/local-ai/litellm.config.yaml`) and re-run.

**The agent can't control the Mac (clicks/keyboard/screenshots do nothing)**
macOS **Accessibility** and **Screen Recording** permissions can only be granted by you in the GUI — no script can set them. Open **System Settings → Privacy & Security**, then enable OpenClaw (and Peekaboo if installed) under **Accessibility** and **Screen Recording**. Grant only what you're comfortable with.

**Langfuse is slow to come up / a service looks down**
The first start of the Docker services can take a couple of minutes. Check container status and logs in **Portainer** (http://localhost:9000), or run `bash setup_local_ai.sh --status`.

**Docker commands fail / "Cannot connect to the Docker daemon"**
The Docker engine (Colima) isn't running. Start it with `colima start`, or just run `bash setup_local_ai.sh --start`.

---

## Adjusting for your hardware

The default model set assumes ~64 GB of unified memory. On a Mac with less RAM, the large `qwen3:32b` orchestrator may be too big. Edit the `MODELS=( … )` array near the top of the script to use smaller variants (for example a 14B or 8B orchestrator), and update the matching `model:` lines in `~/local-ai/litellm.config.yaml`. You can also tune the Docker VM size via the `COLIMA_CPU` / `COLIMA_MEM` / `COLIMA_DISK` variables in the same config block.

---

## Cost

Everything in the default setup is **free and open-source**, and runs locally. The only optional paid-ish piece is the cloud model step, which uses Google Gemini's **free tier** (rate-limited, no charge) and is entirely optional — skip it and you stay 100% local.

---

## Safety & limitations (please read)

- **No agent is flawless** — especially desktop/GUI control and open-web automation. You supervise it, and you improve it over time. Keep the **human-approval rule** in `agents/SOUL.orchestrator.md`: the agent must summarize and wait for your "yes" before any high-impact action (sending messages, deleting/overwriting files, installing software, submitting forms, spending money, controlling the mouse/keyboard).
- **Local models have a fixed knowledge cutoff.** Their "up-to-dateness" comes from the **SearXNG** search tool, not from the model itself.
- **Respect each site's terms of service** when automating the browser. Some sites (LinkedIn, for example) forbid automated actions and may ban accounts — the browser helper defaults to *draft-then-confirm* so you make the final click on such sites.
- **Keep it local.** All services bind to `localhost`. Don't expose these ports to the public internet, and review the source of any community OpenClaw skill before installing it.
- **Verify official sources.** Some of these projects have scam look-alikes. Trust only the official sources listed in the script header.

---

## Official sources

- **OpenClaw** — https://openclaw.ai · https://github.com/openclaw/openclaw
- **Peekaboo** — https://peekaboo.sh · https://github.com/openclaw/Peekaboo
- **Langfuse** — https://github.com/langfuse/langfuse
- **SearXNG** — https://github.com/searxng/searxng
- **Portainer** — https://github.com/portainer/portainer
- **Ollama** — https://ollama.com (model tags: https://ollama.com/library)
- **LiteLLM** — https://github.com/BerriAI/litellm
- **browser-use** — https://github.com/browser-use/browser-use
- **Colima** — https://github.com/abiosoft/colima
