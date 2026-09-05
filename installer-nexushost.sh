#!/usr/bin/env bash
set -Eeuo pipefail

# NexusHost Webpanel v3.1 - installer for Ubuntu 22.04/24.04/26.04.
# Run with: sudo bash installer-nexushost.sh

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "FEJL: Kør filen med sudo: sudo bash $0"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "FEJL: Denne installationsfil er lavet til Ubuntu/Debian med apt."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
PANEL_USER="nexushost-panel"
TUNNEL_USER="nexushost-tunnel"
PANEL_HOME="/opt/nexushost-webpanel"
DATA_DIR="/var/lib/nexushost-webpanel"
SITE_ROOT="/srv/nexushost-sites"
TUNNEL_DIR="/etc/nexushost"
PANEL_PORT="9090"
ADMIN_USER="${PANEL_USER_NAME:-admin}"
ADMIN_PASSWORD="${PANEL_PASSWORD:-}"

if [[ -z "$ADMIN_PASSWORD" && -t 0 ]]; then
  echo ""
  echo "Vælg den adgangskode, du vil bruge til dashboardet."
  while true; do
    read -r -s -p "Ny adgangskode (mindst 8 tegn): " FIRST_PASSWORD
    echo ""
    if (( ${#FIRST_PASSWORD} < 8 )); then
      echo "Adgangskoden skal være på mindst 8 tegn. Prøv igen."
      continue
    fi
    read -r -s -p "Skriv adgangskoden igen: " SECOND_PASSWORD
    echo ""
    if [[ "$FIRST_PASSWORD" != "$SECOND_PASSWORD" ]]; then
      echo "De to adgangskoder var ikke ens. Prøv igen."
      continue
    fi
    ADMIN_PASSWORD="$FIRST_PASSWORD"
    unset FIRST_PASSWORD SECOND_PASSWORD
    break
  done
fi

echo "[1/7] Installerer Nginx, Python og nødvendige pakker..."
apt-get update
apt-get install -y nginx python3 python3-flask python3-gunicorn unzip openssl curl ca-certificates sudo git nodejs npm

NODE_MAJOR="$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)"
if (( NODE_MAJOR < 20 )); then
  echo "Installerer Node.js 22 LTS til GitHub/Node-apps..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
NODE_MAJOR="$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)"
if (( NODE_MAJOR < 20 )); then
  echo "FEJL: NexusHost kræver Node.js 20+ for at kunne deploye Node-apps fra GitHub."
  exit 1
fi
if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'xy')"
fi

# Tilføj Cloudflares officielle pakkearkiv, så cloudflared også får opdateringer
# gennem Ubuntus normale apt-opdateringer. Hvis arkivet er utilgængeligt, bruges
# den officielle release-pakke som reserve.
if ! command -v cloudflared >/dev/null 2>&1; then
  install -d -o root -g root -m 0755 /usr/share/keyrings
  CF_KEY="$(mktemp)"
  CF_REPO_READY=false
  if curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 \
    https://pkg.cloudflare.com/cloudflare-main.gpg --output "$CF_KEY"; then
    install -o root -g root -m 0644 "$CF_KEY" /usr/share/keyrings/cloudflare-main.gpg
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      > /etc/apt/sources.list.d/cloudflared.list
    if apt-get update && apt-get install -y cloudflared; then
      CF_REPO_READY=true
    fi
  fi
  rm -f -- "$CF_KEY"

  if [[ "$CF_REPO_READY" != true ]]; then
    CF_ARCH="$(dpkg --print-architecture)"
    case "$CF_ARCH" in
      amd64) CF_PACKAGE="cloudflared-linux-amd64.deb" ;;
      arm64) CF_PACKAGE="cloudflared-linux-arm64.deb" ;;
      armhf) CF_PACKAGE="cloudflared-linux-arm.deb" ;;
      *)
        echo "FEJL: Cloudflare Tunnel understøttes ikke automatisk på arkitekturen: $CF_ARCH"
        exit 1
        ;;
    esac
    CF_DEB="$(mktemp --suffix=.deb)"
    if ! curl --fail --location --retry 3 --connect-timeout 20 \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/${CF_PACKAGE}" \
      --output "$CF_DEB"; then
      rm -f -- "$CF_DEB"
      echo "FEJL: Cloudflared kunne ikke downloades. Kontrollér internetforbindelsen og prøv igen."
      exit 1
    fi
    apt-get install -y "$CF_DEB"
    rm -f -- "$CF_DEB"
  fi
fi
if command -v cloudflared >/dev/null 2>&1 && apt-cache show cloudflared >/dev/null 2>&1; then
  apt-get install -y --only-upgrade cloudflared || true
fi
CLOUDFLARED_BIN="$(command -v cloudflared 2>/dev/null || true)"
if [[ -z "$CLOUDFLARED_BIN" ]]; then
  echo "FEJL: Cloudflared blev installeret, men programmet kunne ikke findes."
  exit 1
fi
echo "Cloudflare Tunnel fundet: $($CLOUDFLARED_BIN --version 2>&1 | head -n 1)"

# Ubuntu-versioner bruger enten navnet gunicorn eller gunicorn3.
GUNICORN_START="$(command -v gunicorn 2>/dev/null || command -v gunicorn3 2>/dev/null || true)"
if [[ -z "$GUNICORN_START" ]]; then
  if python3 -c 'import gunicorn' >/dev/null 2>&1; then
    GUNICORN_START="/usr/bin/python3 -m gunicorn"
  else
    echo "FEJL: Gunicorn blev installeret, men programmet kunne ikke findes."
    exit 1
  fi
fi
echo "Gunicorn fundet: $GUNICORN_START"

if ! id "$PANEL_USER" >/dev/null 2>&1; then
  useradd --system --home "$PANEL_HOME" --shell /usr/sbin/nologin "$PANEL_USER"
fi
if ! getent group "$TUNNEL_USER" >/dev/null 2>&1; then
  groupadd --system "$TUNNEL_USER"
fi
if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
  useradd --system --gid "$TUNNEL_USER" --home "$TUNNEL_DIR" --shell /usr/sbin/nologin "$TUNNEL_USER"
else
  usermod --gid "$TUNNEL_USER" "$TUNNEL_USER"
fi

install -d -o root -g root -m 0755 "$PANEL_HOME"
install -d -o root -g root -m 0755 "$PANEL_HOME/static"
install -d -o "$PANEL_USER" -g "$PANEL_USER" -m 0750 "$DATA_DIR" "$DATA_DIR/backups"
install -d -o "$PANEL_USER" -g "$PANEL_USER" -m 0755 "$SITE_ROOT"
chown -R "$PANEL_USER:$PANEL_USER" "$DATA_DIR" "$SITE_ROOT"
install -d -o root -g "$TUNNEL_USER" -m 0750 "$TUNNEL_DIR"

# Brug logoet fra den downloadede GitHub-mappe. Hvis brugeren kun har hentet
# installationsfilen, hentes den samme kontrollerede logofil automatisk.
LOGO_SHA256="a4e38af961edb428b4ad7ae57811abfd7f031f03299fa9bf86cc022e84d860cd"
INSTALLER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
LOGO_LOCAL="${INSTALLER_DIR}/assets/nexushost-logo.png"
LOGO_TEMP="$(mktemp --suffix=.png)"
if [[ -n "$INSTALLER_DIR" && -f "$LOGO_LOCAL" ]]; then
  cp -- "$LOGO_LOCAL" "$LOGO_TEMP"
elif ! curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 \
  "https://raw.githubusercontent.com/chingchang2000/Ubuntu-pc-to-Web-server/main/assets/nexushost-logo.png" \
  --output "$LOGO_TEMP"; then
  rm -f -- "$LOGO_TEMP"
  echo "FEJL: NexusHost-logoet kunne ikke hentes. Kontrollér internetforbindelsen og prøv igen."
  exit 1
fi
if ! printf '%s  %s\n' "$LOGO_SHA256" "$LOGO_TEMP" | sha256sum --check --status; then
  rm -f -- "$LOGO_TEMP"
  echo "FEJL: NexusHost-logoet bestod ikke sikkerhedskontrollen. Download projektet igen."
  exit 1
fi
install -o root -g root -m 0644 "$LOGO_TEMP" "$PANEL_HOME/static/nexushost-logo.png"
rm -f -- "$LOGO_TEMP"
unset LOGO_SHA256 INSTALLER_DIR LOGO_LOCAL LOGO_TEMP

APP_HELPER="/usr/local/sbin/nexushost-app-control"
APP_HELPER_LOCAL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)/nexushost-app-control"
if [[ -f "$APP_HELPER_LOCAL" ]]; then
  install -o root -g root -m 0755 "$APP_HELPER_LOCAL" "$APP_HELPER"
else
  if ! curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 \
    "https://raw.githubusercontent.com/chingchang2000/Ubuntu-pc-to-Web-server/main/nexushost-app-control" \
    --output "$APP_HELPER"; then
    rm -f -- "$APP_HELPER"
    echo "FEJL: GitHub-deploy-hjælperen kunne ikke hentes."
    exit 1
  fi
  chown root:root "$APP_HELPER"
  chmod 0755 "$APP_HELPER"
fi
unset APP_HELPER_LOCAL

echo "[2/7] Opretter den sikre server-hjælper..."
install -o root -g root -m 0755 /dev/null /usr/local/sbin/nexushost-panel-apply
cat > /usr/local/sbin/nexushost-panel-apply <<'PYHELPER'
#!/usr/bin/env python3
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

DATA = Path("/var/lib/nexushost-webpanel/sites.json")
OUT = Path("/etc/nginx/nexushost-sites")
ROOT = Path("/srv/nexushost-sites")
DOMAIN = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,48}$")

def fail(message):
    print("FEJL:", message, file=sys.stderr)
    raise SystemExit(1)

def validate(site):
    slug = str(site.get("slug", ""))
    if not SLUG.fullmatch(slug): fail("Ugyldigt website-id")
    port = site.get("port")
    if not isinstance(port, int) or not 1024 <= port <= 65535 or port == 9090:
        fail("Ugyldig port")
    if site.get("scope") not in ("lan", "tunnel", "public"): fail("Ugyldig adgangstype")
    domains = site.get("domains", [])
    if not isinstance(domains, list) or len(domains) > 20: fail("Ugyldige domæner")
    for domain in domains:
        if not isinstance(domain, str) or not DOMAIN.fullmatch(domain):
            fail("Ugyldigt domæne")
    real_root = (ROOT / slug / "public").resolve()
    if ROOT.resolve() not in real_root.parents: fail("Ugyldig mappe")
    return slug, port, domains

def nginx_config(site):
    slug, port, domains = validate(site)
    names = " ".join(domains) if domains else "_"
    default = " default_server" if not domains else ""
    domain_listeners = "\n    listen 80;\n    listen [::]:80;" if domains and site["scope"] == "public" else ""
    access = ""
    if site["scope"] in ("lan", "tunnel"):
        access = """
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    allow ::1;
    allow fc00::/7;
    deny all;"""
    runtime = site.get("runtime", "static")
    if runtime not in ("static", "node"):
        fail("Ugyldig website-runtime")
    if runtime == "node":
        app_port = site.get("app_port")
        if not isinstance(app_port, int) or not 18000 <= app_port <= 29999:
            fail("Ugyldig intern Node-port")
        location = f"""    location / {{
        proxy_pass http://127.0.0.1:{app_port};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
    }}"""
    else:
        location = """    location / {
        try_files $uri $uri/ =404;
    }"""
    return f'''# Managed by NexusHost Webpanel - do not edit manually
server {{
    listen {port}{default};
    listen [::]:{port}{default};{domain_listeners}
    server_name {names};
    root {ROOT / slug / "public"};
    index index.html index.htm;
    charset utf-8;
    autoindex off;
    client_max_body_size 100m;
    server_tokens off;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;{access}
{location}
    location ~ /\\. {{ deny all; }}
}}
'''

def main():
    OUT.mkdir(mode=0o755, parents=True, exist_ok=True)
    try:
        sites = json.loads(DATA.read_text()) if DATA.exists() else []
    except Exception as exc:
        fail(f"Kunne ikke læse website-listen: {exc}")
    if not isinstance(sites, list): fail("Website-listen er ødelagt")

    used_ports = set()
    used_domains = set()
    wanted = set()
    for site in sites:
        slug, port, domains = validate(site)
        if not site.get("active", True):
            continue
        if port in used_ports: fail(f"Flere websites bruger port {port}")
        used_ports.add(port)
        for domain in domains:
            if domain in used_domains: fail(f"Domænet {domain} bruges af flere websites")
            used_domains.add(domain)
        target = OUT / f"{slug}.conf"
        content = nginx_config(site)
        fd, tmp = tempfile.mkstemp(prefix=f".{slug}.", dir=OUT, text=True)
        try:
            with os.fdopen(fd, "w") as handle:
                handle.write(content)
            os.chmod(tmp, 0o644)
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
        wanted.add(target.name)

    for old in OUT.glob("*.conf"):
        if old.name not in wanted:
            old.unlink()

    test = subprocess.run(["/usr/sbin/nginx", "-t"], text=True, capture_output=True)
    if test.returncode:
        fail(test.stderr.strip() or "Nginx-konfigurationen kunne ikke godkendes")
    subprocess.run(["/bin/systemctl", "reload", "nginx"], check=True)
    ufw = Path("/usr/sbin/ufw")
    if ufw.exists():
        status = subprocess.run([str(ufw), "status", "numbered"], text=True, capture_output=True)
        if "Status: active" in status.stdout:
            # Fjern kun regler, som tidligere er oprettet af website-hjælperen.
            # Det lukker også en gammel offentlig port, hvis et site skifter til Tunnel/LAN.
            managed_comments = (
                "NexusHost public site", "NexusHost LAN site",
                "NexusHost public domains", "NexusHost managed site",
            )
            rule_numbers = []
            for line in status.stdout.splitlines():
                if any(comment in line for comment in managed_comments):
                    match = re.match(r"\[\s*(\d+)\]", line.strip())
                    if match:
                        rule_numbers.append(int(match.group(1)))
            for number in sorted(set(rule_numbers), reverse=True):
                subprocess.run([str(ufw), "--force", "delete", str(number)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            for port in sorted({s["port"] for s in sites if s.get("active", True)}):
                direct_public = any(
                    s.get("active", True) and s["port"] == port and s["scope"] == "public"
                    for s in sites
                )
                if direct_public:
                    subprocess.run([str(ufw), "allow", f"{port}/tcp", "comment", "NexusHost managed site"],
                                   check=True, stdout=subprocess.DEVNULL)
                else:
                    for subnet in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"):
                        subprocess.run([
                            str(ufw), "allow", "from", subnet, "to", "any", "port", str(port),
                            "proto", "tcp", "comment", "NexusHost managed site",
                        ], check=True, stdout=subprocess.DEVNULL)
            if any(s.get("active", True) and s["scope"] == "public" and s.get("domains") for s in sites):
                subprocess.run([str(ufw), "allow", "80/tcp", "comment", "NexusHost managed site"],
                               check=True, stdout=subprocess.DEVNULL)

if __name__ == "__main__":
    main()
PYHELPER
chmod 0755 /usr/local/sbin/nexushost-panel-apply
chown root:root /usr/local/sbin/nexushost-panel-apply

install -o root -g root -m 0755 /dev/null /usr/local/sbin/nexushost-tunnel-control
cat > /usr/local/sbin/nexushost-tunnel-control <<'TUNNELHELPER'
#!/usr/bin/env bash
set -Eeuo pipefail

TOKEN_FILE="/etc/nexushost/tunnel-token"
MARKER_FILE="/var/lib/nexushost-webpanel/tunnel-configured"
SERVICE="nexushost-tunnel.service"

fail() {
  echo "FEJL: $1" >&2
  exit 1
}

case "${1:-}" in
  install)
    [[ $# -eq 1 ]] || fail "Ugyldige argumenter"
    TOKEN="$(head -c 4097)"
    if (( ${#TOKEN} < 80 || ${#TOKEN} > 4096 )) || [[ ! "$TOKEN" =~ ^[A-Za-z0-9+/._=-]+$ ]]; then
      fail "Cloudflare-tokenet ser ikke gyldigt ud. Kopiér hele Linux-kommandoen igen."
    fi
    if ! printf '%s' "$TOKEN" | python3 -c 'import base64,json,sys; data=json.loads(base64.b64decode(sys.stdin.buffer.read(), validate=True)); assert all(data.get(k) for k in ("a","s","t"))' 2>/dev/null; then
      fail "Cloudflare-tokenet kunne ikke godkendes. Kopiér kommandoen igen fra din tunnel."
    fi
    TEMP_TOKEN="$(mktemp /etc/nexushost/.tunnel-token.XXXXXX)"
    trap 'rm -f -- "${TEMP_TOKEN:-}"' EXIT
    printf '%s' "$TOKEN" > "$TEMP_TOKEN"
    chown root:nexushost-tunnel "$TEMP_TOKEN"
    chmod 0640 "$TEMP_TOKEN"
    mv -f -- "$TEMP_TOKEN" "$TOKEN_FILE"
    trap - EXIT
    unset TOKEN
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE"; then
      journalctl -u "$SERVICE" --no-pager -n 12 >&2 || true
      fail "Tunnelen kunne ikke starte. Kontrollér tokenet og prøv igen."
    fi
    install -o nexushost-panel -g nexushost-panel -m 0640 /dev/null "$MARKER_FILE"
    ;;
  restart)
    [[ $# -eq 1 ]] || fail "Ugyldige argumenter"
    [[ -s "$TOKEN_FILE" ]] || fail "Tunnelen er ikke forbundet endnu"
    systemctl restart "$SERVICE"
    install -o nexushost-panel -g nexushost-panel -m 0640 /dev/null "$MARKER_FILE"
    ;;
  disconnect)
    [[ $# -eq 1 ]] || fail "Ugyldige argumenter"
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    rm -f -- "$TOKEN_FILE" "$MARKER_FILE"
    ;;
  *)
    fail "Tilladt handling er install, restart eller disconnect"
    ;;
esac
TUNNELHELPER
chmod 0755 /usr/local/sbin/nexushost-tunnel-control
chown root:root /usr/local/sbin/nexushost-tunnel-control

echo "[3/7] Opretter webpanelet..."
install -o root -g root -m 0644 /dev/null "$PANEL_HOME/app.py"
cat > "$PANEL_HOME/app.py" <<'PYAPP'
from flask import Flask, abort, flash, redirect, render_template_string, request, send_file, session, url_for
from werkzeug.security import check_password_hash
from pathlib import Path
from functools import wraps
from datetime import datetime, timezone
import html, io, json, os, re, secrets, shutil, socket, subprocess, zipfile

app = Flask(__name__)
DATA = Path("/var/lib/nexushost-webpanel")
SITES_FILE = DATA / "sites.json"
CONFIG_FILE = DATA / "config.json"
ROOT = Path("/srv/nexushost-sites")
BACKUPS = DATA / "backups"
TUNNEL_MARKER = DATA / "tunnel-configured"
TUNNEL_HELPER = "/usr/local/sbin/nexushost-tunnel-control"
TUNNEL_SERVICE = "nexushost-tunnel.service"
APP_HELPER = "/usr/local/sbin/nexushost-app-control"
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,48}$")
GITHUB_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$")
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
TUNNEL_TOKEN_RE = re.compile(r"^[A-Za-z0-9+/._=-]{80,4096}$")

config = json.loads(CONFIG_FILE.read_text())
app.secret_key = config["secret_key"]
app.config.update(MAX_CONTENT_LENGTH=100 * 1024 * 1024, SESSION_COOKIE_HTTPONLY=True,
                  SESSION_COOKIE_SAMESITE="Strict", PERMANENT_SESSION_LIFETIME=3600)

def load_sites():
    try:
        value = json.loads(SITES_FILE.read_text())
        return value if isinstance(value, list) else []
    except (FileNotFoundError, json.JSONDecodeError):
        return []

def save_sites(sites):
    tmp = SITES_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(sites, ensure_ascii=False, indent=2))
    os.replace(tmp, SITES_FILE)

def apply_config():
    result = subprocess.run(["sudo", "/usr/local/sbin/nexushost-panel-apply"], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Nginx kunne ikke genindlæses")

def next_app_port(exclude_slug=None):
    used = {
        int(site.get("app_port"))
        for site in load_sites()
        if site.get("slug") != exclude_slug and isinstance(site.get("app_port"), int)
    }
    for port in range(18000, 30000):
        if port not in used:
            return port
    raise RuntimeError("Der er ingen ledige interne app-porte")

def run_app_action(action, slug, app_port=None, github_url=None):
    if action not in ("deploy", "remove", "delete", "start", "stop"):
        raise ValueError("Ugyldig app-handling")
    args = ["sudo", APP_HELPER, action, slug]
    if action == "deploy":
        if not isinstance(app_port, int):
            raise ValueError("Intern app-port mangler")
        args.append(str(app_port))
    try:
        result = subprocess.run(
            args, input=(github_url or ""), text=True, capture_output=True,
            timeout=240,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("GitHub-deploy tog for lang tid. Prøv igen.") from exc
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "App-handlingen fejlede")
    return result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""

def update_site_runtime(slug, runtime, source_url="", app_port=None):
    sites = load_sites()
    target = next((item for item in sites if item.get("slug") == slug), None)
    if target is None:
        raise ValueError("Websitet findes ikke")
    target["runtime"] = runtime
    if runtime == "node":
        target["app_port"] = int(app_port)
    else:
        target.pop("app_port", None)
    if source_url:
        target["source_url"] = source_url
    else:
        target.pop("source_url", None)
    target["updated"] = datetime.now(timezone.utc).isoformat()
    save_sites(sites)
    return target

def tunnel_state():
    active = subprocess.run(["systemctl", "is-active", "--quiet", TUNNEL_SERVICE]).returncode == 0
    enabled = subprocess.run(["systemctl", "is-enabled", "--quiet", TUNNEL_SERVICE],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    try:
        version = subprocess.run(["cloudflared", "--version"], text=True, capture_output=True,
                                 timeout=4).stdout.strip().replace("cloudflared version ", "")
    except (OSError, subprocess.TimeoutExpired):
        version = "Ikke fundet"
    return {"active": active, "enabled": enabled, "configured": TUNNEL_MARKER.exists(),
            "version": version or "Ukendt"}

def extract_tunnel_token(raw):
    raw = (raw or "").strip()
    if not raw or len(raw) > 10000:
        raise ValueError("Indsæt kommandoen fra Cloudflare")
    if TUNNEL_TOKEN_RE.fullmatch(raw):
        return raw
    candidates = re.findall(r"(?<![A-Za-z0-9+/._=-])[A-Za-z0-9+/._=-]{80,4096}(?![A-Za-z0-9+/._=-])", raw)
    candidates = [candidate for candidate in candidates if TUNNEL_TOKEN_RE.fullmatch(candidate)]
    if len(candidates) != 1:
        raise ValueError("Kunne ikke finde tunnel-tokenet. Kopiér hele Linux-kommandoen fra Cloudflare.")
    return candidates[0]

def run_tunnel_action(action, token=None):
    if action not in ("install", "restart", "disconnect"):
        raise ValueError("Ugyldig tunnel-handling")
    try:
        result = subprocess.run(
            ["sudo", TUNNEL_HELPER, action], input=token, text=True,
            capture_output=True, timeout=30,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("Handlingen tog for lang tid. Prøv igen.") from exc
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Cloudflare Tunnel kunne ikke opdateres")

def current_ip():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("1.1.1.1", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()

def logged_in(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)
    return wrapped

def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(24)
    return session["csrf"]

@app.before_request
def protect_csrf():
    if request.method == "POST":
        supplied = request.form.get("csrf", "")
        if not secrets.compare_digest(supplied, session.get("csrf", "")):
            abort(403)

app.jinja_env.globals["csrf_token"] = csrf_token

STYLE = r'''
:root{--bg:#07111f;--panel:#101d30;--soft:#182940;--line:#253b57;--text:#eef6ff;--muted:#91a6bd;--blue:#38a5ff;--cyan:#52e5d5;--red:#ff6474;--green:#41d898;--shadow:0 24px 65px #02081299}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 15% 0,#12325a 0,transparent 34%),var(--bg);color:var(--text);font:15px Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;min-height:100vh}a{color:inherit}.shell{display:grid;grid-template-columns:245px 1fr;min-height:100vh}.side{padding:27px 20px;border-right:1px solid var(--line);background:#091523dd;backdrop-filter:blur(18px)}.brand{display:flex;gap:12px;align-items:center;font-weight:800;font-size:18px;margin:0 5px 30px}.logo{width:44px;height:44px;object-fit:contain;flex:0 0 auto;filter:drop-shadow(0 0 12px #38a5ff66)}.nav a{display:flex;text-decoration:none;padding:12px 13px;border-radius:11px;color:var(--muted);margin:4px 0}.nav a:hover,.nav a.on{background:var(--soft);color:white}.side-foot{position:fixed;bottom:24px;color:var(--muted);font-size:12px;padding:0 8px}.main{padding:32px;max-width:1500px;width:100%}.top{display:flex;justify-content:space-between;gap:20px;align-items:center;margin-bottom:26px}.top h1{font-size:29px;margin:0 0 5px}.muted{color:var(--muted)}.button,button{border:0;border-radius:10px;background:linear-gradient(135deg,var(--blue),#2479ff);color:white;padding:11px 16px;font-weight:700;cursor:pointer;text-decoration:none;display:inline-block}.button.secondary,button.secondary{background:var(--soft);border:1px solid var(--line)}button.danger,.danger{background:#3a1721;color:#ff98a3;border:1px solid #6b2735}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:22px}.stat,.card{border:1px solid var(--line);border-radius:16px;background:linear-gradient(155deg,#13233aee,#0c1829ee);box-shadow:var(--shadow)}.stat{padding:18px}.stat .big{font-size:25px;font-weight:800;margin-top:7px}.card{padding:20px;margin-bottom:18px}.sites{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:16px}.site{padding:19px;border:1px solid var(--line);border-radius:15px;background:#101e31}.row{display:flex;align-items:center;justify-content:space-between;gap:12px}.site h3{margin:0 0 4px;font-size:18px}.pill{padding:5px 9px;border-radius:99px;font-size:12px;font-weight:800}.pill.on{background:#123d32;color:#67e8b4}.pill.off{background:#3b2530;color:#ff9aa7}.pill.lan{background:#193451;color:#72beff}.pill.tunnel{background:#253257;color:#9cc8ff}.pill.direct{background:#49351b;color:#ffd38a}.domain{font-family:ui-monospace,monospace;color:#bcd0e6;background:#0a1423;padding:8px 10px;border-radius:9px;margin:12px 0;word-break:break-all}.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:15px}.actions button,.actions .button{font-size:13px;padding:8px 11px}label{font-weight:700;display:block;margin:13px 0 7px}input,textarea,select{width:100%;border:1px solid var(--line);border-radius:10px;background:#091523;color:white;padding:12px;outline:none}input:focus,textarea:focus,select:focus{border-color:var(--blue);box-shadow:0 0 0 3px #38a5ff22}textarea{min-height:350px;font-family:ui-monospace,monospace;line-height:1.5}.form-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}.help{color:var(--muted);font-size:13px;margin-top:6px}.flash{padding:12px 14px;border-radius:11px;margin-bottom:15px;background:#143b31;border:1px solid #23684f}.flash.error{background:#3a1721;border-color:#6b2735}.notice{padding:14px;border:1px solid #375b7f;border-radius:12px;background:#102943;margin:15px 0}.notice.warn{border-color:#715329;background:#332817}.steps{counter-reset:step;display:grid;gap:12px}.step{position:relative;padding:14px 14px 14px 50px;border:1px solid var(--line);border-radius:12px;background:#0b1829}.step:before{counter-increment:step;content:counter(step);position:absolute;left:14px;top:13px;width:25px;height:25px;border-radius:50%;display:grid;place-items:center;background:linear-gradient(135deg,var(--blue),#2479ff);font-weight:800}.code{font-family:ui-monospace,monospace;color:#d9eaff;background:#07111f;padding:10px;border:1px solid var(--line);border-radius:9px;word-break:break-all}.statusline{display:flex;align-items:center;gap:10px}.dot{width:11px;height:11px;border-radius:50%;background:var(--red);box-shadow:0 0 15px #ff647477}.dot.ok{background:var(--green);box-shadow:0 0 15px #41d89877}.empty{text-align:center;padding:55px 20px;color:var(--muted)}.login-wrap{min-height:100vh;display:grid;place-items:center;padding:20px}.login{width:min(420px,100%);padding:30px}.login-brand{display:flex;align-items:center;gap:13px;margin-bottom:22px;font-size:18px;font-weight:800}.login-logo{width:58px;height:58px;object-fit:contain;filter:drop-shadow(0 0 18px #38a5ff66)}.login h1{margin:0 0 8px}@media(max-width:900px){.shell{grid-template-columns:1fr}.side{display:none}.main{padding:20px}.grid{grid-template-columns:1fr 1fr}.form-grid{grid-template-columns:1fr}}@media(max-width:520px){.grid{grid-template-columns:1fr}.top{align-items:flex-start;flex-direction:column}}
'''

BASE = r'''<!doctype html><html lang="da"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{{ title }} · NexusHost</title><link rel="icon" type="image/png" sizes="256x256" href="{{ url_for('static', filename='nexushost-logo.png') }}"><link rel="apple-touch-icon" href="{{ url_for('static', filename='nexushost-logo.png') }}"><style>''' + STYLE + r'''</style></head><body>
{% if session.get('logged_in') %}<div class="shell"><aside class="side"><div class="brand"><img class="logo" src="{{ url_for('static', filename='nexushost-logo.png') }}" alt="NexusHost-logo"> NexusHost Panel</div><nav class="nav"><a class="{{ 'on' if request.endpoint=='dashboard' }}" href="{{ url_for('dashboard') }}">● Websites</a><a class="{{ 'on' if request.endpoint=='new_site' }}" href="{{ url_for('new_site') }}">＋ Tilføj website</a><a class="{{ 'on' if request.endpoint=='cloudflare' }}" href="{{ url_for('cloudflare') }}">◈ Cloudflare Tunnel</a><a class="{{ 'on' if request.endpoint=='system' }}" href="{{ url_for('system') }}">◫ Serverinfo</a><a href="{{ url_for('logout') }}">↪ Log ud</a></nav><div class="side-foot">Nginx · Cloudflare · Ubuntu</div></aside><main class="main">{% else %}<div class="login-wrap"><main class="card login">{% endif %}
{% with messages=get_flashed_messages(with_categories=true) %}{% for category,message in messages %}<div class="flash {{ category }}">{{ message }}</div>{% endfor %}{% endwith %}
{{ body|safe }}
{% if session.get('logged_in') %}</main></div>{% else %}</main></div>{% endif %}</body></html>'''

def page(title, body, **ctx):
    inner = render_template_string(body, **ctx)
    return render_template_string(BASE, title=title, body=inner)

@app.errorhandler(413)
def too_large(_):
    flash("Filen er for stor. Maksimum er 100 MB.", "error")
    return redirect(request.referrer or url_for("dashboard"))

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if request.form.get("username") == config["username"] and check_password_hash(config["password_hash"], request.form.get("password", "")):
            session.clear(); session["logged_in"] = True; session.permanent = True; csrf_token()
            return redirect(url_for("dashboard"))
        flash("Forkert brugernavn eller adgangskode.", "error")
    body = '''<div class="login-brand"><img class="login-logo" src="{{ url_for('static', filename='nexushost-logo.png') }}" alt="NexusHost-logo"><span>NexusHost Panel</span></div><h1>Velkommen tilbage</h1><p class="muted">Log ind for at styre din Ubuntu-webserver.</p><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><label>Brugernavn</label><input name="username" autocomplete="username" required autofocus><label>Adgangskode</label><input type="password" name="password" autocomplete="current-password" required><button style="width:100%;margin-top:18px">Log ind</button></form>'''
    return page("Log ind", body)

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/")
@logged_in
def dashboard():
    sites = load_sites(); ip = current_ip()
    state = tunnel_state()
    for site in sites:
        scope = site.get("scope", "lan")
        site["scope_label"] = {"lan":"Kun netværk", "tunnel":"Cloudflare", "public":"Direkte offentlig"}.get(scope, "Ukendt")
        site["scope_class"] = {"lan":"lan", "tunnel":"tunnel", "public":"direct"}.get(scope, "off")
        if site.get("domains"):
            scheme = "https" if scope == "tunnel" else "http"
            site["open_url"] = f"{scheme}://{site['domains'][0]}"
        else:
            site["open_url"] = f"http://{ip}:{site['port']}"
    tunnel_sites = [site for site in sites if site.get("scope") == "tunnel" and site.get("active", True)]
    body = '''<div class="top"><div><h1>Dine websites</h1><div class="muted">Administrér alt fra ét sted</div></div><a class="button" href="{{ url_for('new_site') }}">＋ Nyt website</a></div>
    <div class="grid"><div class="stat"><span class="muted">Websites</span><div class="big">{{ sites|length }}</div></div><div class="stat"><span class="muted">Online</span><div class="big">{{ sites|selectattr('active')|list|length }}</div></div><div class="stat"><span class="muted">Server-IP</span><div class="big" style="font-size:18px">{{ ip }}</div></div><div class="stat"><span class="muted">Sikker tunnel</span><div class="big" style="font-size:18px">{{ 'Forbundet' if state.active else 'Ikke forbundet' }}</div></div></div>
    {% if tunnel_sites and not state.active %}<div class="notice warn"><b>Cloudflare Tunnel er ikke forbundet.</b> Dine Cloudflare-websites virker kun lokalt endnu. <a href="{{ url_for('cloudflare') }}">Forbind tunnelen →</a></div>{% endif %}
    <div class="sites">{% for s in sites %}<article class="site"><div class="row"><div><h3>{{ s.name }}</h3><span class="muted">Port {{ s.port }}</span></div><span class="pill {{ 'on' if s.active else 'off' }}">{{ 'ONLINE' if s.active else 'STOPPET' }}</span></div><div class="domain">{% if s.domains %}{{ s.domains|join(', ') }}{% else %}{{ ip }}:{{ s.port }}{% endif %}</div><div class="row"><span class="pill {{ s.scope_class }}">{{ s.scope_label }}</span><span class="muted">{{ s.updated[:10] }}</span></div><div class="actions"><a class="button secondary" href="{{ url_for('edit_site', slug=s.slug) }}">Redigér</a><a class="button secondary" href="{{ s.open_url }}" target="_blank" rel="noopener">Åbn</a><form method="post" action="{{ url_for('toggle_site', slug=s.slug) }}"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><button class="secondary">{{ 'Stop' if s.active else 'Start' }}</button></form><form method="post" action="{{ url_for('delete_site', slug=s.slug) }}" onsubmit="return confirm('Flyt websitet til backup og fjern det?')"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><button class="danger">Slet</button></form></div></article>{% else %}<div class="card empty"><h2>Ingen websites endnu</h2><p>Opret dit første website på under ét minut.</p><a class="button" href="{{ url_for('new_site') }}">Opret website</a></div>{% endfor %}</div>'''
    return page("Websites", body, sites=sites, ip=ip, state=state, tunnel_sites=tunnel_sites)

@app.route("/cloudflare", methods=["GET", "POST"])
@logged_in
def cloudflare():
    if request.method == "POST":
        action = request.form.get("action", "")
        try:
            if action == "connect":
                token = extract_tunnel_token(request.form.get("token", ""))
                run_tunnel_action("install", token)
                del token
                flash("Cloudflare Tunnel er forbundet og starter automatisk med Ubuntu.")
            elif action == "restart":
                run_tunnel_action("restart")
                flash("Cloudflare Tunnel er genstartet.")
            elif action == "disconnect":
                run_tunnel_action("disconnect")
                flash("Cloudflare Tunnel er afbrudt. Ingen website-filer er slettet.")
            else:
                raise ValueError("Ugyldig handling")
        except (ValueError, RuntimeError, OSError) as exc:
            flash(str(exc), "error")
        return redirect(url_for("cloudflare"))

    state = tunnel_state()
    tunnel_sites = [site for site in load_sites() if site.get("scope") == "tunnel"]
    body = '''<div class="top"><div><h1>Cloudflare Tunnel</h1><div class="muted">Offentlige hjemmesider uden åbne routerporte</div></div><a class="button secondary" href="https://one.dash.cloudflare.com/" target="_blank" rel="noopener">Åbn Cloudflare ↗</a></div>
    <section class="card"><div class="row"><div><h2 style="margin:0 0 7px">Forbindelse</h2><div class="statusline"><span class="dot {{ 'ok' if state.active }}"></span><b>{{ 'Forbundet' if state.active else ('Stoppet' if state.configured else 'Ikke opsat') }}</b></div></div><span class="muted">cloudflared {{ state.version }}</span></div>{% if state.configured %}<div class="actions"><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="restart"><button class="secondary">Genstart tunnel</button></form><form method="post" onsubmit="return confirm('Afbryd tunnelen? Dine offentlige domæner går offline.')"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="disconnect"><button class="danger">Afbryd tunnel</button></form></div>{% endif %}</section>
    <section class="card"><h2>Opsætning – kun én gang</h2><div class="notice"><b>Du skal ikke logge ind på routeren og ikke åbne nogen porte.</b> Dashboardet bliver på dit lokale netværk.</div><div class="steps"><div class="step">Køb et domæne, opret en gratis Cloudflare-konto, tilføj domænet og skift navneservere som Cloudflare viser.</div><div class="step">I Cloudflare: gå til <b>Networking → Tunnels</b>, vælg <b>Create tunnel</b>, giv den navnet <b>NexusHost</b>, og vælg Linux.</div><div class="step">Kopiér hele installationskommandoen fra Cloudflare og indsæt den herunder. NexusHost kører den ikke direkte; det finder kun det hemmelige tunnel-token.</div><div class="step">Når der står <b>Forbundet</b>, tilføjer du en <b>Published application</b> i Cloudflare for hvert domæne. Brug den Service URL, som NexusHost viser længere nede.</div></div>
    <form method="post" style="margin-top:18px"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="connect"><label>{{ 'Udskift tunnel-token' if state.configured else 'Cloudflare Linux-kommando' }}</label><input type="password" name="token" autocomplete="off" placeholder="sudo cloudflared service install eyJ..." required><div class="help">Tokenet gemmes i en beskyttet systemfil og vises aldrig igen.</div><button style="margin-top:14px">{{ 'Opdatér forbindelse' if state.configured else 'Forbind sikkert' }}</button></form></section>
    <section class="card"><h2>Ruter til dine websites</h2><p class="muted">Skriv hver adresse i Cloudflares Published application. Vælg HTTP som service.</p>{% for site in tunnel_sites %}<div class="site" style="margin-top:12px"><div class="row"><b>{{ site.name }}</b><span class="pill {{ 'on' if site.active else 'off' }}">{{ 'KLAR' if site.active else 'STOPPET' }}</span></div>{% if site.domains %}{% for domain in site.domains %}<p><b>Hostname:</b> {{ domain }}</p>{% endfor %}{% else %}<p class="muted">Tilføj først et domæne under Redigér website.</p>{% endif %}<div class="code">Service URL: http://localhost:{{ site.port }}</div></div>{% else %}<div class="empty"><p>Du har endnu ingen websites med adgangstypen Cloudflare Tunnel.</p><a class="button" href="{{ url_for('new_site') }}">Opret Cloudflare-website</a></div>{% endfor %}<div class="notice warn"><b>Vigtigt:</b> Tilføj aldrig dashboardets adresse eller port 9090 som en Cloudflare-rute. Kun dine websites skal være offentlige.</div></section>'''
    return page("Cloudflare Tunnel", body, state=state, tunnel_sites=tunnel_sites)

def parse_domains(raw):
    domains = []
    for item in re.split(r"[,\s]+", raw.lower().strip()):
        item = item.removeprefix("https://").removeprefix("http://").split("/")[0].split(":")[0].strip(".")
        if item and item not in domains: domains.append(item)
    if len(domains) > 20 or any(not DOMAIN_RE.fullmatch(x) for x in domains):
        raise ValueError("Et eller flere domæner er ugyldige")
    return domains

def validate_site_form(existing_slug=None):
    name = request.form.get("name", "").strip()
    slug = existing_slug or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:49]
    if not name or len(name) > 80 or not SLUG_RE.fullmatch(slug): raise ValueError("Navnet kan ikke bruges")
    try: port = int(request.form.get("port", ""))
    except ValueError: raise ValueError("Porten skal være et tal")
    if not 1024 <= port <= 65535 or port == 9090: raise ValueError("Vælg en port mellem 1024 og 65535 (ikke 9090)")
    scope = request.form.get("scope")
    if scope not in ("lan", "tunnel", "public"): raise ValueError("Vælg en adgangstype")
    domains = parse_domains(request.form.get("domains", ""))
    sites = load_sites()
    for other in sites:
        if other["slug"] == slug: continue
        if other["port"] == port: raise ValueError("Porten bruges allerede af et andet website")
        if set(domains) & set(other.get("domains", [])): raise ValueError("Domænet bruges allerede af et andet website")
    return name, slug, port, scope, domains

@app.route("/sites/new", methods=["GET", "POST"])
@logged_in
def new_site():
    if request.method == "POST":
        try:
            name, slug, port, scope, domains = validate_site_form()
            sites = load_sites()
            if any(x["slug"] == slug for x in sites): raise ValueError("Der findes allerede et website med næsten samme navn")
            now = datetime.now(timezone.utc).isoformat()
            site = {"name":name,"slug":slug,"port":port,"scope":scope,"domains":domains,"active":True,"runtime":"static","created":now,"updated":now}
            public = ROOT / slug / "public"; public.mkdir(parents=True, exist_ok=False)
            (public / "index.html").write_text(f'''<!doctype html><html lang="da"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>{html.escape(name)}</title><style>body{{font:18px system-ui;background:#07111f;color:#eef6ff;display:grid;place-items:center;min-height:100vh;margin:0}}main{{text-align:center}}h1{{font-size:clamp(2rem,8vw,5rem);margin:0}}p{{color:#91a6bd}}</style><main><h1>{html.escape(name)}</h1><p>Dit website er online 🚀</p></main></html>''')
            sites.append(site); save_sites(sites)
            try: apply_config()
            except Exception:
                sites.pop(); save_sites(sites); shutil.rmtree(ROOT/slug, ignore_errors=True)
                try: apply_config()
                except Exception: pass
                raise
            flash("Websitet blev oprettet.")
            return redirect(url_for("edit_site", slug=slug))
        except (ValueError, RuntimeError, OSError) as exc: flash(str(exc), "error")
    body = '''<div class="top"><div><h1>Nyt website</h1><div class="muted">Du kan ændre det hele senere</div></div></div><section class="card"><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><div class="form-grid"><div><label>Navn</label><input name="name" maxlength="80" placeholder="Min hjemmeside" required></div><div><label>Port</label><input name="port" type="number" min="1024" max="65535" value="{{ suggested }}" required><div class="help">Fx 8081. Dashboardet bruger 9090.</div></div></div><label>Domæner (valgfrit)</label><input name="domains" placeholder="minside.dk, www.minside.dk"><div class="help">Adskil flere domæner med komma. Cloudflare-ruten klarer forbindelsen, så domænet skal ikke pege på din hjemme-IP.</div><label>Adgang</label><select name="scope"><option value="lan">Kun mit lokale netværk</option><option value="tunnel">Offentlig via Cloudflare Tunnel – uden routerporte</option></select><div class="notice"><b>Sikker offentlig adgang:</b> Cloudflare Tunnel kræver ingen port forwarding. Du skal have et domæne til en fast offentlig adresse.</div><button style="margin-top:6px">Opret website</button> <a class="button secondary" href="{{ url_for('dashboard') }}">Annullér</a></form></section>'''
    used = {s["port"] for s in load_sites()}; suggested = next((p for p in range(8081, 9000) if p not in used), 10080)
    return page("Nyt website", body, suggested=suggested)

def get_site(slug):
    for site in load_sites():
        if site["slug"] == slug: return site
    abort(404)

def safe_extract(upload, destination):
    raw = upload.read()
    if not zipfile.is_zipfile(io.BytesIO(raw)): raise ValueError("Filen er ikke en gyldig ZIP-fil")
    stage = destination.parent / (".upload-" + secrets.token_hex(6)); stage.mkdir()
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            files = [x for x in archive.infolist() if not x.is_dir()]
            if len(files) > 5000 or sum(x.file_size for x in files) > 300*1024*1024: raise ValueError("ZIP-filen indeholder for meget data")
            for member in archive.infolist():
                normalized = Path(member.filename)
                if member.is_dir(): continue
                if normalized.is_absolute() or ".." in normalized.parts or (member.external_attr >> 16) & 0o170000 == 0o120000: raise ValueError("ZIP-filen indeholder en usikker sti eller et link")
                target = (stage / normalized).resolve()
                if stage.resolve() not in target.parents: raise ValueError("ZIP-filen indeholder en usikker sti")
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as src, target.open("wb") as dst: shutil.copyfileobj(src, dst)
        children = list(stage.iterdir())
        source = children[0] if len(children)==1 and children[0].is_dir() and not (stage/"index.html").exists() else stage
        if not (source/"index.html").exists(): raise ValueError("ZIP-filen skal indeholde index.html")
        backup_site(destination)
        old = destination.parent / (".old-" + secrets.token_hex(5))
        destination.rename(old)
        try:
            if source == stage: stage.rename(destination)
            else: source.rename(destination); shutil.rmtree(stage, ignore_errors=True)
            shutil.rmtree(old, ignore_errors=True)
        except Exception:
            if not destination.exists() and old.exists(): old.rename(destination)
            raise
    finally: shutil.rmtree(stage, ignore_errors=True)

def backup_site(public):
    if not public.exists(): return None
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = BACKUPS / f"{public.parent.name}-{stamp}"
    return shutil.make_archive(str(target), "zip", public)

@app.route("/sites/<slug>", methods=["GET", "POST"])
@logged_in
def edit_site(slug):
    site = get_site(slug); public = ROOT/slug/"public"; index = public/"index.html"
    if request.method == "POST":
        action = request.form.get("action")
        try:
            if action == "settings":
                name, _, port, scope, domains = validate_site_form(slug)
                old = dict(site); site.update(name=name,port=port,scope=scope,domains=domains,updated=datetime.now(timezone.utc).isoformat())
                sites=load_sites(); sites[sites.index(next(x for x in sites if x["slug"]==slug))]=site; save_sites(sites)
                try: apply_config()
                except Exception: sites[sites.index(site)]=old; save_sites(sites); apply_config(); raise
                flash("Indstillingerne er gemt.")
            elif action == "html":
                content=request.form.get("content", "")
                if len(content.encode()) > 1024*1024: raise ValueError("index.html må højst være 1 MB")
                backup_site(public); index.write_text(content)
                if site.get("runtime") == "node":
                    run_app_action("remove", slug)
                    update_site_runtime(slug, "static")
                    apply_config()
                flash("Forsiden er gemt.")
            elif action == "upload":
                upload=request.files.get("zipfile")
                if not upload or not upload.filename: raise ValueError("Vælg en ZIP-fil")
                safe_extract(upload, public)
                if site.get("runtime") == "node":
                    run_app_action("remove", slug)
                    update_site_runtime(slug, "static")
                    apply_config()
                flash("Website-filerne er uploadet. Den gamle version er gemt som backup.")
            elif action == "github":
                github_url = request.form.get("github_url", "").strip().rstrip("/")
                if not GITHUB_RE.fullmatch(github_url):
                    raise ValueError("Indsæt et offentligt GitHub-link, fx https://github.com/bruger/repository")
                backup_site(public)
                app_port = next_app_port(slug)
                runtime = run_app_action("deploy", slug, app_port, github_url)
                if runtime not in ("static", "node"):
                    raise RuntimeError("GitHub-importen returnerede en ukendt website-type")
                updated = update_site_runtime(
                    slug, runtime, source_url=github_url,
                    app_port=app_port if runtime == "node" else None,
                )
                apply_config()
                if runtime == "node" and not updated.get("active", True):
                    run_app_action("stop", slug)
                flash("GitHub-repository blev hentet og udgivet som " + ("Node-app." if runtime == "node" else "statisk website."))
            return redirect(url_for("edit_site",slug=slug))
        except (ValueError, RuntimeError, OSError, zipfile.BadZipFile) as exc: flash(str(exc),"error")
    try: content=index.read_text()[:1024*1024]
    except (FileNotFoundError,UnicodeDecodeError): content=""
    body='''<div class="top"><div><h1>{{ site.name }}</h1><div class="muted">/srv/nexushost-sites/{{ site.slug }}/public</div></div><a class="button secondary" href="{{ url_for('dashboard') }}">← Tilbage</a></div><section class="card"><h2>Indstillinger</h2><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="settings"><div class="form-grid"><div><label>Navn</label><input name="name" value="{{ site.name }}" required></div><div><label>Port</label><input name="port" type="number" min="1024" max="65535" value="{{ site.port }}" required></div></div><label>Domæner</label><input name="domains" value="{{ site.domains|join(', ') }}" placeholder="minside.dk, www.minside.dk"><div class="help">Adskil flere domæner med komma.</div><label>Adgang</label><select name="scope"><option value="lan" {{ 'selected' if site.scope=='lan' }}>Kun lokalt netværk</option><option value="tunnel" {{ 'selected' if site.scope=='tunnel' }}>Offentlig via Cloudflare Tunnel – uden routerporte</option>{% if site.scope=='public' %}<option value="public" selected>Ældre direkte offentlig opsætning – skift til Tunnel</option>{% endif %}</select><button style="margin-top:18px">Gem indstillinger</button></form>{% if site.scope=='tunnel' %}<div class="notice"><b>Cloudflare Service URL:</b><div class="code" style="margin-top:9px">http://localhost:{{ site.port }}</div><p style="margin-bottom:0"><a href="{{ url_for('cloudflare') }}">Åbn tunnelopsætningen →</a></p></div>{% elif site.scope=='public' %}<div class="notice warn"><b>Advarsel:</b> Dette site bruger den ældre direkte offentlige metode. Vælg Cloudflare Tunnel ovenfor, så routerporten kan lukkes.</div>{% endif %}</section><section class="card"><h2>Upload et færdigt website</h2><p class="muted">ZIP-filen skal indeholde en index.html. Maks. 100 MB. Din nuværende version bliver automatisk gemt som backup.</p><form method="post" enctype="multipart/form-data"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="upload"><input type="file" name="zipfile" accept=".zip" required><button style="margin-top:14px">Upload og udgiv</button></form></section><section class="card"><h2>Udgiv fra GitHub</h2><p class="muted">Indsæt linket til et offentligt GitHub-repository. NexusHost finder automatisk ud af, om det er et statisk website eller en Node-app med <b>npm start</b>.</p>{% if site.source_url %}<div class="domain" style="margin-bottom:14px">Kilde: {{ site.source_url }}</div>{% endif %}<form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="github"><label>GitHub repository</label><input name="github_url" type="url" placeholder="https://github.com/bruger/repository" required><div class="help">Kun offentlige repositories. Node-apps køres isoleret og starter automatisk efter genstart.</div><div class="notice warn"><b>Importér kun kode du stoler på.</b> En Node-app er rigtig serverkode og bliver kørt på maskinen.</div><button style="margin-top:14px">Hent fra GitHub og udgiv</button></form></section><section class="card"><h2>Redigér index.html</h2><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="html"><textarea name="content" spellcheck="false">{{ content }}</textarea><button style="margin-top:14px">Gem og udgiv</button></form></section>'''
    return page(site["name"], body, site=site, content=content)

@app.post("/sites/<slug>/toggle")
@logged_in
def toggle_site(slug):
    sites=load_sites(); site=next((x for x in sites if x["slug"]==slug),None)
    if not site: abort(404)
    site["active"]=not site["active"]; site["updated"]=datetime.now(timezone.utc).isoformat(); save_sites(sites)
    try:
        apply_config()
        if site.get("runtime") == "node":
            run_app_action("start" if site["active"] else "stop", slug)
        flash("Websitet er nu " + ("online." if site["active"] else "stoppet."))
    except RuntimeError as exc:
        site["active"]=not site["active"]; save_sites(sites)
        try:
            apply_config()
            if site.get("runtime") == "node":
                run_app_action("start" if site["active"] else "stop", slug)
        except RuntimeError:
            pass
        flash(str(exc),"error")
    return redirect(url_for("dashboard"))

@app.post("/sites/<slug>/delete")
@logged_in
def delete_site(slug):
    sites=load_sites(); site=next((x for x in sites if x["slug"]==slug),None)
    if not site: abort(404)
    folder=ROOT/slug
    try:
        backup_site(folder/"public"); sites.remove(site); save_sites(sites)
        try: apply_config()
        except Exception:
            sites.append(site); save_sites(sites); apply_config(); raise
        if site.get("runtime") == "node":
            run_app_action("delete", slug)
        shutil.rmtree(folder,ignore_errors=True); flash("Websitet blev fjernet. En ZIP-backup er gemt på serveren.")
    except (RuntimeError,OSError) as exc: flash(str(exc),"error")
    return redirect(url_for("dashboard"))

@app.route("/system")
@logged_in
def system():
    ip=current_ip(); sites=load_sites(); uptime="Ukendt"; state=tunnel_state()
    try:
        seconds=float(Path("/proc/uptime").read_text().split()[0]); uptime=f"{int(seconds//86400)} dage, {int(seconds%86400//3600)} timer"
    except OSError: pass
    body='''<div class="top"><div><h1>Serverinfo</h1><div class="muted">Status og næste skridt</div></div></div><div class="grid"><div class="stat"><span class="muted">Lokal IP</span><div class="big" style="font-size:18px">{{ ip }}</div></div><div class="stat"><span class="muted">Dashboard</span><div class="big">Port 80 / 9090</div></div><div class="stat"><span class="muted">Oppetid</span><div class="big" style="font-size:18px">{{ uptime }}</div></div><div class="stat"><span class="muted">Tunnel</span><div class="big" style="font-size:18px">{{ 'Forbundet' if state.active else 'Ikke forbundet' }}</div></div></div><section class="card"><h2>Sikker offentlig adgang</h2><p>Vælg <b>Cloudflare Tunnel</b> på et website. Så forbinder serveren ud til Cloudflare, og du skal ikke åbne porte eller ændre noget i routeren.</p><p><a class="button" href="{{ url_for('cloudflare') }}">Opsæt Cloudflare Tunnel</a></p><p class="muted">Muligheden Direkte offentlig findes kun til avancerede brugere og anbefales ikke på et hjemmenetværk.</p></section><section class="card"><h2>Automatisk opstart</h2><p>Dashboardet, alle aktive hjemmesider og en forbundet Cloudflare Tunnel starter automatisk efter en nedlukning eller genstart. Du skal ikke skrive nogen kommando.</p></section><section class="card"><h2>Nyttige kommandoer</h2><div class="domain">sudo systemctl status nexushost-webpanel<br>sudo systemctl status nexushost-tunnel<br>sudo journalctl -u nexushost-webpanel -f<br>sudo nginx -t</div></section>'''
    return page("Serverinfo",body,ip=ip,uptime=uptime,sites=sites,state=state)

@app.get("/health")
def health(): return {"ok":True}
PYAPP

SECRET_KEY="$(openssl rand -hex 32)"
PASSWORD_HASH="$(PW="$ADMIN_PASSWORD" python3 -c 'from werkzeug.security import generate_password_hash; import os; print(generate_password_hash(os.environ["PW"]))')"
python3 - "$DATA_DIR/config.json" "$ADMIN_USER" "$PASSWORD_HASH" "$SECRET_KEY" <<'PYCONFIG'
import json,sys
with open(sys.argv[1],"w") as f: json.dump({"username":sys.argv[2],"password_hash":sys.argv[3],"secret_key":sys.argv[4]},f)
PYCONFIG
[[ -f "$DATA_DIR/sites.json" ]] || printf '[]\n' > "$DATA_DIR/sites.json"
python3 - "$DATA_DIR/sites.json" <<'PYSCOPES'
import json, os, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        sites = json.load(handle)
except (OSError, json.JSONDecodeError):
    sites = []

changed = False
if isinstance(sites, list):
    for site in sites:
        if isinstance(site, dict) and site.get("scope") == "public":
            site["scope"] = "tunnel"
            changed = True
if changed:
    temporary = path + ".scope-update"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(sites, handle, ensure_ascii=False, indent=2)
    os.replace(temporary, path)
    print("Eksisterende offentlige websites er flyttet til sikker Cloudflare Tunnel-adgang.")
PYSCOPES
chown "$PANEL_USER:$PANEL_USER" "$DATA_DIR/config.json" "$DATA_DIR/sites.json"
chmod 0600 "$DATA_DIR/config.json" "$DATA_DIR/sites.json"
chown root:root "$PANEL_HOME/app.py"
chmod 0644 "$PANEL_HOME/app.py"

echo "[4/7] Konfigurerer Nginx..."
LAN_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./ {print; exit}')"
LAN_IP="${LAN_IP:-127.0.0.1}"
install -d -o root -g root -m 0755 /etc/nginx/nexushost-sites
cat > /etc/nginx/conf.d/nexushost-sites.conf <<'NGINXINCLUDE'
include /etc/nginx/nexushost-sites/*.conf;
NGINXINCLUDE
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/nexushost-panel <<NGINXPANEL
server {
    listen 80;
    listen [::]:80;
    listen ${PANEL_PORT};
    listen [::]:${PANEL_PORT};
    server_name localhost 127.0.0.1 ${LAN_IP};
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    allow ::1;
    allow fc00::/7;
    deny all;
    if (\$host !~* "^(localhost|127\\.0\\.0\\.1|10\\.[0-9.]+|192\\.168\\.[0-9.]+|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9.]+)$") {
        return 404;
    }
    client_max_body_size 100m;
    location / {
        proxy_pass http://127.0.0.1:9080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
NGINXPANEL
ln -sfn /etc/nginx/sites-available/nexushost-panel /etc/nginx/sites-enabled/nexushost-panel

echo "[5/7] Opretter automatisk opstart..."
cat > /etc/systemd/system/nexushost-webpanel.service <<EOF
[Unit]
Description=NexusHost Webpanel
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
User=${PANEL_USER}
Group=${PANEL_USER}
WorkingDirectory=${PANEL_HOME}
ExecStartPre=/usr/bin/sudo /usr/local/sbin/nexushost-panel-apply
ExecStart=${GUNICORN_START} --workers 2 --threads 4 --bind 127.0.0.1:9080 --access-logfile - app:app
Restart=always
RestartSec=3
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${SITE_ROOT} ${TUNNEL_DIR} /etc/nginx/nexushost-sites -/etc/ufw -/var/lib/ufw
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/nexushost-tunnel.service <<EOF
[Unit]
Description=NexusHost Cloudflare Tunnel
Documentation=https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/
After=network-online.target
Wants=network-online.target
ConditionPathExists=${TUNNEL_DIR}/tunnel-token

[Service]
Type=simple
User=${TUNNEL_USER}
Group=${TUNNEL_USER}
ExecStart=${CLOUDFLARED_BIN} --no-autoupdate tunnel run --token-file ${TUNNEL_DIR}/tunnel-token
Restart=always
RestartSec=5
TimeoutStopSec=20
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectKernelLogs=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0027

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/sudoers.d/nexushost-webpanel <<EOF
${PANEL_USER} ALL=(root) NOPASSWD: /usr/local/sbin/nexushost-panel-apply, /usr/local/sbin/nexushost-tunnel-control install, /usr/local/sbin/nexushost-tunnel-control restart, /usr/local/sbin/nexushost-tunnel-control disconnect
${PANEL_USER} ALL=(root) NOPASSWD: /usr/local/sbin/nexushost-app-control *
EOF
chmod 0440 /etc/sudoers.d/nexushost-webpanel

echo "[6/7] Tester opsætningen..."
/usr/sbin/visudo -cf /etc/sudoers.d/nexushost-webpanel
python3 -m py_compile "$PANEL_HOME/app.py" /usr/local/sbin/nexushost-panel-apply
bash -n /usr/local/sbin/nexushost-tunnel-control
bash -n /usr/local/sbin/nexushost-app-control
node -e 'if (Number(process.versions.node.split(".")[0]) < 20) process.exit(1)'
npm --version >/dev/null
git --version >/dev/null
python3 -c 'import flask, gunicorn, werkzeug'
CLOUDFLARED_HELP="$("$CLOUDFLARED_BIN" tunnel run --help 2>&1)"
if [[ "$CLOUDFLARED_HELP" != *"--token-file"* ]]; then
  echo "FEJL: Den installerede cloudflared-version er for gammel til sikker token-lagring."
  exit 1
fi
unset CLOUDFLARED_HELP
/usr/sbin/nginx -t
systemctl daemon-reload
systemctl enable nginx nexushost-webpanel nexushost-tunnel
systemctl restart nginx
systemctl restart nexushost-webpanel
if [[ -s "$TUNNEL_DIR/tunnel-token" ]]; then
  chown root:"$TUNNEL_USER" "$TUNNEL_DIR/tunnel-token"
  chmod 0640 "$TUNNEL_DIR/tunnel-token"
  install -o "$PANEL_USER" -g "$PANEL_USER" -m 0640 /dev/null "$DATA_DIR/tunnel-configured"
  systemctl restart nexushost-tunnel || true
fi

# If UFW is already active, allow the panel from private IPv4 networks without changing SSH rules.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow from 10.0.0.0/8 to any port 80 proto tcp comment 'NexusHost panel' >/dev/null || true
  ufw allow from 172.16.0.0/12 to any port 80 proto tcp comment 'NexusHost panel' >/dev/null || true
  ufw allow from 192.168.0.0/16 to any port 80 proto tcp comment 'NexusHost panel' >/dev/null || true
  ufw allow from 10.0.0.0/8 to any port "$PANEL_PORT" proto tcp comment 'NexusHost panel' >/dev/null || true
  ufw allow from 172.16.0.0/12 to any port "$PANEL_PORT" proto tcp comment 'NexusHost panel' >/dev/null || true
  ufw allow from 192.168.0.0/16 to any port "$PANEL_PORT" proto tcp comment 'NexusHost panel' >/dev/null || true
fi

PANEL_OK=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl --silent --fail --max-time 2 http://127.0.0.1/health | grep -q '"ok":true'; then
    PANEL_OK=true
    break
  fi
  sleep 1
done
if [[ "$PANEL_OK" != true ]]; then
  echo ""
  echo "FEJL: Dashboardet startede ikke korrekt. Her er fejlen:"
  journalctl -u nexushost-webpanel --no-pager -n 30 || true
  exit 1
fi

systemctl is-enabled --quiet nginx
systemctl is-enabled --quiet nexushost-webpanel
systemctl is-active --quiet nginx
systemctl is-active --quiet nexushost-webpanel

echo "[7/7] Færdig!"

cat <<DONE

╔══════════════════════════════════════════════════════════════╗
║                 NEXUSHOST WEBSERVER ER KLAR                   ║
╚══════════════════════════════════════════════════════════════╝

Dashboard:   http://${LAN_IP}
Alternativ:  http://${LAN_IP}:${PANEL_PORT}
Brugernavn:  ${ADMIN_USER}
Adgangskode: ${ADMIN_PASSWORD}

GEM ADGANGSKODEN NU. Den vises kun under installationen.

Åbn dashboardet fra en computer eller mobil på samme netværk.
Du skal ikke køre flere kommandoer efter en genstart.
Dashboardet og alle aktive hjemmesider starter automatisk med Ubuntu.
Cloudflare Tunnel kan forbindes fra menupunktet "Cloudflare Tunnel".
Du skal ikke åbne porte eller ændre noget i routeren.

Status: sudo systemctl status nexushost-webpanel
Logs:   sudo journalctl -u nexushost-webpanel -f
DONE
