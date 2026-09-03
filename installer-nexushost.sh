#!/usr/bin/env bash
set -Eeuo pipefail

# NexusHost Webpanel v2.1 - one-file installer for Ubuntu 22.04/24.04/26.04.
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
PANEL_HOME="/opt/nexushost-webpanel"
DATA_DIR="/var/lib/nexushost-webpanel"
SITE_ROOT="/srv/nexushost-sites"
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
apt-get install -y nginx python3 python3-flask python3-gunicorn unzip openssl curl sudo
if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'xy')"
fi

if ! id "$PANEL_USER" >/dev/null 2>&1; then
  useradd --system --home "$PANEL_HOME" --shell /usr/sbin/nologin "$PANEL_USER"
fi

install -d -o root -g root -m 0755 "$PANEL_HOME"
install -d -o "$PANEL_USER" -g "$PANEL_USER" -m 0750 "$DATA_DIR" "$DATA_DIR/backups"
install -d -o "$PANEL_USER" -g "$PANEL_USER" -m 0755 "$SITE_ROOT"

# Flyt automatisk data fra den tidligere udgave uden at vise det gamle navn igen.
LEGACY_TAG="$(printf '\143\141\162\163\164\145\156')"
LEGACY_USER="${LEGACY_TAG}-panel"
LEGACY_HOME="/opt/${LEGACY_TAG}-webpanel"
LEGACY_DATA="/var/lib/${LEGACY_TAG}-webpanel"
LEGACY_SITE_ROOT="/srv/${LEGACY_TAG}-sites"
LEGACY_SERVICE="${LEGACY_TAG}-webpanel"

systemctl disable --now "$LEGACY_SERVICE" >/dev/null 2>&1 || true
rm -f -- \
  "/etc/nginx/sites-enabled/${LEGACY_TAG}-panel" \
  "/etc/nginx/conf.d/${LEGACY_TAG}-sites.conf"

if [[ -f "$LEGACY_DATA/sites.json" ]]; then
  python3 - "$LEGACY_DATA/sites.json" "$DATA_DIR/sites.json" <<'PYMIGRATE'
import json, os, sys
old_path, new_path = sys.argv[1:]
try:
    with open(old_path) as handle:
        old_sites = json.load(handle)
except (OSError, json.JSONDecodeError):
    old_sites = []
try:
    with open(new_path) as handle:
        new_sites = json.load(handle)
except (OSError, json.JSONDecodeError):
    new_sites = []
known = {site.get("slug") for site in new_sites if isinstance(site, dict)}
for site in old_sites if isinstance(old_sites, list) else []:
    if isinstance(site, dict) and site.get("slug") not in known:
        new_sites.append(site)
        known.add(site.get("slug"))
temporary = new_path + ".migrate"
with open(temporary, "w") as handle:
    json.dump(new_sites, handle, ensure_ascii=False, indent=2)
os.replace(temporary, new_path)
PYMIGRATE
fi
if [[ -d "$LEGACY_SITE_ROOT" ]]; then
  cp -a -n "$LEGACY_SITE_ROOT/." "$SITE_ROOT/"
fi
if [[ -d "$LEGACY_DATA/backups" ]]; then
  cp -a -n "$LEGACY_DATA/backups/." "$DATA_DIR/backups/"
fi
chown -R "$PANEL_USER:$PANEL_USER" "$DATA_DIR" "$SITE_ROOT"

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
    if site.get("scope") not in ("lan", "public"): fail("Ugyldig adgangstype")
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
    domain_listeners = "\n    listen 80;\n    listen [::]:80;" if domains else ""
    access = ""
    if site["scope"] == "lan":
        access = """
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    allow ::1;
    allow fc00::/7;
    deny all;"""
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
    location / {{
        try_files $uri $uri/ =404;
    }}
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

    used_defaults = set()
    used_domains = set()
    wanted = set()
    for site in sites:
        slug, port, domains = validate(site)
        if not site.get("active", True):
            continue
        if not domains:
            if port in used_defaults: fail(f"Flere websites uden domæne bruger port {port}")
            used_defaults.add(port)
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
        status = subprocess.run([str(ufw), "status"], text=True, capture_output=True)
        if "Status: active" in status.stdout:
            for port in sorted({s["port"] for s in sites if s.get("active", True)}):
                is_public = any(s.get("active", True) and s["port"] == port and s["scope"] == "public" for s in sites)
                if is_public:
                    subprocess.run([str(ufw), "allow", f"{port}/tcp", "comment", "NexusHost public site"], check=True, stdout=subprocess.DEVNULL)
                else:
                    for subnet in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"):
                        subprocess.run([str(ufw), "allow", "from", subnet, "to", "any", "port", str(port), "proto", "tcp", "comment", "NexusHost LAN site"], check=True, stdout=subprocess.DEVNULL)
            if any(s.get("active", True) and s["scope"] == "public" and s.get("domains") for s in sites):
                subprocess.run([str(ufw), "allow", "80/tcp", "comment", "NexusHost public domains"], check=True, stdout=subprocess.DEVNULL)

if __name__ == "__main__":
    main()
PYHELPER
chmod 0755 /usr/local/sbin/nexushost-panel-apply
chown root:root /usr/local/sbin/nexushost-panel-apply

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
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,48}$")
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")

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
:root{--bg:#07111f;--panel:#101d30;--soft:#182940;--line:#253b57;--text:#eef6ff;--muted:#91a6bd;--blue:#38a5ff;--cyan:#52e5d5;--red:#ff6474;--green:#41d898;--shadow:0 24px 65px #02081299}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 15% 0,#12325a 0,transparent 34%),var(--bg);color:var(--text);font:15px Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;min-height:100vh}a{color:inherit}.shell{display:grid;grid-template-columns:245px 1fr;min-height:100vh}.side{padding:27px 20px;border-right:1px solid var(--line);background:#091523dd;backdrop-filter:blur(18px)}.brand{display:flex;gap:12px;align-items:center;font-weight:800;font-size:18px;margin:0 8px 32px}.logo{width:36px;height:36px;border-radius:12px;background:linear-gradient(135deg,var(--blue),var(--cyan));box-shadow:0 0 26px #38a5ff55;display:grid;place-items:center;color:#03233a}.nav a{display:flex;text-decoration:none;padding:12px 13px;border-radius:11px;color:var(--muted);margin:4px 0}.nav a:hover,.nav a.on{background:var(--soft);color:white}.side-foot{position:fixed;bottom:24px;color:var(--muted);font-size:12px;padding:0 8px}.main{padding:32px;max-width:1500px;width:100%}.top{display:flex;justify-content:space-between;gap:20px;align-items:center;margin-bottom:26px}.top h1{font-size:29px;margin:0 0 5px}.muted{color:var(--muted)}.button,button{border:0;border-radius:10px;background:linear-gradient(135deg,var(--blue),#2479ff);color:white;padding:11px 16px;font-weight:700;cursor:pointer;text-decoration:none;display:inline-block}.button.secondary,button.secondary{background:var(--soft);border:1px solid var(--line)}button.danger,.danger{background:#3a1721;color:#ff98a3;border:1px solid #6b2735}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:22px}.stat,.card{border:1px solid var(--line);border-radius:16px;background:linear-gradient(155deg,#13233aee,#0c1829ee);box-shadow:var(--shadow)}.stat{padding:18px}.stat .big{font-size:25px;font-weight:800;margin-top:7px}.card{padding:20px;margin-bottom:18px}.sites{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:16px}.site{padding:19px;border:1px solid var(--line);border-radius:15px;background:#101e31}.row{display:flex;align-items:center;justify-content:space-between;gap:12px}.site h3{margin:0 0 4px;font-size:18px}.pill{padding:5px 9px;border-radius:99px;font-size:12px;font-weight:800}.pill.on{background:#123d32;color:#67e8b4}.pill.off{background:#3b2530;color:#ff9aa7}.pill.lan{background:#193451;color:#72beff}.domain{font-family:ui-monospace,monospace;color:#bcd0e6;background:#0a1423;padding:8px 10px;border-radius:9px;margin:12px 0;word-break:break-all}.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:15px}.actions button,.actions .button{font-size:13px;padding:8px 11px}label{font-weight:700;display:block;margin:13px 0 7px}input,textarea,select{width:100%;border:1px solid var(--line);border-radius:10px;background:#091523;color:white;padding:12px;outline:none}input:focus,textarea:focus,select:focus{border-color:var(--blue);box-shadow:0 0 0 3px #38a5ff22}textarea{min-height:350px;font-family:ui-monospace,monospace;line-height:1.5}.form-grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}.help{color:var(--muted);font-size:13px;margin-top:6px}.flash{padding:12px 14px;border-radius:11px;margin-bottom:15px;background:#143b31;border:1px solid #23684f}.flash.error{background:#3a1721;border-color:#6b2735}.empty{text-align:center;padding:55px 20px;color:var(--muted)}.login-wrap{min-height:100vh;display:grid;place-items:center;padding:20px}.login{width:min(420px,100%);padding:30px}.login h1{margin:0 0 8px}@media(max-width:900px){.shell{grid-template-columns:1fr}.side{display:none}.main{padding:20px}.grid{grid-template-columns:1fr 1fr}.form-grid{grid-template-columns:1fr}}@media(max-width:520px){.grid{grid-template-columns:1fr}.top{align-items:flex-start;flex-direction:column}}
'''

BASE = r'''<!doctype html><html lang="da"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{{ title }} · NexusHost</title><style>''' + STYLE + r'''</style></head><body>
{% if session.get('logged_in') %}<div class="shell"><aside class="side"><div class="brand"><span class="logo">N</span> NexusHost Panel</div><nav class="nav"><a class="on" href="{{ url_for('dashboard') }}">● Websites</a><a href="{{ url_for('new_site') }}">＋ Tilføj website</a><a href="{{ url_for('system') }}">◫ Serverinfo</a><a href="{{ url_for('logout') }}">↪ Log ud</a></nav><div class="side-foot">Nginx · Ubuntu · gratis</div></aside><main class="main">{% else %}<div class="login-wrap"><main class="card login">{% endif %}
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
    body = '''<h1>Velkommen tilbage</h1><p class="muted">Log ind for at styre din Ubuntu-webserver.</p><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><label>Brugernavn</label><input name="username" autocomplete="username" required autofocus><label>Adgangskode</label><input type="password" name="password" autocomplete="current-password" required><button style="width:100%;margin-top:18px">Log ind</button></form>'''
    return page("Log ind", body)

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/")
@logged_in
def dashboard():
    sites = load_sites(); ip = current_ip()
    used = shutil.disk_usage(ROOT)
    body = '''<div class="top"><div><h1>Dine websites</h1><div class="muted">Administrér alt fra ét sted</div></div><a class="button" href="{{ url_for('new_site') }}">＋ Nyt website</a></div>
    <div class="grid"><div class="stat"><span class="muted">Websites</span><div class="big">{{ sites|length }}</div></div><div class="stat"><span class="muted">Online</span><div class="big">{{ sites|selectattr('active')|list|length }}</div></div><div class="stat"><span class="muted">Server-IP</span><div class="big" style="font-size:18px">{{ ip }}</div></div><div class="stat"><span class="muted">Ledig disk</span><div class="big">{{ free }} GB</div></div></div>
    <div class="sites">{% for s in sites %}<article class="site"><div class="row"><div><h3>{{ s.name }}</h3><span class="muted">Port {{ s.port }}</span></div><span class="pill {{ 'on' if s.active else 'off' }}">{{ 'ONLINE' if s.active else 'STOPPET' }}</span></div><div class="domain">{% if s.domains %}{{ s.domains|join(', ') }}{% else %}{{ ip }}:{{ s.port }}{% endif %}</div><div class="row"><span class="pill {{ 'lan' if s.scope == 'lan' else 'on' }}">{{ 'Kun netværk' if s.scope == 'lan' else 'Offentlig' }}</span><span class="muted">{{ s.updated[:10] }}</span></div><div class="actions"><a class="button secondary" href="{{ url_for('edit_site', slug=s.slug) }}">Redigér</a><a class="button secondary" href="http://{% if s.domains %}{{ s.domains[0] }}{% else %}{{ ip }}:{{ s.port }}{% endif %}" target="_blank">Åbn</a><form method="post" action="{{ url_for('toggle_site', slug=s.slug) }}"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><button class="secondary">{{ 'Stop' if s.active else 'Start' }}</button></form><form method="post" action="{{ url_for('delete_site', slug=s.slug) }}" onsubmit="return confirm('Flyt websitet til backup og fjern det?')"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><button class="danger">Slet</button></form></div></article>{% else %}<div class="card empty"><h2>Ingen websites endnu</h2><p>Opret dit første website på under ét minut.</p><a class="button" href="{{ url_for('new_site') }}">Opret website</a></div>{% endfor %}</div>'''
    return page("Websites", body, sites=sites, ip=ip, free=round(used.free/1024**3, 1))

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
    if scope not in ("lan", "public"): raise ValueError("Vælg en adgangstype")
    domains = parse_domains(request.form.get("domains", ""))
    sites = load_sites()
    for other in sites:
        if other["slug"] == slug: continue
        if not domains and not other["domains"] and other["port"] == port: raise ValueError("Porten bruges allerede af et website uden domæne")
        if set(domains) & set(other["domains"]): raise ValueError("Domænet bruges allerede af et andet website")
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
            site = {"name":name,"slug":slug,"port":port,"scope":scope,"domains":domains,"active":True,"created":now,"updated":now}
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
    body = '''<div class="top"><div><h1>Nyt website</h1><div class="muted">Du kan ændre det hele senere</div></div></div><section class="card"><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><div class="form-grid"><div><label>Navn</label><input name="name" maxlength="80" placeholder="Min hjemmeside" required></div><div><label>Port</label><input name="port" type="number" min="1024" max="65535" value="{{ suggested }}" required><div class="help">Fx 8081. Panel bruger 9090.</div></div></div><label>Domæner (valgfrit)</label><input name="domains" placeholder="minside.dk, www.minside.dk"><div class="help">Adskil flere domæner med komma. DNS skal pege mod din offentlige IP.</div><label>Adgang</label><select name="scope"><option value="lan">Kun mit lokale netværk (anbefalet til test)</option><option value="public">Offentlig på internettet</option></select><button style="margin-top:20px">Opret website</button> <a class="button secondary" href="{{ url_for('dashboard') }}">Annullér</a></form></section>'''
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
                backup_site(public); index.write_text(content); flash("Forsiden er gemt.")
            elif action == "upload":
                upload=request.files.get("zipfile")
                if not upload or not upload.filename: raise ValueError("Vælg en ZIP-fil")
                safe_extract(upload, public); flash("Website-filerne er uploadet. Den gamle version er gemt som backup.")
            return redirect(url_for("edit_site",slug=slug))
        except (ValueError, RuntimeError, OSError, zipfile.BadZipFile) as exc: flash(str(exc),"error")
    try: content=index.read_text()[:1024*1024]
    except (FileNotFoundError,UnicodeDecodeError): content=""
    body='''<div class="top"><div><h1>{{ site.name }}</h1><div class="muted">/srv/nexushost-sites/{{ site.slug }}/public</div></div><a class="button secondary" href="{{ url_for('dashboard') }}">← Tilbage</a></div><section class="card"><h2>Indstillinger</h2><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="settings"><div class="form-grid"><div><label>Navn</label><input name="name" value="{{ site.name }}" required></div><div><label>Port</label><input name="port" type="number" min="1024" max="65535" value="{{ site.port }}" required></div></div><label>Domæner</label><input name="domains" value="{{ site.domains|join(', ') }}"><label>Adgang</label><select name="scope"><option value="lan" {{ 'selected' if site.scope=='lan' }}>Kun lokalt netværk</option><option value="public" {{ 'selected' if site.scope=='public' }}>Offentlig på internettet</option></select><button style="margin-top:18px">Gem indstillinger</button></form></section><section class="card"><h2>Upload et færdigt website</h2><p class="muted">ZIP-filen skal indeholde en index.html. Maks. 100 MB. Din nuværende version bliver automatisk gemt som backup.</p><form method="post" enctype="multipart/form-data"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="upload"><input type="file" name="zipfile" accept=".zip" required><button style="margin-top:14px">Upload og udgiv</button></form></section><section class="card"><h2>Redigér index.html</h2><form method="post"><input type="hidden" name="csrf" value="{{ csrf_token() }}"><input type="hidden" name="action" value="html"><textarea name="content" spellcheck="false">{{ content }}</textarea><button style="margin-top:14px">Gem og udgiv</button></form></section>'''
    return page(site["name"], body, site=site, content=content)

@app.post("/sites/<slug>/toggle")
@logged_in
def toggle_site(slug):
    sites=load_sites(); site=next((x for x in sites if x["slug"]==slug),None)
    if not site: abort(404)
    site["active"]=not site["active"]; site["updated"]=datetime.now(timezone.utc).isoformat(); save_sites(sites)
    try: apply_config(); flash("Websitet er nu " + ("online." if site["active"] else "stoppet."))
    except RuntimeError as exc:
        site["active"]=not site["active"]; save_sites(sites)
        try: apply_config()
        except RuntimeError: pass
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
        shutil.rmtree(folder,ignore_errors=True); flash("Websitet blev fjernet. En ZIP-backup er gemt på serveren.")
    except (RuntimeError,OSError) as exc: flash(str(exc),"error")
    return redirect(url_for("dashboard"))

@app.route("/system")
@logged_in
def system():
    ip=current_ip(); sites=load_sites(); uptime="Ukendt"
    try:
        seconds=float(Path("/proc/uptime").read_text().split()[0]); uptime=f"{int(seconds//86400)} dage, {int(seconds%86400//3600)} timer"
    except OSError: pass
    body='''<div class="top"><div><h1>Serverinfo</h1><div class="muted">Status og næste skridt</div></div></div><div class="grid"><div class="stat"><span class="muted">Lokal IP</span><div class="big" style="font-size:18px">{{ ip }}</div></div><div class="stat"><span class="muted">Dashboard</span><div class="big">Port 80 / 9090</div></div><div class="stat"><span class="muted">Oppetid</span><div class="big" style="font-size:18px">{{ uptime }}</div></div><div class="stat"><span class="muted">Aktive sites</span><div class="big">{{ sites|selectattr('active')|list|length }}</div></div></div><section class="card"><h2>Sådan gør du et website offentligt</h2><p>1. Vælg <b>Offentlig</b> på websitet.</p><p>2. Uden domæne: port-forward websitets valgte TCP-port til <b>{{ ip }}</b>.</p><p>3. Med domæne: port-forward TCP-port 80, og lad domænets A-record pege på din offentlige IP.</p><p class="muted">Din internetudbyder kan bruge CGNAT. I så fald virker almindelig port-forwarding ikke, og du skal bruge fx Cloudflare Tunnel.</p></section><section class="card"><h2>Automatisk opstart</h2><p>Dashboardet og alle websites, der står som <b>ONLINE</b>, starter automatisk efter en nedlukning eller genstart. Du skal ikke skrive nogen kommando.</p></section><section class="card"><h2>Nyttige kommandoer</h2><div class="domain">sudo systemctl status nexushost-webpanel<br>sudo journalctl -u nexushost-webpanel -f<br>sudo nginx -t</div></section>'''
    return page("Serverinfo",body,ip=ip,uptime=uptime,sites=sites)

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
ExecStart=/usr/bin/gunicorn --workers 2 --threads 4 --bind 127.0.0.1:9080 --access-logfile - app:app
Restart=always
RestartSec=3
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${SITE_ROOT} /etc/nginx/nexushost-sites -/etc/ufw -/var/lib/ufw
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/sudoers.d/nexushost-webpanel <<EOF
${PANEL_USER} ALL=(root) NOPASSWD: /usr/local/sbin/nexushost-panel-apply
EOF
chmod 0440 /etc/sudoers.d/nexushost-webpanel

echo "[6/7] Tester opsætningen..."
/usr/sbin/visudo -cf /etc/sudoers.d/nexushost-webpanel
python3 -m py_compile "$PANEL_HOME/app.py" /usr/local/sbin/nexushost-panel-apply
/usr/sbin/nginx -t
systemctl daemon-reload
systemctl enable nginx nexushost-webpanel
systemctl restart nginx
systemctl restart nexushost-webpanel

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

# Den nye udgave virker; fjern nu resterne af den tidligere udgave.
rm -f -- \
  "/etc/systemd/system/${LEGACY_SERVICE}.service" \
  "/etc/sudoers.d/${LEGACY_SERVICE}" \
  "/usr/local/sbin/${LEGACY_TAG}-panel-apply" \
  "/etc/nginx/sites-available/${LEGACY_TAG}-panel"
if [[ "$LEGACY_HOME" == "/opt/${LEGACY_TAG}-webpanel" && \
      "$LEGACY_DATA" == "/var/lib/${LEGACY_TAG}-webpanel" && \
      "$LEGACY_SITE_ROOT" == "/srv/${LEGACY_TAG}-sites" ]]; then
  rm -rf -- "$LEGACY_HOME" "$LEGACY_DATA" "$LEGACY_SITE_ROOT" "/etc/nginx/${LEGACY_TAG}-sites"
fi
if id "$LEGACY_USER" >/dev/null 2>&1; then
  userdel "$LEGACY_USER" >/dev/null 2>&1 || true
fi
systemctl daemon-reload

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

Status: sudo systemctl status nexushost-webpanel
Logs:   sudo journalctl -u nexushost-webpanel -f
DONE
