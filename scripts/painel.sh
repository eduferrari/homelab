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
        o = run(["curl", "--noproxy", "*", "-sk", "-o", "/dev/null", "-w", "%{http_code} %{time_total}", "-m", "8",
                 "--resolve", f"{d}:443:127.0.0.1", f"https://{d}/"], timeout=12) or "000 0"
        code, t = (o.split() + ["0"])[:2]
        return d, code, round(float(t) * 1000)
    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(check, doms))
    rows = []
    for d, code, ms in results:
        end = certs.get(d) or certs.get("*." + d.split(".", 1)[-1])
        days = (end - NOW).days if end else None
        level = "ok"
        if code == "000" or code.startswith("5"):
            level = "erro"; alerts.append(("erro", f"{d}: {'sem resposta' if code == '000' else 'HTTP ' + code}"))
        if days is None:
            level = "erro"; alerts.append(("erro", f"{d}: sem certificado Let's Encrypt"))
        elif days < 15:
            level = "erro" if days < 7 else ("aviso" if level == "ok" else level)
            alerts.append(("erro" if days < 7 else "aviso", f"Certificado de {d} vence em {days} dias"))
        rows.append({"domain": d, **doms[d], "code": code, "ms": ms, "cert_days": days,
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
esc = lambda s: html.escape(str(s if s is not None else ""))
def badge(level, text=None):
    return f'<span class="b {esc(level)}">{esc(text or level)}</span>'
def bar(pct):
    cls = "erro" if pct >= 90 else "aviso" if pct >= 80 else "ok"
    return f'<div class="bar"><i class="{cls}" style="width:{min(pct,100)}%"></i></div>'

errs = [a for a in alerts if a[0] == "erro"]; warns = [a for a in alerts if a[0] == "aviso"]
overall = "erro" if errs else "aviso" if warns else "ok"
P = []
P.append(f"""<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="60">
<title>{esc(hostname)} — painel</title><style>
:root{{--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--mut:#667085;--bd:#e4e7ec;--ok:#12805c;--okb:#e3f6ee;--av:#a15c00;--avb:#fff4e0;--er:#b42318;--erb:#fdecea;--ln:#2557d6}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0f1218;--card:#171b23;--fg:#e6e8ec;--mut:#98a2b3;--bd:#2a303c;--ok:#4cc38a;--okb:#11291f;--av:#f0b450;--avb:#2d2410;--er:#f97066;--erb:#33171a;--ln:#7aa2ff}}}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}}
header{{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:center;justify-content:space-between;padding:16px;max-width:1200px;margin:auto}}
h1{{font-size:20px;margin:0}}h2{{font-size:15px;margin:0 0 10px}}main{{max-width:1200px;margin:auto;padding:0 16px 32px;display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}}
section{{background:var(--card);border:1px solid var(--bd);border-radius:10px;padding:14px;min-width:0}}.wide{{grid-column:1/-1}}
.mut{{color:var(--mut)}}.b{{display:inline-block;padding:1px 8px;border-radius:99px;font-size:12px;font-weight:600;white-space:nowrap}}
.b.ok{{background:var(--okb);color:var(--ok)}}.b.aviso{{background:var(--avb);color:var(--av)}}.b.erro{{background:var(--erb);color:var(--er)}}.b.parado{{background:var(--bd);color:var(--mut)}}
table{{width:100%;border-collapse:collapse}}td,th{{text-align:left;padding:5px 6px;border-top:1px solid var(--bd);vertical-align:top}}th{{color:var(--mut);font-weight:500;font-size:12px;border-top:0}}
.scroll{{overflow-x:auto}}.num{{text-align:right;font-variant-numeric:tabular-nums}}tr.proj td{{background:var(--bg);font-weight:600}}
.bar{{height:6px;background:var(--bd);border-radius:3px;overflow:hidden;margin-top:3px}}.bar i{{display:block;height:100%}}.bar i.ok{{background:var(--ok)}}.bar i.aviso{{background:var(--av)}}.bar i.erro{{background:var(--er)}}
.kv{{display:grid;grid-template-columns:auto 1fr;gap:6px 14px}}.links{{display:grid;gap:8px;grid-template-columns:repeat(auto-fill,minmax(180px,1fr))}}
.links a{{display:block;padding:10px;border:1px solid var(--bd);border-radius:8px;text-decoration:none;color:var(--fg)}}.links a:hover{{border-color:var(--ln)}}.links b{{color:var(--ln)}}
.alert{{padding:6px 10px;border-radius:6px;margin:4px 0}}.alert.erro{{background:var(--erb);color:var(--er)}}.alert.aviso{{background:var(--avb);color:var(--av)}}
pre{{background:var(--bg);padding:8px;border-radius:6px;overflow:auto;font-size:12px;max-height:320px;margin:8px 0 0}}a{{color:var(--ln)}}
</style></head><body><header><div><h1>{esc(hostname)}</h1>
<div class="mut">Atualizado às {NOW.strftime('%H:%M:%S')} de {NOW.strftime('%d/%m/%Y')} · atualiza a cada minuto · <a href="status.json">status.json</a></div></div>
<div>{badge(overall, {"ok": "Tudo certo", "aviso": f"{len(warns)} aviso(s)", "erro": f"{len(errs)} problema(s)"}[overall])}</div></header><main>""")

# alertas
if alerts:
    P.append('<section class="wide"><h2>Atenção</h2>' + "".join(f'<div class="alert {l}">{esc(t)}</div>' for l, t in sorted(alerts, key=lambda a: a[0] != "erro")) + "</section>")

# atalhos (endereço montado no navegador: funciona pelo nome .local, pelo IP ou pelo Tailscale)
groups = defaultdict(list)
for l in status["links"]:
    groups[l["group"]].append(l)
P.append('<section class="wide"><h2>Atalhos</h2>')
for g, items in groups.items():
    P.append(f'<div class="mut" style="margin:6px 0 4px">{esc(g)}</div><div class="links">')
    for l in items:
        P.append(f'<a class="lk" data-scheme="{esc(l["scheme"])}" data-port="{esc(l["port"])}" href="#"><b>{esc(l["name"])}</b>'
                 f' <span class="mut">:{esc(l["port"])}</span><br><span class="mut">{esc(l["desc"])}</span></a>')
    P.append("</div>")
P.append("</section>")

# servidor
h = host
kv = [("Ligado há", esc(h.get("uptime"))),
      ("Carga", esc(" / ".join(h.get("load", []))) + f' <span class="mut">({h.get("cpus")} CPUs)</span>')]
if h.get("mem"):
    m = h["mem"]; kv.append(("Memória", f'{human(m["used"])} de {human(m["total"])} ({m["pct"]}%){bar(m["pct"])}'))
for d in h.get("disks", []):
    kv.append((esc(d["label"]), f'{human(d["total"] - d["free"])} de {human(d["total"])} ({d["pct"]}%) <span class="mut">{esc(d["path"])}</span>{bar(d["pct"])}'))
if h.get("battery"):
    bt = h["battery"]; kv.append(("Bateria", f'{bt["pct"]}% — {esc(bt["status"])}{"" if bt.get("ac", True) else " " + badge("erro", "sem tomada")}'))
if h.get("temp"):
    kv.append(("Temperatura", f'{h["temp"]} °C'))
P.append('<section><h2>Servidor</h2><div class="kv">' + "".join(f"<span class=mut>{k}</span><span>{v}</span>" for k, v in kv) + "</div></section>")

# backup
b = bk; last = b.get("last")
kv = []
if last:
    kv.append(("Último", f'{badge("ok" if last.get("ok") else "erro", "OK" if last.get("ok") else "falhou")} {esc(b["when"])}'
               f' <span class="mut">(levou {esc(last.get("duration_s"))} s)</span>'))
    kv.append(("Resultado", esc(last.get("message"))))
    if last.get("size") and last.get("size") != "-": kv.append(("Tamanho", esc(last["size"])))
else:
    kv.append(("Último", f'{badge("aviso", "sem registro")} {esc(b.get("latest") or "")}'))
if b.get("next"):
    kv.append(("Próximo", esc(b["next"])))
ext = b.get("external")
if ext is None:
    kv.append(("Disco externo", badge("parado", "não configurado")))
else:
    kv.append(("Disco externo", (badge("ok", "montado") + f' <span class="mut">último: {esc(ext.get("latest") or "-")}</span>') if ext["mounted"] else badge("erro", "não montado")))
P.append('<section><h2>Backup</h2><div class="kv">' + "".join(f"<span class=mut>{k}</span><span>{v}</span>" for k, v in kv) + "</div>")
if b.get("log"):
    P.append("<details><summary class=mut>Log do último backup</summary><pre>" + esc("\n".join(b["log"])) + "</pre></details>")
P.append("</section>")

# domínios
if domains:
    P.append('<section><h2>Domínios públicos</h2><div class="scroll"><table><tr><th>Domínio</th><th>HTTP</th><th class=num>Tempo</th><th>Certificado</th></tr>')
    for d in domains:
        lv = "erro" if d["code"] == "000" or d["code"].startswith("5") else "ok"
        cert = (f'{badge("ok" if d["cert_days"] >= 15 else "aviso" if d["cert_days"] >= 7 else "erro", str(d["cert_days"]) + " dias")}'
                if d["cert_days"] is not None else badge("erro", "sem Let's Encrypt"))
        P.append(f'<tr><td><a href="https://{esc(d["domain"])}" target="_blank" rel="noopener">{esc(d["domain"])}</a>'
                 f'<br><span class="mut">{esc(d["project"])}{"/" if d["service"] else ""}{esc(d["service"])}</span></td>'
                 f'<td>{badge(lv, d["code"])}</td><td class=num>{d["ms"]} ms</td><td>{cert}</td></tr>')
    P.append("</table></div>")
    if lan:
        P.append(f'<p class="mut">Certificado da LAN (CA do homelab): vence em {lan["days"]} dias ({esc(lan["end"])})</p>')
    P.append("</section>")
elif lan:
    P.append(f'<section><h2>Certificados</h2><p>LAN (CA do homelab): vence em {lan["days"]} dias ({esc(lan["end"])})</p></section>')

# tráfego
tt = traf["total"]
P.append(f'<section><h2>Tráfego — últimas 24 h</h2><p><b>{tt["req"]}</b> requisições · '
         f'{badge("aviso" if tt["c4"] else "ok", str(tt["c4"]) + " 4xx")} {badge("erro" if tt["c5"] else "ok", str(tt["c5"]) + " 5xx")}</p>')
if traf["routers"]:
    P.append('<div class="scroll"><table><tr><th>Rota</th><th class=num>Req.</th><th class=num>4xx</th><th class=num>5xx</th><th class=num>Média</th><th>Última</th></tr>')
    for r in traf["routers"]:
        P.append(f'<tr><td>{esc(r["router"].removesuffix("@docker"))}</td><td class=num>{r["req"]}</td><td class=num>{r["c4"]}</td>'
                 f'<td class=num>{"<b style=color:var(--er)>" + str(r["c5"]) + "</b>" if r["c5"] else 0}</td><td class=num>{r["avg_ms"]} ms</td><td class=mut style="white-space:nowrap">{esc(r["last"])}</td></tr>')
    P.append("</table></div>")
else:
    P.append('<p class="mut">Sem requisições registradas (log de acesso do proxy vazio ou desligado).</p>')
P.append("</section>")

# containers
P.append('<section class="wide"><h2>Containers</h2><div class="scroll"><table><tr><th>Container</th><th>Estado</th><th class=num>CPU</th><th class=num>Memória</th><th>Desde</th><th>Imagem</th></tr>')
cur = None
for c in cont:
    if c["project"] != cur:
        cur = c["project"]; n = [x for x in cont if x["project"] == cur]
        bad = sum(1 for x in n if x["level"] == "erro")
        P.append(f'<tr class=proj><td colspan=6>{esc(cur)} <span class="mut">({len(n)})</span> {badge("erro", str(bad) + " com problema") if bad else ""}</td></tr>')
    state = c["status"] + (f" · {c['health']}" if c["health"] else "") + (f" · código {c['exit']}" if c["status"] == "exited" else "")
    rst = f' <span class="mut">↻{c["restarts"]}</span>' if c["restarts"] else ""
    P.append(f'<tr><td>{esc(c["name"])}</td><td>{badge(c["level"], state)}{rst}</td><td class=num>{esc(c["cpu"])}</td>'
             f'<td class=num>{esc(c["mem"])}</td><td class=mut>{esc(c["since"])}</td><td class=mut>{esc(c["image"])}</td></tr>')
P.append("</table></div></section>")

P.append(f"""</main><footer class="mut" style="text-align:center;padding:0 16px 24px">Gerado em {status['elapsed_ms']} ms por painel.sh</footer>
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
