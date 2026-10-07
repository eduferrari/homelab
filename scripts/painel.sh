#!/usr/bin/env bash
# Painel geral do homelab — uma página com tudo: alertas, atalhos para os painéis, saúde do
# servidor, containers por projeto, domínios públicos, tráfego das últimas 24 h, backup e
# certificados. Gerado a cada minuto pelo homelab-painel.timer (instalado pelo monitor.sh) e
# servido pelo proxy na porta do painel (padrão https://<host>:9440, só LAN, com senha).
#
#   sudo painel.sh            # gera a página agora ($MONITOR_DIR/painel/index.html e status.json)
#   sudo painel.sh json       # mostra o status.json gerado
set -Eeuo pipefail
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
export HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
export PROXY_DIR="${PROXY_DIR:-$HOMELAB_DIR/proxy}"
export MONITOR_DIR="${MONITOR_DIR:-$HOMELAB_DIR/monitor}"
export PAINEL_OUT="${PAINEL_OUT:-$MONITOR_DIR/painel}"
export BACKUP_LOG="${BACKUP_LOG_FILE:-/var/log/homelab/backup.log}"

die() { echo "✘ $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"
command -v python3 >/dev/null || die "python3 não encontrado"

case "${1:-gerar}" in
  gerar|run) ;;
  json) exec cat "$PAINEL_OUT/status.json" ;;
  -h|--help) sed -n '2,/^set -Eeuo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) die "Comando desconhecido: $1 (veja: $0 --help)" ;;
esac

install -d -m 755 "$PAINEL_OUT"
exec python3 - <<'PY'
import datetime as dt, html, json, os, re, shlex, socket, subprocess, base64, time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

E = os.environ
HOMELAB, PROXY, MONITOR, OUT = E["HOMELAB_DIR"], E["PROXY_DIR"], E["MONITOR_DIR"], E["PAINEL_OUT"]
NOW = dt.datetime.now().astimezone()
alerts = []   # (nível, texto)  nível: "erro" | "aviso"

def run(cmd, timeout=20, inp=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=inp)
        return r.stdout if r.returncode == 0 else ""
    except Exception:
        return ""

def read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return default

def shconf(path):
    """Lê um arquivo KEY=valor (estilo shell) sem executá-lo."""
    out = {}
    for line in read(path).splitlines():
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
        if not m:
            continue
        try:
            v = shlex.split(m.group(2), comments=True)
            out[m.group(1)] = v[0] if v else ""
        except ValueError:
            out[m.group(1)] = m.group(2).strip().strip('"\'')
    return out

def human(n):
    n = float(n)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or u == "TB":
            return f"{n:.0f} {u}" if u in ("B", "KB") else f"{n:.1f} {u}"
        n /= 1024

def ago(t):
    s = int((NOW - t).total_seconds())
    if s < 0:
        s = -s; pre = "em "; suf = ""
    else:
        pre = ""; suf = " atrás"
    if s < 90: return f"{pre}{s} s{suf}"
    if s < 5400: return f"{pre}{s // 60} min{suf}"
    if s < 172800: return f"{pre}{s // 3600} h{suf}"
    return f"{pre}{s // 86400} dias{suf}"

infra = shconf(f"{HOMELAB}/infra/.env")
mon = shconf(f"{MONITOR}/monitor.conf")
proxyconf = shconf(f"{PROXY}/proxy.conf")
hostname = socket.gethostname()

# ------------------------------------------------------------------ servidor
def host_info():
    h = {"hostname": hostname}
    try:
        up = float(read("/proc/uptime").split()[0]); d, r = divmod(int(up), 86400)
        h["uptime"] = (f"{d} d " if d else "") + f"{r // 3600} h {r % 3600 // 60} min"
    except Exception:
        h["uptime"] = "?"
    try:
        h["load"] = read("/proc/loadavg").split()[:3]; h["cpus"] = os.cpu_count()
        if float(h["load"][1]) > (h["cpus"] or 1) * 1.5:
            alerts.append(("aviso", f"Carga alta: {h['load'][1]} (5 min) para {h['cpus']} CPUs"))
    except Exception:
        pass
    mem = {}
    for line in read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        mem[k] = int(v.split()[0]) * 1024 if v.split() else 0
    if mem.get("MemTotal"):
        used = mem["MemTotal"] - mem.get("MemAvailable", 0)
        h["mem"] = {"used": used, "total": mem["MemTotal"], "pct": round(100 * used / mem["MemTotal"])}
        if h["mem"]["pct"] >= 90:
            alerts.append(("aviso", f"Memória em {h['mem']['pct']}%"))
    disks, seen = [], set()
    ext = infra.get("BACKUP_EXTERNAL_MOUNT", "")
    for label, path in (("Sistema", "/"), ("Backups", f"{HOMELAB}/backups"), ("Docker", "/var/lib/docker"), ("Disco externo", ext)):
        if not path or not os.path.exists(path):
            continue
        if label == "Disco externo" and not os.path.ismount(path):
            continue
        st = os.statvfs(path)
        if st.f_fsid in seen and label != "Disco externo":
            continue
        seen.add(st.f_fsid)
        total = st.f_blocks * st.f_frsize; free = st.f_bavail * st.f_frsize
        pct = round(100 * (total - free) / total) if total else 0
        disks.append({"label": label, "path": path, "total": total, "free": free, "pct": pct})
        if pct >= 90: alerts.append(("erro", f"Disco {label} ({path}) em {pct}%"))
        elif pct >= 80: alerts.append(("aviso", f"Disco {label} ({path}) em {pct}%"))
    h["disks"] = disks
    ps = "/sys/class/power_supply"
    supplies = os.listdir(ps) if os.path.isdir(ps) else []
    for b in sorted(p for p in supplies if p.startswith("BAT")):
        cap, st = read(f"{ps}/{b}/capacity").strip(), read(f"{ps}/{b}/status").strip()
        if not cap:
            continue
        mains = [p for p in supplies if read(f"{ps}/{p}/type").strip() == "Mains"]
        ac = any(read(f"{ps}/{p}/online").strip() == "1" for p in mains) if mains else st != "Discharging"
        h["battery"] = {"pct": int(cap), "status": st, "ac": ac}
        if not ac:
            alerts.append(("erro", f"Sem energia da tomada — bateria em {cap}%"))
        break
    temps = []
    if os.path.isdir("/sys/class/thermal"):
        for z in os.listdir("/sys/class/thermal"):
            t = read(f"/sys/class/thermal/{z}/temp").strip()
            if z.startswith("thermal_zone") and t.lstrip("-").isdigit() and int(t) > 0:
                temps.append(int(t) / 1000)
    if temps:
        h["temp"] = round(max(temps))
        if h["temp"] >= 85: alerts.append(("aviso", f"Temperatura alta: {h['temp']} °C"))
    return h

# ---------------------------------------------------------------- containers
def containers():
    rows = []
    out = run(["docker", "ps", "-a", "--no-trunc", "--format", "{{json .}}"])
    stats = {}
    for line in run(["docker", "stats", "--no-stream", "--format", "{{json .}}"], timeout=30).splitlines():
        try:
            s = json.loads(line); stats[s["Name"]] = s
        except Exception:
            pass
    ids = []
    for line in out.splitlines():
        try:
            ids.append(json.loads(line)["ID"])
        except Exception:
            pass
    inspect = json.loads(run(["docker", "inspect", *ids]) or "[]") if ids else []
    for c in inspect:
        name = c["Name"].lstrip("/"); st = c["State"]; lab = c["Config"].get("Labels") or {}
        project = lab.get("com.docker.compose.project") or "(sem projeto)"
        health = (st.get("Health") or {}).get("Status", "")
        started = st.get("StartedAt", "")
        try:
            since = ago(dt.datetime.fromisoformat(re.sub(r"\.\d+", "", started).replace("Z", "+00:00"))) if st.get("Running") else ""
        except Exception:
            since = ""
        level = "ok"
        if st.get("Restarting"):
            level = "erro"
        elif st.get("Running"):
            level = {"unhealthy": "erro", "starting": "aviso"}.get(health, "ok")
        elif st.get("Status") == "dead" or (st.get("Status") == "exited" and st.get("ExitCode") not in (0, 137, 143)):
            level = "erro"   # terminou com erro (0/137/143 = parado de propósito: docker stop)
        else:
            level = "parado"
        s = stats.get(name, {})
        rows.append({
            "name": name, "project": project, "service": lab.get("com.docker.compose.service", ""),
            "image": c["Config"].get("Image", ""), "status": st.get("Status"), "health": health,
            "exit": st.get("ExitCode"), "restarts": c.get("RestartCount", 0), "since": since,
            "cpu": s.get("CPUPerc", ""), "mem": (s.get("MemUsage", "").split(" / ")[0]), "level": level,
        })
        if level == "erro":
            what = "reiniciando" if st.get("Restarting") else health if health == "unhealthy" else f"parado (código {st.get('ExitCode')})"
            where = f" ({project})" if lab.get("com.docker.compose.project") else ""
            alerts.append(("erro", f"Container {name}{where}: {what}"))
    rows.sort(key=lambda r: (r["project"] == "(sem projeto)", r["project"], r["name"]))
    return rows

# ---------------------------------------------------------- certificados LE
def openssl_end(pem):
    o = run(["openssl", "x509", "-noout", "-enddate", "-subject"], inp=pem)
    m = re.search(r"notAfter=(.+)", o)
    if not m:
        return None
    try:
        return dt.datetime.strptime(m.group(1).strip(), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None

def acme_certs():
    certs = {}
    try:
        data = json.loads(read(f"{PROXY}/acme/acme.json") or "{}")
    except ValueError:
        return certs
    for resolver in data.values():
        for c in (resolver or {}).get("Certificates") or []:
            dom = (c.get("domain") or {}).get("main")
            try:
                pem = base64.b64decode(c.get("certificate", "")).decode()
            except Exception:
                continue
            end = openssl_end(pem)
            if dom and end:
                for d in [dom, *((c.get("domain") or {}).get("sans") or [])]:
                    certs[d] = end
    return certs

def public_domains(certs):
    doms = {}
    apps = f"{HOMELAB}/apps"
    if os.path.isdir(apps):
        for p in sorted(os.listdir(apps)):
            for line in read(f"{apps}/{p}/public-routes.conf").splitlines():
                parts = line.split("#")[0].split()
                if len(parts) >= 2:
                    doms[parts[1]] = {"project": p, "service": parts[0]}
    for d in certs:
        doms.setdefault(d, {"project": "", "service": ""})
    def check(d):
        # corpo + "código tempo" na última linha: o corpo diferencia o 404/503 do próprio Traefik
        # (rota ausente / sem servidor) do 404 da aplicação (ex.: raiz de uma API)
        o = run(["curl", "--noproxy", "*", "-sk", "--max-filesize", "65536", "-w", "\n%{http_code} %{time_total}", "-m", "8",
                 "--resolve", f"{d}:443:127.0.0.1", f"https://{d}/"], timeout=12) or "\n000 0"
        body, _, last = o.rpartition("\n")
        code, t = (last.split() + ["0", "0"])[:2]
        proxy = {"404 page not found": "sem rota no proxy", "no available server": "proxy sem servidor disponível"}.get(body.strip(), "")
        return d, code, round(float(t) * 1000), proxy
    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(check, doms))
    rows = []
    for d, code, ms, proxy in results:
        end = certs.get(d) or certs.get("*." + d.split(".", 1)[-1])
        days = (end - NOW).days if end else None
        level = "ok"
        if proxy:
            level = "erro"
            hint = (" — rotas públicas fora do container? rode: public-route.sh apply na pasta do projeto"
                    if proxy == "sem rota no proxy" else " — container parado, reiniciando ou unhealthy")
            alerts.append(("erro", f"{d}: HTTP {code}, {proxy}{hint}"))
        elif code == "000" or code.startswith("5"):
            level = "erro"; alerts.append(("erro", f"{d}: {'sem resposta' if code == '000' else 'HTTP ' + code}"))
        if days is None:
            level = "erro"; alerts.append(("erro", f"{d}: sem certificado Let's Encrypt"))
        elif days < 15:
            level = "erro" if days < 7 else ("aviso" if level == "ok" else level)
            alerts.append(("erro" if days < 7 else "aviso", f"Certificado de {d} vence em {days} dias"))
        rows.append({"domain": d, **doms[d], "code": code, "ms": ms, "proxy": proxy, "cert_days": days,
                     "cert_end": end.astimezone().strftime("%d/%m/%Y") if end else "", "level": level})
    return rows

# ------------------------------------------------------------------ tráfego
LINE = re.compile(r'\[(\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\] "[^"]*" (\d{3}) \S+ "[^"]*" "[^"]*" \d+ "([^"]*)" "[^"]*" (\d+)ms')
def traffic():
    since = NOW - dt.timedelta(hours=24)
    by = defaultdict(lambda: {"req": 0, "c4": 0, "c5": 0, "ms": 0, "last": None})
    total = {"req": 0, "c4": 0, "c5": 0}
    for f in (f"{PROXY}/logs/access.log.1", f"{PROXY}/logs/access.log"):
        try:
            size = os.path.getsize(f)
            with open(f, "rb") as fh:
                if size > 64 * 1024 * 1024:
                    fh.seek(size - 64 * 1024 * 1024); fh.readline()
                for raw in fh:
                    m = LINE.search(raw.decode("utf-8", "replace"))
                    if not m:
                        continue
                    t = dt.datetime.strptime(m.group(1), "%d/%b/%Y:%H:%M:%S %z")
                    if t < since:
                        continue
                    router = m.group(3) if m.group(3) not in ("-", "") else "(sem rota)"
                    r = by[router]; code = m.group(2)
                    r["req"] += 1; r["ms"] += int(m.group(4)); total["req"] += 1
                    if code[0] == "4": r["c4"] += 1; total["c4"] += 1
                    if code[0] == "5": r["c5"] += 1; total["c5"] += 1
                    if not r["last"] or t > r["last"]: r["last"] = t
        except OSError:
            continue
    rows = []
    for k, v in sorted(by.items(), key=lambda kv: -kv[1]["req"]):
        rows.append({"router": k, "req": v["req"], "c4": v["c4"], "c5": v["c5"],
                     "avg_ms": round(v["ms"] / v["req"]) if v["req"] else 0,
                     "last": ago(v["last"]) if v["last"] else ""})
        if v["req"] >= 20 and v["c5"] / v["req"] > 0.05:
            alerts.append(("aviso", f"Rota {k}: {v['c5']} erros 5xx em {v['req']} requisições (24 h)"))
    return {"total": total, "routers": rows[:25]}

# ------------------------------------------------------------------- backup
def backup():
    b = {}
    try:
        b["last"] = json.loads(read(f"{HOMELAB}/backups/last-status.json") or "null")
    except ValueError:
        b["last"] = None
    last = b["last"]
    if last:
        t = dt.datetime.fromisoformat(last["time"])
        b["when"] = ago(t); b["age_h"] = (NOW - t).total_seconds() / 3600
        if not last.get("ok"):
            alerts.append(("erro", f"Último backup: {last.get('message')}"))
        elif b["age_h"] > 26:
            alerts.append(("erro", f"Último backup bem-sucedido foi há {int(b['age_h'])} h"))
    else:
        latest = os.path.join(HOMELAB, "backups", "latest")
        b["latest"] = os.readlink(latest) if os.path.islink(latest) else ""
        alerts.append(("aviso", "Sem registro de backup (last-status.json) — rode: sudo backup.sh"))
    nxt = run(["systemctl", "show", "homelab-backup.timer", "-p", "NextElapseUSecRealtime", "--value"]).strip()
    b["next"] = nxt or ""
    ext, extdir = infra.get("BACKUP_EXTERNAL_MOUNT", ""), infra.get("BACKUP_EXTERNAL_DIR", "")
    if ext:
        b["external"] = {"mount": ext, "mounted": os.path.ismount(ext)}
        if b["external"]["mounted"]:
            lk = os.path.join(extdir, "latest")
            b["external"]["latest"] = os.readlink(lk) if os.path.islink(lk) else ""
        else:
            alerts.append(("erro", f"Disco externo de backup não está montado ({ext})"))
    else:
        b["external"] = None
    b["log"] = read(E["BACKUP_LOG"]).splitlines()[-30:]
    return b

# --------------------------------------------------------- certificado LAN
def lan_cert():
    pem = read(f"{HOMELAB}/ca/lan.crt")
    end = openssl_end(pem) if pem else None
    if not end:
        return None
    days = (end - NOW).days
    if days < 15:
        alerts.append(("aviso", f"Certificado da LAN vence em {days} dias (sudo homelab-ca.sh renew)"))
    return {"end": end.astimezone().strftime("%d/%m/%Y"), "days": days}

# ------------------------------------------------------------------- atalhos
def links():
    L = []
    def on(k): return mon.get(k, "true") == "true"
    panels = [("DOZZLE", "Logs", "Dozzle — logs dos containers ao vivo", "9443"),
              ("GOACCESS", "Tráfego", "GoAccess — requisições por rota", "9444"),
              ("UPTIME_KUMA", "Status", "Uptime Kuma — disponibilidade e alertas", "9445"),
              ("SEQ", "Seq", "Logs estruturados das apps .NET", "9446")]
    for key, name, desc, port in panels:
        if on(key):
            L.append({"group": "Painéis", "name": name, "desc": desc, "scheme": "https", "port": mon.get(f"{key}_PORT", port)})
    for ep in proxyconf.get("PROXY_ENTRYPOINTS", "").split():
        n, _, p = ep.partition("=")
        if p and not n.startswith("painel"):
            L.append({"group": "Projetos (LAN)", "name": n, "desc": f"entrypoint {n}", "scheme": "https", "port": p})
    L.append({"group": "Projetos (LAN)", "name": "443", "desc": "rotas na porta padrão", "scheme": "https", "port": "443"})
    for key, name, desc, dflt in (("ADMINER_PORT", "Adminer", "MySQL (servidor: mysql)", "8088"),
                                  ("REDISINSIGHT_PORT", "RedisInsight", "Redis", "5540"),
                                  ("RABBITMQ_UI_PORT", "RabbitMQ", "Filas e conexões", "15672")):
        L.append({"group": "Infraestrutura", "name": name, "desc": desc, "scheme": "http", "port": infra.get(key, dflt)})
    return L

t0 = time.time()
with ThreadPoolExecutor(4) as ex:
    f_cont = ex.submit(containers); f_certs = ex.submit(acme_certs); f_traffic = ex.submit(traffic)
    host = host_info()
    cont = f_cont.result(); certs = f_certs.result(); traf = f_traffic.result()
proxy_c = next((c for c in cont if c["name"] == "traefik"), None)
if not proxy_c or proxy_c["status"] != "running":
    alerts.insert(0, ("erro", "Proxy (traefik) fora do ar — nenhum site responde"))
elif proxy_c["health"] == "unhealthy":
    alerts.insert(0, ("erro", "Proxy (traefik) unhealthy"))
domains = public_domains(certs)
bk = backup()
lan = lan_cert()
status = {
    "generated": NOW.isoformat(timespec="seconds"), "host": host, "alerts": [{"level": l, "text": t} for l, t in alerts],
    "containers": cont, "domains": domains, "traffic": traf, "backup": bk, "lan_cert": lan, "links": links(),
    "elapsed_ms": round((time.time() - t0) * 1000),
}

# --------------------------------------------------------------------- HTML
# Uma página de operação: a faixa de estado no topo responde "está tudo bem?"; o resto,
# em ordem de urgência, mostra o quê e onde. Tipografia IBM Plex (com fallback do sistema).
esc = lambda s: html.escape(str(s if s is not None else ""))
LV_TEXT = {"ok": "ok", "aviso": "atenção", "erro": "problema", "parado": "parado"}

def pill(level, text):
    return f'<span class="pill {esc(level)}">{esc(text)}</span>'

def meter(pct, warn=80, err=90):
    cls = "erro" if pct >= err else "aviso" if pct >= warn else "ok"
    return f'<span class="meter" role="img" aria-label="{pct}%"><i class="{cls}" style="width:{min(max(pct,0),100)}%"></i></span>'

def plural(n, um, varios):
    return f"{n} {um if n == 1 else varios}"

errs = [t for l, t in alerts if l == "erro"]; warns = [t for l, t in alerts if l == "aviso"]
overall = "erro" if errs else "aviso" if warns else "ok"
running = [c for c in cont if c["status"] == "running"]
headline = {
    "ok": "Tudo funcionando",
    "aviso": plural(len(warns), "ponto pede atenção", "pontos pedem atenção"),
    "erro": plural(len(errs), "problema precisa de ação", "problemas precisam de ação"),
}[overall]
summary = [plural(len(running), "container rodando", "containers rodando")]
if domains:
    up = sum(1 for d in domains if not d.get("proxy") and d["code"] != "000" and not d["code"].startswith("5"))
    summary.append(f"{up} de {plural(len(domains), 'domínio público respondendo', 'domínios públicos respondendo')}")
last = bk.get("last")
if last:
    summary.append(f"backup {'ok' if last.get('ok') else 'com falha'} {bk['when']}")

# rack: um quadradinho por container, agrupados por projeto
projects = {}
for c in cont:
    projects.setdefault(c["project"], []).append(c)
rack = "".join(
    '<span class="rack-group">' + "".join(
        f'<i class="led {esc(c["level"])}" title="{esc(c["name"])}: {esc(c["status"])}"></i>' for c in cs) + "</span>"
    for cs in projects.values())

P = []
P.append(f"""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="60">
<meta name="color-scheme" content="light dark">
<title>{esc(hostname)} — {esc(headline)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Condensed:wght@500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<style>
:root{{
  --bg:#eef1f4; --surface:#ffffff; --ink:#18212b; --muted:#5b6877; --line:#d5dce3; --accent:#2f5da8;
  --ok:#1e7f5c; --ok-bg:#e2f1ea; --warn:#9a6200; --warn-bg:#fbefd9; --err:#b4322b; --err-bg:#fbe6e4; --off:#9aa6b2;
  --sans:"IBM Plex Sans",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
  --cond:"IBM Plex Sans Condensed","IBM Plex Sans",system-ui,sans-serif;
}}
@media (prefers-color-scheme:dark){{:root{{
  --bg:#10161d; --surface:#18202a; --ink:#e3e8ee; --muted:#8d9aa9; --line:#273342; --accent:#8fb0f2;
  --ok:#4cc391; --ok-bg:#132a21; --warn:#e8ad45; --warn-bg:#2e2412; --err:#f2786e; --err-bg:#341a1b; --off:#5d6b7a;
}}}}
*{{box-sizing:border-box}}
html{{-webkit-text-size-adjust:100%}}
body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 var(--sans);font-variant-numeric:tabular-nums}}
a{{color:var(--accent);text-decoration-thickness:1px;text-underline-offset:2px}}
a:focus-visible,summary:focus-visible{{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}}
.wrap{{max-width:1180px;margin:0 auto;padding:0 20px}}
.muted{{color:var(--muted)}}

/* faixa de estado */
.band{{border-bottom:1px solid var(--line)}}
.band.ok{{background:var(--ok-bg)}} .band.aviso{{background:var(--warn-bg)}} .band.erro{{background:var(--err-bg)}}
.band .wrap{{padding-top:20px;padding-bottom:22px}}
.host{{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;font-size:14px;color:var(--muted)}}
.host b{{color:var(--ink);font-weight:600}}
.state{{display:flex;align-items:center;gap:14px;margin:14px 0 6px}}
.state .dot{{width:14px;height:14px;border-radius:50%;flex:none}}
.band.ok .dot{{background:var(--ok)}} .band.aviso .dot{{background:var(--warn)}} .band.erro .dot{{background:var(--err)}}
h1{{font:600 clamp(28px,4.2vw,40px)/1.1 var(--cond);margin:0;letter-spacing:-.01em}}
.summary{{margin:0 0 0 28px;color:var(--muted)}}
.rack{{display:flex;flex-wrap:wrap;gap:4px 10px;margin:16px 0 0 28px}}
.rack-group{{display:flex;gap:3px}}
.led{{width:9px;height:16px;border-radius:2px;background:var(--ok)}}
.led.aviso{{background:var(--warn)}} .led.erro{{background:var(--err)}} .led.parado{{background:var(--off);opacity:.6}}
.issues{{list-style:none;margin:18px 0 0 28px;padding:0;display:grid;gap:6px;max-width:80ch}}
.issues li{{padding-left:14px;border-left:3px solid var(--err)}}
.issues li.aviso{{border-left-color:var(--warn)}}

/* atalhos */
nav.tools{{border-bottom:1px solid var(--line);background:var(--surface)}}
nav.tools .wrap{{display:flex;flex-wrap:wrap;align-items:center;gap:8px 22px;padding-top:10px;padding-bottom:10px}}
.tool-group{{display:flex;flex-wrap:wrap;align-items:center;gap:4px}}
.tool-group span{{font-size:13px;color:var(--muted);margin-right:6px}}
.tool{{display:inline-block;padding:4px 10px;border-radius:6px;font-weight:500;text-decoration:none;color:var(--ink)}}
.tool:hover{{background:var(--bg);color:var(--accent)}}
.tool small{{color:var(--muted);font-weight:400;margin-left:4px}}

/* corpo */
main.wrap{{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:28px;padding-top:26px;padding-bottom:40px}}
@media (max-width:900px){{main.wrap{{grid-template-columns:minmax(0,1fr)}}}}
section{{margin-bottom:30px}}
h2{{font:600 19px/1.3 var(--cond);margin:0 0 10px;display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 10px}}
h2 .muted{{font:400 14px var(--sans)}}
.panel{{background:var(--surface);border:1px solid var(--line);border-radius:8px}}

/* linhas (containers, domínios, tráfego) */
.rows{{display:grid}}
.row{{display:grid;align-items:center;gap:4px 14px;padding:9px 14px;border-top:1px solid var(--line)}}
.row:first-child{{border-top:0}}
.row.head{{font-size:13px;color:var(--muted);padding-top:7px;padding-bottom:7px}}
.num{{text-align:right}}
.cont{{grid-template-columns:12px minmax(0,1.2fr) minmax(0,1.7fr) 62px 82px 92px}}
.proj{{display:flex;align-items:baseline;gap:10px;padding:10px 14px;border-top:1px solid var(--line);background:var(--bg)}}
.proj:first-child{{border-top:0;border-radius:8px 8px 0 0}}
.proj b{{font-weight:600}}
.cdot{{width:10px;height:10px;border-radius:50%;background:var(--ok)}}
.cdot.aviso{{background:var(--warn)}} .cdot.erro{{background:var(--err)}} .cdot.parado{{background:var(--off)}}
.name{{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:500}}
.dom{{grid-template-columns:minmax(0,1fr) 120px 70px 150px}}
.traf{{grid-template-columns:minmax(0,1fr) 150px 56px 56px 64px}}
.bar{{display:block;height:8px;border-radius:4px;background:var(--bg);overflow:hidden}}
.bar i{{display:block;height:100%;background:var(--accent);opacity:.75}}
.pill{{display:inline-block;padding:1px 8px;border-radius:5px;font-size:13px;font-weight:500;white-space:nowrap}}
.pill.ok{{background:var(--ok-bg);color:var(--ok)}} .pill.aviso{{background:var(--warn-bg);color:var(--warn)}}
.pill.erro{{background:var(--err-bg);color:var(--err)}} .pill.parado{{background:var(--bg);color:var(--muted)}}
.sub{{display:block;font-size:13px;color:var(--muted);font-weight:400;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.err{{color:var(--err);font-weight:600}}
@media (max-width:640px){{
  .cont{{grid-template-columns:12px minmax(0,1fr) auto}} .cont .opt{{display:none}}
  .dom{{grid-template-columns:minmax(0,1fr) auto}} .dom .opt{{display:none}}
  .traf{{grid-template-columns:minmax(0,1fr) auto auto}} .traf .opt{{display:none}}
}}

/* lateral */
dl.facts{{display:grid;grid-template-columns:auto minmax(0,1fr);gap:10px 16px;margin:0;padding:14px}}
dl.facts dt{{color:var(--muted)}} dl.facts dd{{margin:0;min-width:0}}
.meter{{display:block;height:6px;border-radius:3px;background:var(--bg);overflow:hidden;margin-top:5px}}
.meter i{{display:block;height:100%;background:var(--ok)}}
.meter i.aviso{{background:var(--warn)}} .meter i.erro{{background:var(--err)}}
details{{border-top:1px solid var(--line);padding:10px 14px}}
summary{{cursor:pointer;color:var(--accent)}}
pre{{margin:10px 0 0;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;word-break:break-word;max-height:300px;overflow:auto;color:var(--muted)}}
.empty{{padding:14px;color:var(--muted)}}
footer{{padding:0 20px 28px;text-align:center;font-size:13px;color:var(--muted)}}
@media (prefers-reduced-motion:no-preference){{.band.erro .dot{{animation:pulse 2s ease-in-out infinite}}}}
@keyframes pulse{{50%{{box-shadow:0 0 0 6px color-mix(in srgb,var(--err) 20%,transparent)}}}}
</style></head><body>""")

# ---- faixa de estado
issues = "".join(f'<li class="{l}">{esc(t)}</li>' for l, t in sorted(alerts, key=lambda a: a[0] != "erro"))
P.append(f"""<header class="band {overall}"><div class="wrap">
<div class="host"><span><b>{esc(hostname)}</b> ligado há {esc(host.get('uptime'))}</span>
<span>Atualizado às {NOW.strftime('%H:%M')} de {NOW.strftime('%d/%m')}, a cada minuto</span></div>
<div class="state"><span class="dot" aria-hidden="true"></span><h1>{esc(headline)}</h1></div>
<p class="summary">{esc(', '.join(summary))}.</p>
<div class="rack" aria-label="Containers por projeto">{rack}</div>
{f'<ul class="issues">{issues}</ul>' if issues else ''}
</div></header>""")

# ---- atalhos (endereço montado no navegador: nome .local, IP ou Tailscale)
groups = {}
for l in status["links"]:
    groups.setdefault(l["group"], []).append(l)
P.append('<nav class="tools" aria-label="Atalhos"><div class="wrap">')
for g, items in groups.items():
    P.append(f'<div class="tool-group"><span>{esc(g)}</span>')
    for l in items:
        P.append(f'<a class="tool lk" data-scheme="{esc(l["scheme"])}" data-port="{esc(l["port"])}" href="#" title="{esc(l["desc"])}">'
                 f'{esc(l["name"])}<small>:{esc(l["port"])}</small></a>')
    P.append("</div>")
P.append("</div></nav>")

P.append('<main class="wrap"><div>')

# ---- projetos e containers (problemas primeiro)
order = sorted(projects.items(), key=lambda kv: (not any(c["level"] == "erro" for c in kv[1]), kv[0] == "(sem projeto)", kv[0]))
P.append(f'<section><h2>Projetos <span class="muted">{plural(len(cont), "container", "containers")}</span></h2><div class="panel">')
for proj, cs in order:
    bad = sum(1 for c in cs if c["level"] == "erro")
    stopped = sum(1 for c in cs if c["level"] == "parado")
    note = (pill("erro", plural(bad, "com problema", "com problema")) if bad else "") + \
           (f' <span class="muted">{stopped} parado{"s" if stopped > 1 else ""}</span>' if stopped else "")
    P.append(f'<div class="proj"><b>{esc(proj)}</b> <span class="muted">{len(cs)}</span> {note}</div><div class="rows">')
    for c in cs:
        state = {"running": "rodando", "exited": "parado", "restarting": "reiniciando", "created": "criado",
                 "paused": "pausado", "dead": "morto"}.get(c["status"], c["status"])
        if c["health"]:
            state += {"healthy": ", saudável", "unhealthy": ", com falha no healthcheck", "starting": ", iniciando"}.get(c["health"], f", {c['health']}")
        if c["status"] == "exited" and c["exit"] not in (0, None):
            state += f" (código {c['exit']})"
        if c["restarts"]:
            state += f", {c['restarts']} reinício{'s' if c['restarts'] > 1 else ''}"
        sub = c["service"] if c["service"] and c["service"] != c["name"] else ""
        P.append(f'<div class="row cont"><span class="cdot {esc(c["level"])}" aria-label="{LV_TEXT.get(c["level"], "")}"></span>'
                 f'<span class="name" title="{esc(c["image"])}">{esc(c["name"])}</span>'
                 f'<span class="{"err" if c["level"] == "erro" else "muted"}">{esc(state)}</span>'
                 f'<span class="num opt">{esc(c["cpu"])}</span><span class="num opt">{esc(c["mem"])}</span>'
                 f'<span class="num opt muted">{esc(c["since"])}</span></div>')
    P.append("</div>")
P.append("</div></section>")

# ---- domínios públicos
if domains:
    P.append(f'<section><h2>Domínios públicos <span class="muted">teste local pelo proxy</span></h2><div class="panel rows">'
             '<div class="row dom head"><span>Domínio</span><span>Resposta</span><span class="num opt">Tempo</span><span class="opt">Certificado</span></div>')
    for d in domains:
        resp_lv = "erro" if d.get("proxy") or d["code"] == "000" or d["code"].startswith("5") else "ok"
        resp = "sem resposta" if d["code"] == "000" else f'HTTP {d["code"]}'
        days = d["cert_days"]
        cert = (pill("erro", "sem Let's Encrypt") if days is None else
                pill("ok" if days >= 15 else "aviso" if days >= 7 else "erro", f"{days} dias"))
        origin = f'{d["project"]}/{d["service"]}' if d["service"] else ""
        P.append(f'<div class="row dom"><span class="name"><a href="https://{esc(d["domain"])}" target="_blank" rel="noopener">{esc(d["domain"])}</a>'
                 f'<span class="sub">{esc(d.get("proxy") or origin)}</span></span>'
                 f'<span>{pill(resp_lv, resp)}</span><span class="num opt muted">{d["ms"]} ms</span><span class="opt">{cert}</span></div>')
    P.append("</div></section>")

# ---- tráfego
tt = traf["total"]
P.append(f'<section><h2>Tráfego <span class="muted">últimas 24 h, {plural(tt["req"], "requisição", "requisições")}</span></h2><div class="panel rows">')
if traf["routers"]:
    top = max(r["req"] for r in traf["routers"]) or 1
    P.append('<div class="row traf head"><span>Rota</span><span class="opt">Volume</span><span class="num">4xx</span><span class="num">5xx</span><span class="num opt">Média</span></div>')
    for r in traf["routers"]:
        P.append(f'<div class="row traf"><span class="name">{esc(r["router"].removesuffix("@docker"))}'
                 f'<span class="sub">{r["req"]} req., última {esc(r["last"])}</span></span>'
                 f'<span class="opt"><span class="bar"><i style="width:{max(2, round(100 * r["req"] / top))}%"></i></span></span>'
                 f'<span class="num">{r["c4"]}</span><span class="num{" err" if r["c5"] else ""}">{r["c5"]}</span>'
                 f'<span class="num opt muted">{r["avg_ms"]} ms</span></div>')
else:
    P.append('<p class="empty">Nenhuma requisição registrada. O log de acesso do proxy está ligado? (ACCESS_LOG no proxy.conf)</p>')
P.append("</div></section></div>")

# ---- lateral: servidor, backup, certificados
P.append("<aside>")
h = host
facts = [("Carga", f'{esc(" / ".join(h.get("load", [])))} <span class="muted">em {h.get("cpus")} CPUs</span>')]
if h.get("mem"):
    m = h["mem"]; facts.append(("Memória", f'{human(m["used"])} de {human(m["total"])}{meter(m["pct"])}'))
for d in h.get("disks", []):
    facts.append((esc(d["label"]), f'{human(d["free"])} livres de {human(d["total"])}{meter(d["pct"])}'))
if h.get("battery"):
    bt = h["battery"]
    facts.append(("Bateria", f'{bt["pct"]}%, ' + ("na tomada" if bt.get("ac", True) else '<span class="err">sem tomada</span>')))
if h.get("temp"):
    facts.append(("Temperatura", f'{h["temp"]} °C'))
P.append('<section><h2>Servidor</h2><div class="panel"><dl class="facts">' +
         "".join(f"<dt>{k}</dt><dd>{v}</dd>" for k, v in facts) + "</dl></div></section>")

facts = []
if last:
    facts.append(("Último", f'{pill("ok" if last.get("ok") else "erro", "concluído" if last.get("ok") else "falhou")} {esc(bk["when"])}'))
    facts.append(("Resultado", esc(last.get("message"))))
    facts.append(("Duração", f'{esc(last.get("duration_s"))} s'))
else:
    facts.append(("Último", pill("aviso", "sem registro")))
if bk.get("next"):
    facts.append(("Próximo", esc(bk["next"])))
ext = bk.get("external")
if ext is None:
    facts.append(("Disco externo", '<span class="muted">não configurado</span>'))
else:
    facts.append(("Disco externo", pill("ok", "conectado") if ext["mounted"] else pill("erro", "desconectado")))
P.append('<section><h2>Backup</h2><div class="panel"><dl class="facts">' +
         "".join(f"<dt>{k}</dt><dd>{v}</dd>" for k, v in facts) + "</dl>")
if bk.get("log"):
    P.append("<details><summary>Log do último backup</summary><pre>" + esc("\n".join(bk["log"])) + "</pre></details>")
P.append("</div></section>")

if lan:
    lv = "ok" if lan["days"] >= 15 else "aviso"
    P.append(f'<section><h2>Certificado da LAN</h2><div class="panel"><dl class="facts"><dt>Vence em</dt>'
             f'<dd>{pill(lv, str(lan["days"]) + " dias")} <span class="muted">{esc(lan["end"])}</span></dd></dl></div></section>')
P.append("</aside></main>")

P.append(f"""<footer>Página gerada em {status['elapsed_ms']} ms pelo painel.sh. Dados em <a href="status.json">status.json</a>.</footer>
<script>for(const a of document.querySelectorAll('a.lk')){{const s=a.dataset.scheme,p=a.dataset.port;
a.href=s+'://'+location.hostname+((s==='https'&&p==='443')||(s==='http'&&p==='80')?'':':'+p)+'/';a.target='_blank';a.rel='noopener'}}</script>
</body></html>""")

def write(name, content, mode=0o644):
    tmp = os.path.join(OUT, f".{name}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(tmp, mode); os.replace(tmp, os.path.join(OUT, name))

write("index.html", "".join(P))
write("status.json", json.dumps(status, ensure_ascii=False, indent=1, default=str))
PY
