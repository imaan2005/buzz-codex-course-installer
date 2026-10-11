#!/usr/bin/env bash
set -Eeuo pipefail

# Installs a four-agent Codex outreach team beside an existing Buzz relay on an
# Ubuntu/Debian VPS. The existing Buzz relay containers are not modified.

INSTALL_ROOT="/opt/buzz-codex-team"
ENV_ROOT="/etc/buzz-codex-team"
AGENT_IMAGE="buzz-codex-team:local"
SEED_AUTH_VOLUME="buzz-codex-auth-seed"
SPRIG_IMAGE="${SPRIG_IMAGE:-}"
KEEPALIVE_PID=""
FRESH_INSTALL=0

SLUGS=(researcher writer reviewer sender)
NAMES=("NYC Roofing Researcher" "Outreach Writer" "Fact and Outreach Reviewer" "Campaign Manager")

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
disable_bracketed_paste() {
  # A TUI used earlier in the same terminal can leave bracketed-paste mode on.
  # Plain Bash read prompts would otherwise receive ESC[200~/ESC[201~ as text.
  [[ -t 1 ]] && printf '\033[?2004l'
}
clean_pasted_input() {
  local value="$1"
  value="${value//$'\033[200~'/}"
  value="${value//$'\033[201~'/}"
  printf '%s' "$value"
}
stop_connection_keepalive() {
  if [[ -n "${KEEPALIVE_PID:-}" ]]; then
    kill "$KEEPALIVE_PID" 2>/dev/null || true
    wait "$KEEPALIVE_PID" 2>/dev/null || true
    KEEPALIVE_PID=""
  fi
}
start_connection_keepalive() {
  local message="$1"
  stop_connection_keepalive
  (
    while sleep 20; do
      printf '\n[connection active] %s\n' "$message"
    done
  ) &
  KEEPALIVE_PID=$!
}
on_error() {
  stop_connection_keepalive
  printf '\nSetup failed near line %s.\nThe existing Buzz relay stack was not intentionally changed.\n' "$1" >&2
}
trap 'stop_connection_keepalive' EXIT
trap 'stop_connection_keepalive; exit 130' INT TERM
trap 'on_error "$LINENO"' ERR

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run this installer as root: sudo bash $0"; }
require_supported_os() {
  [[ -r /etc/os-release ]] || die "Cannot identify this Linux distribution."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) die "This installer supports Ubuntu and Debian only (detected: ${ID:-unknown})." ;; esac
  command -v docker >/dev/null 2>&1 || die "Docker is required. The Buzz deployment should already provide it."
  docker info >/dev/null 2>&1 || die "Docker is installed but is not available to root."
}

parse_arguments() {
  case "${1:-}" in
    "") ;;
    --fresh) FRESH_INSTALL=1 ;;
    *) die "Unknown argument: $1" ;;
  esac
  [[ "$#" -le 1 ]] || die "Only one optional argument is supported: --fresh"
}

validate_relay_url() { [[ "$1" =~ ^wss?://[^[:space:]]+$ && "$1" != */ ]]; }
npub_to_hex() {
  python3 - "$1" <<'PY'
import sys
s=sys.argv[1].strip().lower(); charset="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def polymod(v):
 c=1; g=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]
 for x in v:
  t=c>>25; c=((c&0x1ffffff)<<5)^x
  for i in range(5):
   if (t>>i)&1: c^=g[i]
 return c
def exp(h): return [ord(c)>>5 for c in h]+[0]+[ord(c)&31 for c in h]
def conv(data,fb,tb,pad):
 a=b=0; out=[]; m=(1<<tb)-1
 for x in data:
  if x<0 or x>>fb: raise ValueError
  a=(a<<fb)|x; b+=fb
  while b>=tb: b-=tb; out.append((a>>b)&m)
 if pad and b: out.append((a<<(tb-b))&m)
 elif not pad and (b>=fb or ((a<<(tb-b))&m)): raise ValueError
 return out
p=s.rfind("1")
if p<1 or p+7>len(s) or s[:p]!="npub": raise SystemExit("invalid npub")
try: vals=[charset.index(c) for c in s[p+1:]]
except ValueError: raise SystemExit("invalid npub character")
if polymod(exp("npub")+vals)!=1: raise SystemExit("invalid npub checksum")
raw=bytes(conv(vals[:-6],5,8,False))
if len(raw)!=32: raise SystemExit("npub must contain a 32-byte key")
print(raw.hex())
PY
}

hex_to_npub() {
  python3 - "$1" <<'PY'
import sys
r=bytes.fromhex(sys.argv[1].strip()); cs="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
if len(r)!=32: raise SystemExit("public key must be 32 bytes")
def pm(v):
 c=1; g=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]
 for x in v:
  t=c>>25; c=((c&0x1ffffff)<<5)^x
  for i in range(5):
   if (t>>i)&1: c^=g[i]
 return c
def ex(h): return [ord(c)>>5 for c in h]+[0]+[ord(c)&31 for c in h]
def cv(d):
 a=b=0; o=[]
 for x in d:
  a=(a<<8)|x; b+=8
  while b>=5: b-=5; o.append((a>>b)&31)
 if b: o.append((a<<(5-b))&31)
 return o
d=cv(r); x=pm(ex("npub")+d+[0]*6)^1; ck=[(x>>(5*(5-i)))&31 for i in range(6)]
print("npub1"+"".join(cs[n] for n in d+ck))
PY
}

normalize_owner_key() {
  if [[ "$1" =~ ^[0-9A-Fa-f]{64}$ ]]; then printf '%s\n' "${1,,}"
  elif [[ "$1" == npub1* ]]; then npub_to_hex "$1"
  else return 1; fi
}

select_sprig_image() {
  [[ -z "$SPRIG_IMAGE" ]] || return 0
  case "$(uname -m)" in
    x86_64|amd64) SPRIG_IMAGE="ghcr.io/block/buzz-sprig@sha256:4224d90ceba5d76ee4e3398dd3d4a225d1f4b4164b1a7addc69455fb070d5112" ;;
    aarch64|arm64) SPRIG_IMAGE="ghcr.io/block/buzz-sprig@sha256:89273b2fb3cccf90a3441fba51b1e9fd91a79c408b3ac690179731ecbf5494be" ;;
    *) die "Unsupported VPS architecture: $(uname -m)" ;;
  esac
  printf 'Using Buzz bridge image: %s\n' "$SPRIG_IMAGE"
}

collect_configuration() {
  say "Buzz connection settings"
  disable_bracketed_paste
  while true; do
    read -r -p "Buzz relay WebSocket URL (wss://...): " RELAY_URL
    RELAY_URL="$(clean_pasted_input "$RELAY_URL")"
    validate_relay_url "$RELAY_URL" && break
    printf 'Use wss:// with no trailing slash.\n'
  done
  while true; do
    read -r -p "Your Buzz owner public key (npub or 64-character hex): " OWNER_INPUT
    OWNER_INPUT="$(clean_pasted_input "$OWNER_INPUT")"
    if OWNER_HEX="$(normalize_owner_key "$OWNER_INPUT" 2>/dev/null)"; then break; fi
    printf 'That is not a valid npub or 64-character hexadecimal public key.\n'
  done
  printf '\nCodex will use one ChatGPT device login for this four-agent team. No API key is requested.\n'
}

build_agent_image() {
  say "Building the Codex team image from Buzz's prebuilt bridge"
  install -d -m 0755 "$INSTALL_ROOT/prompts" "$ENV_ROOT"
  cat > "$INSTALL_ROOT/Dockerfile" <<EOF
FROM ${SPRIG_IMAGE} AS buzz-sprig

# Composio's official Linux CLI is a glibc executable. Buzz's upstream Sprig
# image uses Alpine/musl, so use the official Debian-based Node image and copy
# Buzz's static Sprig bridge into it. This keeps Buzz, Codex, and Composio in
# one compatible image without compiling Buzz from source.
FROM node:22-bookworm-slim
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash bubblewrap ca-certificates curl git unzip \
    && rm -rf /var/lib/apt/lists/* \
    && groupmod --new-name agent node \
    && usermod --login agent --home /home/agent --move-home --shell /bin/bash node \
    && install -d -o agent -g agent /workspace /home/agent \
    && install -d -m 0755 /etc/codex \
    && printf 'sandbox_mode = "danger-full-access"\napproval_policy = "never"\n' > /etc/codex/config.toml \
    && npm install -g @openai/codex @agentclientprotocol/codex-acp \
    && npm cache clean --force
COPY --from=buzz-sprig --chmod=0755 /usr/local/bin/sprig /usr/local/bin/sprig
COPY --from=buzz-sprig --chmod=0755 /usr/local/bin/sprig-entrypoint /usr/local/bin/sprig-entrypoint
RUN for name in buzz-acp buzz-agent buzz-dev-mcp rg tree buzz git-credential-nostr git-sign-nostr; do \
      ln -s sprig "/usr/local/bin/\$name"; \
    done \
    && git config --system gpg.format x509 \
    && git config --system gpg.x509.program /usr/local/bin/git-sign-nostr \
    && git config --system commit.gpgSign true \
    && git config --system tag.gpgSign true
ENV CODEX_PATH=/usr/local/bin/codex
ENV PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin
ENV HOME=/home/agent
WORKDIR /home/agent
USER agent
ENTRYPOINT ["/usr/local/bin/sprig-entrypoint"]
EOF
  docker build --pull -t "$AGENT_IMAGE" "$INSTALL_ROOT"
}

authenticate_codex_once() {
  say "Signing the VPS team in to Codex"
  printf 'Open the displayed URL on your computer, sign in to ChatGPT, and enter the one-time code.\n'
  printf 'Do not press Enter in this terminal. It continues automatically after authorization succeeds.\n\n'
  # Always begin with an empty installer-owned authentication volume so every
  # student explicitly authorizes their own ChatGPT account during setup.
  docker volume rm -f "$SEED_AUTH_VOLUME" >/dev/null 2>&1 || true
  docker volume create "$SEED_AUTH_VOLUME" >/dev/null
  docker run --rm --user root --entrypoint /bin/sh -v "${SEED_AUTH_VOLUME}:/home/agent/.codex" "$AGENT_IMAGE" -c 'chown -R agent:agent /home/agent/.codex'
  start_connection_keepalive "Waiting for ChatGPT device authorization."
  docker run --rm -it -v "${SEED_AUTH_VOLUME}:/home/agent/.codex" --entrypoint /usr/local/bin/codex "$AGENT_IMAGE" login --device-auth
  stop_connection_keepalive
  disable_bracketed_paste
  docker run --rm -v "${SEED_AUTH_VOLUME}:/home/agent/.codex" --entrypoint /usr/local/bin/codex "$AGENT_IMAGE" login status
}

find_relay_container() {
  RELAY_CONTAINER="$(docker ps --format '{{.ID}}\t{{.Image}}\t{{.Names}}' | awk -F '\t' '$2 ~ /(^|\/)buzz([:@]|$)/ && $2 !~ /buzz-sprig/ {print $1; exit}')"
  [[ -n "$RELAY_CONTAINER" ]] || die "Could not locate the running Buzz relay container."
}

reset_exact_agent_state() {
  say "Removing the previous outreach-team test state"
  local slug container pub_hex log_text
  local relay_container=""
  relay_container="$(docker ps --format '{{.ID}}\t{{.Image}}\t{{.Names}}' | awk -F '\t' '$2 ~ /(^|\/)buzz([:@]|$)/ && $2 !~ /buzz-sprig/ {print $1; exit}')"

  # Revoke only identities belonging to the four exact containers, when their
  # public keys are still recoverable from their own logs. Relay-owner access
  # and the Buzz relay containers are never modified.
  for slug in "${SLUGS[@]}"; do
    container="buzz-codex-${slug}"
    if docker inspect "$container" >/dev/null 2>&1; then
      pub_hex=""
      log_text="$(docker logs --tail 200 "$container" 2>&1 || true)"
      if [[ "$log_text" =~ pubkey=([0-9a-f]{64}) ]]; then
        pub_hex="${BASH_REMATCH[1]}"
      fi
      if [[ -n "$relay_container" && "$pub_hex" =~ ^[0-9a-f]{64}$ ]]; then
        docker exec "$relay_container" buzz-admin remove-member --pubkey "$pub_hex" >/dev/null 2>&1 || true
      fi
    fi
  done

  for slug in "${SLUGS[@]}"; do
    docker rm -f "buzz-codex-${slug}" >/dev/null 2>&1 || true
  done
  for slug in "${SLUGS[@]}"; do
    docker volume rm -f \
      "buzz-codex-auth-${slug}" \
      "buzz-codex-home-${slug}" \
      "buzz-codex-workspace-${slug}" >/dev/null 2>&1 || true
  done
  docker volume rm -f "$SEED_AUTH_VOLUME" >/dev/null 2>&1 || true
  docker image rm -f "$AGENT_IMAGE" >/dev/null 2>&1 || true

  [[ "$INSTALL_ROOT" == "/opt/buzz-codex-team" ]] || die "Refusing to remove unexpected install path: $INSTALL_ROOT"
  [[ "$ENV_ROOT" == "/etc/buzz-codex-team" ]] || die "Refusing to remove unexpected environment path: $ENV_ROOT"
  rm -rf -- "$INSTALL_ROOT" "$ENV_ROOT"
  printf 'Previous local agent containers, volumes, image, configuration, and recoverable relay memberships were removed.\n'
}

generate_identities_and_env_files() {
  say "Generating four dedicated Buzz identities"
  NPUBS=()
  local i out secret pub
  for i in "${!SLUGS[@]}"; do
    out="$(docker exec "$RELAY_CONTAINER" buzz-admin generate-key)"
    secret="$(printf '%s\n' "$out" | sed -nE 's/^Secret key:[[:space:]]*//p' | head -n 1)"
    pub="$(printf '%s\n' "$out" | sed -nE 's/^Public key:[[:space:]]*//p' | head -n 1)"
    [[ "$secret" =~ ^(nsec1|[0-9A-Fa-f]{64}) ]] || die "Could not parse the secret for ${NAMES[$i]}."
    [[ "$pub" =~ ^[0-9A-Fa-f]{64}$ ]] || die "Could not parse the public key for ${NAMES[$i]}."
    pub="${pub,,}"; NPUBS+=("$(hex_to_npub "$pub")")
    umask 077
    {
      printf 'BUZZ_RELAY_URL=%s\n' "$RELAY_URL"
      printf 'BUZZ_PRIVATE_KEY=%s\n' "$secret"
      printf 'BUZZ_ACP_AGENT_COMMAND=/usr/local/bin/codex-acp\nBUZZ_ACP_AGENT_ARGS=\n'
      printf 'BUZZ_ACP_MCP_COMMAND=/usr/local/bin/buzz-dev-mcp\nCODEX_PATH=/usr/local/bin/codex\n'
      printf 'BUZZ_ACP_RESPOND_TO=allowlist\nBUZZ_ACP_RESPOND_TO_ALLOWLIST=%s\n' "$OWNER_HEX"
      printf 'BUZZ_ACP_DISPLAY_NAME=%s\n' "${NAMES[$i]}"
    } > "$ENV_ROOT/${SLUGS[$i]}.env"
    chmod 0600 "$ENV_ROOT/${SLUGS[$i]}.env"
  done
  printf '\nIn Buzz Desktop, open Settings -> Invites -> Invite to community and add each npub:\n\n'
  for i in "${!SLUGS[@]}"; do printf '%-30s %s\n' "${NAMES[$i]}:" "${NPUBS[$i]}"; done
  printf '\nNever paste or share an agent private key.\n'
  printf 'The installer will detect admission automatically. Do not press Enter.\n'
}

write_role_prompts() {
  cat > "$INSTALL_ROOT/prompts/researcher.md" <<'EOF'
# NYC Roofing Researcher
Find exactly 10 independently operated roofing businesses in New York City from public, permitted sources. Prefer each business's own website plus one independent source. Do not bypass logins, CAPTCHAs, robots restrictions, or paid data, and never guess personal emails.
For each lead return the business name, NYC location, official website, public business email or public contact-page URL, one verified personalization cue, source URL for every material claim, and a verification note. Exclude duplicates, national chains, out-of-area businesses, and records without a working source. Mark uncertain data UNVERIFIED. Never draft or send outreach.
EOF
  cat > "$INSTALL_ROOT/prompts/writer.md" <<'EOF'
# Outreach Writer
Use only facts and source URLs supplied by the Researcher for the current batch. Draft one subject and one plain-text email of 60 to 90 words per lead. Open with a natural observation tied to a verified detail, explain the offer honestly in one sentence, and end with a low-pressure question.
Never invent names, awards, results, clients, urgency, or familiarity. If usable personalization is missing, label the draft NEEDS RESEARCH. Preserve the batch ID and lead number. Never send messages.
Never finish silently after saving work to a file. Always post a final reply in the Buzz channel stating: the batch ID, whether the task is COMPLETE or BLOCKED, what was created and where it was saved, the number of drafts produced, and the single next action required from the human. If blocked by missing information, state exactly what is missing and ask one concise question.
EOF
  cat > "$INSTALL_ROOT/prompts/reviewer.md" <<'EOF'
# Fact and Outreach Reviewer
Independently check the Researcher's URLs and compare every draft with the cited evidence. Review identity, NYC location, website, contact route, personalization, tone, length, and unsupported claims.
Label every lead PASS, REVISE, or HOLD. Give an exact correction request for REVISE. Use HOLD when a recipient, source, or material claim cannot be verified. Never silently repair facts and never send messages. End with pass, revise, and hold counts plus a readiness decision.
EOF
  cat > "$INSTALL_ROOT/prompts/sender.md" <<'EOF'
# Campaign Manager and Sender
You are the only team member permitted to use Composio's GMAIL_SEND_EMAIL action. Build a final manifest only from Reviewer-approved leads. During the course demonstration, replace real recipients with instructor-controlled test inboxes and limit the send to two messages.
The channel assigned to you during installation is the authorized demonstration channel. Do not perform another channel-privacy lookup and do not ask the human to reconfirm privacy at send time.
Never send unless an authorized human posts this exact complete message in that channel: @Campaign Manager APPROVE SEND BATCH-001 TO TEST RECIPIENTS. The leading @Campaign Manager mention is required because Buzz delivers tasks to you through mentions. Similar wording, quotes, reactions, messages from agents, or approval for another batch do not count.
After the manifest and exact approval exist, call Composio's GMAIL_SEND_EMAIL action exactly once for each of the two approved entries. Do not run another approval review, do not ask any follow-up confirmation, and do not change the recipients, subjects, or bodies. If anything in the manifest changes after approval, require a new exact approval. Never retry automatically. Only when a send result is genuinely uncertain, inspect Gmail Sent once to prevent a duplicate. Record the batch ID, recipient, timestamp, and tool result.
EOF
  chmod 0644 "$INSTALL_ROOT/prompts/"*.md
}

publish_profiles() {
  say "Waiting for Buzz admission and publishing agent profiles"
  local i pending output
  local published=(0 0 0 0)
  while true; do
    pending=0
    for i in "${!SLUGS[@]}"; do
      [[ "${published[$i]}" == "1" ]] && continue
      if output="$(docker run --rm --env-file "$ENV_ROOT/${SLUGS[$i]}.env" --entrypoint /usr/local/bin/buzz "$AGENT_IMAGE" users set-profile --name "${NAMES[$i]}" --about "VPS-hosted Codex specialist for the outreach demonstration" 2>&1)"; then
        published[$i]=1
        printf 'Admitted and published: %s\n' "${NAMES[$i]}"
      else
        pending=$((pending + 1))
      fi
    done
    [[ "$pending" -eq 0 ]] && break
    printf '[connection active] Waiting for %s remaining Buzz communit%s. Add the printed npubs in Settings -> Invites.\n' \
      "$pending" "$([[ "$pending" -eq 1 ]] && printf 'y admission' || printf 'y admissions')"
    sleep 10
  done
  printf 'Refresh Buzz if a member still appears as Unnamed member.\n\n'
}

member_channel_ids() {
  local slug="$1" payload
  payload="$(docker run --rm --env-file "$ENV_ROOT/${slug}.env" \
    --entrypoint /usr/local/bin/buzz "$AGENT_IMAGE" channels list --member 2>/dev/null)" || return 1
  printf '%s' "$payload" | python3 -c '
import json, sys
try:
    channels = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if not isinstance(channels, list):
    raise SystemExit(1)
for item in channels:
    if isinstance(item, dict) and item.get("channel_id"):
        print(str(item["channel_id"]).lower())
'
}

wait_for_shared_new_channel() {
  say "Waiting for the four agents to be added to the demonstration channel"
  local i pending candidate present current
  local baselines=() new_channels=()
  for i in "${!SLUGS[@]}"; do
    baselines[$i]="$(member_channel_ids "${SLUGS[$i]}")" || die "Could not read channel memberships for ${NAMES[$i]}."
  done
  printf 'In Buzz Desktop, open the private demonstration channel and choose Add people.\n'
  printf 'Add all four named agents. The installer detects the shared channel automatically.\n'
  printf 'Do not press Enter and do not copy a channel UUID.\n'
  while true; do
    pending=0
    for i in "${!SLUGS[@]}"; do
      current="$(member_channel_ids "${SLUGS[$i]}" || true)"
      new_channels[$i]=""
      while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if ! grep -Fqx "$candidate" <<< "${baselines[$i]}"; then
          new_channels[$i]+="${candidate}"$'\n'
        fi
      done <<< "$current"
      [[ -n "${new_channels[$i]}" ]] || pending=$((pending + 1))
    done
    if [[ "$pending" -eq 0 ]]; then
      while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        present=1
        for i in 1 2 3; do
          grep -Fqx "$candidate" <<< "${new_channels[$i]}" || { present=0; break; }
        done
        if [[ "$present" -eq 1 ]]; then
          CHANNEL_ID="$candidate"
          printf 'Shared channel detected for all four agents: %s\n' "$CHANNEL_ID"
          printf 'Starting them from a clean runtime state.\n'
          return 0
        fi
      done <<< "${new_channels[0]}"
    fi
    printf '[connection active] Waiting for all four named agents to share the new demonstration channel.\n'
    sleep 10
  done
}

copy_codex_auth_and_start_agents() {
  say "Starting the four persistent VPS agents"
  local i slug auth home workspace container
  for i in "${!SLUGS[@]}"; do
    slug="${SLUGS[$i]}"; auth="buzz-codex-auth-${slug}"; home="buzz-codex-home-${slug}"; workspace="buzz-codex-workspace-${slug}"; container="buzz-codex-${slug}"
    docker volume create "$auth" >/dev/null; docker volume create "$home" >/dev/null; docker volume create "$workspace" >/dev/null
    docker run --rm --user root --entrypoint /bin/sh -v "${SEED_AUTH_VOLUME}:/src:ro" -v "${auth}:/dst" "$AGENT_IMAGE" -c 'cp -a /src/. /dst/ && chown -R agent:agent /dst'
    docker run --rm --user root --entrypoint /bin/sh -v "${home}:/home/agent" -v "${workspace}:/workspace" "$AGENT_IMAGE" -c 'chown -R agent:agent /home/agent /workspace'
    docker run -d --name "$container" --restart unless-stopped --env-file "$ENV_ROOT/${slug}.env" \
      -v "${home}:/home/agent" -v "${auth}:/home/agent/.codex" -v "${workspace}:/workspace" \
      -v "$INSTALL_ROOT/prompts/${slug}.md:/workspace/AGENTS.md:ro" -w /workspace "$AGENT_IMAGE" >/dev/null
  done
}

verify_team() {
  say "Checking the VPS agent team"; sleep 5
  local slug container failed=0 attempt subscribed
  for slug in "${SLUGS[@]}"; do
    container="buzz-codex-${slug}"
    if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]]; then
      docker logs --tail 80 "$container" 2>&1 || true
      failed=1
      continue
    fi
    subscribed=0
    for attempt in {1..12}; do
      if docker logs --since 2m "$container" 2>&1 | grep -Fq "subscribed to channel $CHANNEL_ID"; then
        subscribed=1
        break
      fi
      sleep 5
    done
    if [[ "$subscribed" -ne 1 ]]; then
      printf '\n%s is running but did not confirm the demonstration channel subscription.\n' "$container" >&2
      docker logs --tail 120 "$container" 2>&1 || true
      failed=1
    else
      printf 'Ready: %s is subscribed to %s\n' "$container" "$CHANNEL_ID"
    fi
  done
  [[ "$failed" -eq 0 ]] || die "One or more agents failed the channel-readiness check. Review the logs above."
  docker ps --filter 'name=buzz-codex-' --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

setup_sender_composio() {
  say "Installing Composio in the Campaign Manager only"
  printf 'The next two authorizations require your browser.\n'
  printf 'Use a dedicated test Gmail account, not a production mailbox.\n'
  docker exec --user agent buzz-codex-sender /bin/bash -lc \
    'curl -fsSL https://composio.dev/install | COMPOSIO_INSTALL_SHELL=none COMPOSIO_INSTALL_PLUGINS=0 sh'
  docker exec --user agent buzz-codex-sender /home/agent/.local/bin/composio --version

  say "Signing the Campaign Manager in to Composio"
  printf 'Open the displayed URL in your browser and complete the Composio sign-in.\n'
  printf 'The installer continues automatically. Do not press Enter.\n'
  start_connection_keepalive "Waiting for Composio authorization."
  docker exec -it --user agent buzz-codex-sender \
    /home/agent/.local/bin/composio login --no-browser --yes --no-skill-install
  stop_connection_keepalive
  disable_bracketed_paste
  docker exec --user agent buzz-codex-sender /home/agent/.local/bin/composio whoami

  say "Configuring the Composio plugin for the Sender's Codex runtime"
  docker exec --user agent buzz-codex-sender \
    /home/agent/.local/bin/composio setup --target codex --yes

  say "Connecting the dedicated Gmail account"
  printf 'Open the displayed Google authorization link, select the intended test Gmail account, and approve the requested access.\n'
  printf 'The installer continues when the Gmail connection becomes active. Do not press Enter.\n'
  start_connection_keepalive "Waiting for Gmail authorization through Composio."
  docker exec -it --user agent buzz-codex-sender \
    /home/agent/.local/bin/composio link gmail
  stop_connection_keepalive
  disable_bracketed_paste

  say "Verifying Gmail send-tool availability without sending email"
  docker exec --user agent buzz-codex-sender \
    /home/agent/.local/bin/composio execute GMAIL_SEND_EMAIL --get-schema >/dev/null
  printf 'Verified: GMAIL_SEND_EMAIL schema is available. No email was sent.\n'
}

restart_and_verify_sender() {
  say "Restarting the Campaign Manager with its Composio plugin"
  local attempt started_at ready=0
  docker restart buzz-codex-sender >/dev/null
  started_at="$(docker inspect -f '{{.State.StartedAt}}' buzz-codex-sender)"
  for attempt in {1..12}; do
    if docker logs --since "$started_at" buzz-codex-sender 2>&1 | grep -Fq "subscribed to channel $CHANNEL_ID"; then
      ready=1
      break
    fi
    sleep 5
  done
  if [[ "$ready" -ne 1 ]]; then
    docker logs --since "$started_at" buzz-codex-sender 2>&1 || true
    die "The Campaign Manager restarted but did not confirm its Buzz channel subscription."
  fi
  printf 'Ready: Campaign Manager restarted with Composio and remains subscribed to %s.\n' "$CHANNEL_ID"
}

finish_installation() {
  say "Installation completed"
  printf 'Test each agent by mentioning its exact display name in Buzz.\n'
  printf 'Before any email test, use instructor-controlled recipient inboxes and keep the human approval gate in place.\n'
  printf '\nUseful commands:\n  docker ps --filter name=buzz-codex-\n  docker logs -f buzz-codex-researcher\n  docker logs -f buzz-codex-writer\n  docker logs -f buzz-codex-reviewer\n  docker logs -f buzz-codex-sender\n'
}

main() {
  disable_bracketed_paste
  parse_arguments "$@"
  require_root; require_supported_os
  [[ "$FRESH_INSTALL" -eq 1 ]] && reset_exact_agent_state
  local slug
  for slug in "${SLUGS[@]}"; do
    docker inspect "buzz-codex-${slug}" >/dev/null 2>&1 \
      && die "Existing outreach-agent containers were found. Run the separate reset command before starting a fresh installation."
  done
  printf 'Buzz + Codex VPS Outreach Team Installer\nThis adds four external agents and leaves the Buzz relay containers unchanged.\n'
  collect_configuration; select_sprig_image; build_agent_image; authenticate_codex_once; find_relay_container
  generate_identities_and_env_files; write_role_prompts; publish_profiles
  wait_for_shared_new_channel
  copy_codex_auth_and_start_agents; verify_team
  setup_sender_composio; restart_and_verify_sender; finish_installation
}

main "$@"
