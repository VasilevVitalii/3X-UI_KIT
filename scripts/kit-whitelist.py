#!/usr/bin/env python3
"""Белый список на сервере: через VPN выходит только то, что перечислено в rules.yaml.

https://github.com/VasilevVitalii/3X-UI_KIT (форк itsnotkubrick/3X-UI_KIT)

Берёт тот же /etc/kit-sub/rules.yaml, что и подписка, раскрывает категории GEOSITE по той же
базе, что у приложений на Mihomo (MetaCubeX geosite.dat), и записывает в маршрутизацию Xray
(шаблон 3X-UI) правила с ruleTag «kit-wl-*»: перечисленное – в direct, остальное с
пользовательских подключений – в blocked. Если Xray после записи не запустился – откат.

  kit_whitelist.py on      включить и применить
  kit_whitelist.py sync    применить заново, если включён (после правки rules.yaml)
  kit_whitelist.py off     убрать правила
  kit_whitelist.py status  включён ли, сколько правил
  kit_whitelist.py test домен|IP   куда сервер отправит такое соединение
"""

import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

import yaml

RULES_FILE = os.environ.get("KIT_SUB_RULES") or "/etc/kit-sub/rules.yaml"
XUI_ENV = "/etc/x-ui/install-result.env"
STATE = "/etc/kit/whitelist.on"
GEOSITE = "/usr/local/share/kit/geosite.dat"
GEOSITE_URL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
GEOSITE_MAX_AGE = 7 * 86400
TAG = "kit-wl"
RULE_RE = re.compile(r"^[A-Z][A-Z0-9-]*,[^,\s]+(,no-resolve)?$")
DOMAIN_PREFIX = {0: "keyword:", 1: "regexp:", 2: "domain:", 3: "full:"}  # тип Domain в geosite.dat
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE  # панель на 127.0.0.1 с сертификатом на IP


def say(msg):
    print(f"==> {msg}", flush=True)


def die(msg):
    print(f"✗  {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


# ---------- панель ----------

def panel():
    out = subprocess.run(["bash", "-c", f'. {XUI_ENV} && printf "%s\\n%s\\n%s\\n" '
                          '"$XUI_PANEL_PORT" "$XUI_WEB_BASE_PATH" "$XUI_API_TOKEN"'],
                         capture_output=True, text=True)
    if out.returncode:
        die(f"Не прочитать {XUI_ENV} – сервер ставили скриптом 3x-ui.sh?")
    port, base, token = out.stdout.splitlines()[:3]
    for scheme in ("https", "http"):
        api = f"{scheme}://127.0.0.1:{port}/{base.strip('/')}/panel/api"
        try:
            call(api, token, "GET", "server/status")
            return api, token
        except Exception:
            continue
    die("Панель 3X-UI не отвечает на 127.0.0.1.")


def call(api, token, method, path, form=None):
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    req = urllib.request.Request(f"{api}/{path}", data=data, method=method,
                                 headers={"Authorization": f"Bearer {token}"})
    if data is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=60, context=CTX) as r:
        body = json.load(r)
    if not body.get("success"):
        raise RuntimeError(body.get("msg") or "панель ответила ошибкой")
    obj = body.get("obj")
    return json.loads(obj) if isinstance(obj, str) and obj[:1] in "{[" else obj


def get_template(api, token):
    obj = call(api, token, "POST", "xray/", {})
    tpl = obj.get("xraySetting")
    if isinstance(tpl, str):
        tpl = json.loads(tpl)
    return tpl, obj.get("outboundTestUrl") or ""


def save_template(api, token, tpl, test_url):
    call(api, token, "POST", "xray/update",
         {"xraySetting": json.dumps(tpl, ensure_ascii=False), "outboundTestUrl": test_url})


def xray_state(api, token):
    st = call(api, token, "GET", "server/status") or {}
    x = st.get("xray") or {}
    return x.get("state"), x.get("errorMsg")


def user_inbound_tags(api, token):
    tags = []
    for ib in call(api, token, "GET", "inbounds/list") or []:
        if ib.get("enable") and ib.get("tag"):
            tags.append(ib["tag"])
    return tags


# ---------- geosite.dat (protobuf без зависимостей) ----------

def _varint(b, i):
    shift = res = 0
    while True:
        c = b[i]
        i += 1
        res |= (c & 0x7F) << shift
        shift += 7
        if c < 0x80:
            return res, i


def _fields(b):
    i = 0
    while i < len(b):
        key, i = _varint(b, i)
        num, wt = key >> 3, key & 7
        if wt == 2:
            n, i = _varint(b, i)
            yield num, b[i:i + n]
            i += n
        elif wt == 0:
            v, i = _varint(b, i)
            yield num, v
        elif wt == 5:
            yield num, b[i:i + 4]
            i += 4
        elif wt == 1:
            yield num, b[i:i + 8]
            i += 8
        else:
            raise ValueError(f"geosite.dat: неизвестный тип поля {wt}")


def load_geosite(force=False):
    fresh = os.path.exists(GEOSITE) and time.time() - os.path.getmtime(GEOSITE) < GEOSITE_MAX_AGE
    if force or not fresh:
        os.makedirs(os.path.dirname(GEOSITE), exist_ok=True)
        tmp = GEOSITE + ".new"
        try:
            urllib.request.urlretrieve(GEOSITE_URL, tmp)
            if os.path.getsize(tmp) < 100_000:
                raise ValueError("файл слишком маленький")
            os.replace(tmp, GEOSITE)
            say("База категорий geosite.dat обновлена")
        except Exception as e:
            if os.path.exists(tmp):
                os.remove(tmp)
            if not os.path.exists(GEOSITE):
                die(f"Не удалось скачать geosite.dat ({e}).")
            print(f"!  geosite.dat не обновился ({e}) – беру прежний", file=sys.stderr)
    data = open(GEOSITE, "rb").read()
    cats = {}
    for _, entry in _fields(data):
        code, doms = None, []
        for f, v in _fields(entry):
            if f == 1:
                code = v.decode()
            elif f == 2:
                t, val = 0, ""
                for f3, v3 in _fields(v):
                    if f3 == 1:
                        t = v3
                    elif f3 == 2:
                        val = v3.decode("utf-8", "replace")
                if val and t in DOMAIN_PREFIX:
                    doms.append(DOMAIN_PREFIX[t] + val)
        if code:
            cats[code.lower()] = doms
    return cats


# ---------- правила ----------

def read_rules():
    try:
        with open(RULES_FILE, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except FileNotFoundError:
        die(f"Нет {RULES_FILE} – белому списку не из чего строиться.")
    items = data.get("via_vpn") if isinstance(data, dict) else None
    if not isinstance(items, list) or not items:
        die(f"В {RULES_FILE} нет списка via_vpn.")
    out = []
    for item in items:
        r = re.sub(r"\s*,\s*", ",", str(item).strip())
        if RULE_RE.match(r):
            out.append(r.split(",")[:2])
        else:
            print(f"!  пропускаю непонятное правило {item!r}", file=sys.stderr)
    return out


def build(rules, cats, tags):
    domains, ips, skipped = [], [], []
    for kind, value in rules:
        if kind == "GEOSITE":
            cat = cats.get(value.lower())
            if cat is None:
                skipped.append(f"GEOSITE,{value} (нет такой категории)")
            else:
                domains += cat
        elif kind == "DOMAIN-SUFFIX":
            domains.append("domain:" + value)
        elif kind == "DOMAIN":
            domains.append("full:" + value)
        elif kind == "DOMAIN-KEYWORD":
            domains.append("keyword:" + value)
        elif kind in ("IP-CIDR", "IP-CIDR6"):
            ips.append(value)
        elif kind == "GEOIP" and re.fullmatch(r"[A-Za-z]{2}", value):
            ips.append("geoip:" + value.lower())
        else:
            skipped.append(f"{kind},{value} (на сервере такой тип не поддерживается)")
    domains = list(dict.fromkeys(domains))
    ips = list(dict.fromkeys(ips))
    out = []
    if domains:
        out.append({"type": "field", "ruleTag": f"{TAG}-domains", "domain": domains, "outboundTag": "direct"})
    if ips:
        out.append({"type": "field", "ruleTag": f"{TAG}-ips", "ip": ips, "outboundTag": "direct"})
    # DNS-запросы приложений через VPN (AmneziaWG) – иначе не откроется и разрешённое.
    out.append({"type": "field", "ruleTag": f"{TAG}-dns", "port": "53", "outboundTag": "direct"})
    out.append({"type": "field", "ruleTag": f"{TAG}-rest", "inboundTag": tags,
                "network": "tcp,udp", "outboundTag": "blocked"})
    return out, len(domains), len(ips), skipped


def strip_ours(tpl):
    routing = tpl.setdefault("routing", {})
    rules = routing.get("rules") or []
    routing["rules"] = [r for r in rules if not str(r.get("ruleTag", "")).startswith(TAG)]
    return len(rules) - len(routing["rules"])


def check_outbounds(tpl):
    have = {o.get("tag"): o.get("protocol") for o in tpl.get("outbounds") or []}
    if have.get("direct") != "freedom" or have.get("blocked") != "blackhole":
        die("В шаблоне Xray нет выходов direct (freedom) и blocked (blackhole) – "
            "проверьте раздел «Исходящие» в панели.")


def restart_xray(api, token):
    # Панель применяет шаблон только при перезапуске Xray – сам по себе xray/update ничего не меняет.
    call(api, token, "POST", "server/restartXrayService")


def apply(api, token, tpl, test_url, old):
    save_template(api, token, tpl, test_url)
    try:
        restart_xray(api, token)
    except RuntimeError:
        pass  # не запустился – увидим ниже по состоянию и откатим
    for _ in range(15):
        time.sleep(2)
        state, err = xray_state(api, token)
        if state == "running":
            return
        if state == "error":
            break
    print(f"✗  Xray не запустился с новыми правилами: {err or state}. Возвращаю прежние.", file=sys.stderr)
    save_template(api, token, old, test_url)
    restart_xray(api, token)
    sys.exit(1)


def route(api, token, tags, target):
    form = {"inboundTag": tags[0] if tags else "", "network": "tcp", "port": "443"}
    form["ip" if re.fullmatch(r"[0-9.:a-fA-F/]+", target) and any(c.isdigit() for c in target) else "domain"] = target
    res = call(api, token, "POST", "xray/routeTest", form) or {}
    return res.get("outboundTag") or "direct (правило не сработало – выход по умолчанию)"


# ---------- команды ----------

def cmd_on(sync=False):
    if sync and not os.path.exists(STATE):
        return
    api, token = panel()
    tpl, test_url = get_template(api, token)
    check_outbounds(tpl)
    old = json.loads(json.dumps(tpl))
    tags = user_inbound_tags(api, token)
    if not tags:
        die("В панели нет включённых подключений.")
    ours, nd, ni, skipped = build(read_rules(), load_geosite(), tags)
    strip_ours(tpl)
    tpl["routing"]["rules"] += ours
    for s in skipped:
        print(f"!  пропущено: {s}", file=sys.stderr)
    apply(api, token, tpl, test_url, old)
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    open(STATE, "w").close()
    install_units()
    say(f"Белый список включён: {nd} доменов, {ni} подсетей; остальное через VPN не выходит.")
    for probe in ("youtube.com", "ya.ru"):
        try:
            print(f"   {probe}: {route(api, token, tags, probe)}")
        except Exception as e:
            print(f"   {probe}: проверить не удалось ({e})")


def cmd_off():
    api, token = panel()
    tpl, test_url = get_template(api, token)
    old = json.loads(json.dumps(tpl))
    n = strip_ours(tpl)
    if n:
        apply(api, token, tpl, test_url, old)
    if os.path.exists(STATE):
        os.remove(STATE)
    subprocess.run(["systemctl", "disable", "--now", "kit-whitelist.path", "kit-whitelist.timer"],
                   capture_output=True)
    say("Белый список выключен: через VPN снова выходит всё." if n else "Белый список и так выключен.")


def cmd_status():
    api, token = panel()
    tpl, _ = get_template(api, token)
    ours = [r for r in (tpl.get("routing") or {}).get("rules") or [] if str(r.get("ruleTag", "")).startswith(TAG)]
    if not ours:
        print("Белый список выключен. Включить: kit whitelist on")
        return
    nd = sum(len(r.get("domain") or []) for r in ours)
    ni = sum(len(r.get("ip") or []) for r in ours)
    print(f"Белый список включён: {nd} доменов, {ni} подсетей. "
          f"Синхронизация с {RULES_FILE}: автоматически при правке и раз в неделю.")


def cmd_test(target):
    api, token = panel()
    print(f"{target}: {route(api, token, user_inbound_tags(api, token), target)}")


UNITS = {
    "kit-whitelist.service": """[Unit]
Description=kit: белый список Xray по /etc/kit-sub/rules.yaml
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/kit-sub/kit_whitelist.py sync
""",
    "kit-whitelist.path": """[Unit]
Description=kit: применять белый список при правке rules.yaml
[Path]
PathChanged=/etc/kit-sub/rules.yaml
[Install]
WantedBy=multi-user.target
""",
    "kit-whitelist.timer": """[Unit]
Description=kit: раз в неделю обновлять базу категорий белого списка
[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true
[Install]
WantedBy=timers.target
""",
}


def install_units():
    for name, body in UNITS.items():
        path = f"/etc/systemd/system/{name}"
        if not os.path.exists(path) or open(path).read() != body:
            with open(path, "w") as f:
                f.write(body)
    subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
    subprocess.run(["systemctl", "enable", "--now", "kit-whitelist.path", "kit-whitelist.timer"],
                   capture_output=True)


def main():
    if os.geteuid() != 0:
        die("Запустите от root.")
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if cmd == "on":
            cmd_on()
        elif cmd == "sync":
            cmd_on(sync=True)
        elif cmd == "off":
            cmd_off()
        elif cmd == "status":
            cmd_status()
        elif cmd == "test" and len(sys.argv) > 2:
            cmd_test(sys.argv[2])
        else:
            print(__doc__.split("\n\n", 2)[2])
    except (RuntimeError, OSError) as e:
        die(f"Панель ответила ошибкой: {e}")


if __name__ == "__main__":
    main()
