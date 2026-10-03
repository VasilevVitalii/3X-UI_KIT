#!/usr/bin/env bash
# kit – управление сервером 3X-UI KIT: пользователи, обновление, резервная копия.
# https://github.com/VasilevVitalii/3X-UI_KIT (форк itsnotkubrick/3X-UI_KIT)
#
#   kit user add имя [--gb 50] [--days 30] [--devices 3]
#   kit user list | link имя | limit имя [--gb N] [--days N] | off имя | on имя | del имя
#   kit update [--auto | --manual] | kit backup | kit version

set -Eeuo pipefail
export LC_ALL=C.UTF-8  # ширина колонок по символам, а не байтам

KIT_VERSION="1.1"
KIT_RAW="https://raw.githubusercontent.com/VasilevVitalii/3X-UI_KIT/main"
# Файлы новой версии берём из её тега (v1.2 и т.д.), а не из меняющейся ветки main.
kit_ref_raw() { echo "https://raw.githubusercontent.com/VasilevVitalii/3X-UI_KIT/v$1"; }

XUI_ENV=/etc/x-ui/install-result.env
KIT_ENV=/etc/kit/kit.env
KIT_LATEST=/etc/kit/latest-version

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { printf '%s\n' "${Y}!${N}  $*" >&2; }
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
[[ -f $XUI_ENV && -f $KIT_ENV ]] || die "Не найдена установка – сначала поставьте сервер скриптом 3x-ui.sh."
# shellcheck disable=SC1090
. "$XUI_ENV"; . "$KIT_ENV"

API=""
for scheme in https http; do
  API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$API/server/getNewUUID" 2>/dev/null && break
done

api() { # METHOD path [json]
  local out
  if [[ $1 == GET ]]; then
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" "$API/$2")
  else
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" -H 'Content-Type: application/json' -X "$1" -d "${3:-{\}}" "$API/$2")
  fi
  [[ $(jq -r '.success' <<<"$out" 2>/dev/null) == true ]] || die "Панель ответила ошибкой: $(jq -r '.msg // .' <<<"$out" 2>/dev/null | head -c 300)"
  jq -c '.obj' <<<"$out"
}

# В 3X-UI 3.x у клиента одна запись и в ней одна пара ключей WireGuard и один адрес. Если
# клиент подключён к двум AmneziaWG, в подписку для обоих уходят ключ и адрес одного из них,
# и второй сервер клиента не узнаёт (проверено 2026-09-27). Поэтому к первому AmneziaWG
# подключаем основную запись, а ко второму – запись-«двойник» «имя-awg» с подпиской «<id>-awg»
# (subId в 3X-UI обязан быть уникальным) и теми же лимитами; kit-sub подмешивает её в Clash.
awg_ids() { api GET inbounds/list | jq -r '[.[] | select(.protocol == "amneziawg") | .id] | sort | .[]'; }
non_awg_ids() { api GET inbounds/list | jq -c '[.[] | select(.protocol != "amneziawg") | .id]'; }
# flow для новых пользователей: xtls-rprx-vision, если есть VLESS REALITY поверх TCP. Во входы панель
# подставляет flow из записи клиента сама и только туда, где он применим (XHTTP, Hysteria2 – без него).
new_flow() {
  api GET inbounds/list | jq -r 'def obj: if type == "string" then fromjson else . end;
    if any(.[]; .protocol == "vless" and (.streamSettings | obj | .security == "reality" and (.network == "tcp" or .network == "raw")))
    then "xtls-rprx-vision" else "" end'
}

awg_attach() { # имя subId [лимит-байт] [срок-мс] [устройств]
  local name=$1 sid=$2 total=${3:-0} exp=${4:-0} lim=${5:-0} n=1 id email have
  have=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end')
  for id in $(awg_ids); do
    local esid=$sid
    if ((n == 1)); then email=$name
    elif ((n == 2)); then email="$name-awg"; esid="$sid-awg"
    else email="$name-awg$n"; esid="$sid-awg$n"; fi
    n=$((n + 1))
    if jq -e --arg e "$email" --argjson i "$id" 'any(.[]; .email == $e and ((.inboundIds // []) | index($i)))' <<<"$have" >/dev/null; then
      continue
    elif jq -e --arg e "$email" 'any(.[]; .email == $e)' <<<"$have" >/dev/null; then
      api POST "clients/$email/attach" "$(jq -nc --argjson i "$id" '{inboundIds: [$i]}')" >/dev/null
    else
      api POST clients/add "$(jq -nc --arg e "$email" --arg s "$esid" --argjson t "$total" --argjson x "$exp" --argjson l "$lim" --argjson i "$id" \
        '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x, limitIp: $l, enable: true, comment: "kit"}, inboundIds: [$i]}')" >/dev/null
    fi
  done
}

clients() { api GET clients/list | jq -c 'if type == "array" then . else .clients end'; }
client() { clients | jq -c --arg e "$1" 'map(select(.email == $e))[0] // empty'; }
# Все записи пользователя: основная и «двойники» для AmneziaWG («имя-awgN»).
emails_of() { clients | jq -r --arg e "$1" '.[] | select(.email == $e or (.email | test("^" + $e + "-awg[0-9]*$"))) | .email'; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя: латиница, цифры, _ . - (до 32 символов)."; }
rand_id() { openssl rand -base64 48 | tr -dc 'a-z0-9' | head -c 16; }

gb_bytes() { [[ $1 =~ ^[0-9]+$ ]] || die "--gb: целое число гигабайт"; echo $(($1 * 1073741824)); }
days_ms() { [[ $1 =~ ^[0-9]+$ ]] || die "--days: целое число дней"; ((${1} == 0)) && { echo 0; return; }; echo $((($(date +%s) + $1 * 86400) * 1000)); }

human() { # байты → «1.2 ГБ»
  awk -v b="$1" 'BEGIN { split("Б КБ МБ ГБ ТБ", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

sub_url() { echo "${SUB_BASE}$1"; }

show_link() { # имя subId
  local url
  url=$(sub_url "$2")
  echo
  echo "Подписка ${B}$1${N} – все протоколы одной ссылкой. Вставьте в Happ, Hiddify, Karing,"
  echo "v2rayN, Clash Verge или FlClash:"
  echo
  echo "$url"
  echo
  command -v qrencode >/dev/null && qrencode -t ANSIUTF8 -m 1 "$url"
  echo "${D}AmneziaVPN и Telegram: kit user link $1 --all – отдельные ссылки vpn:// и tg://${N}"
}

cmd_add() {
  local name=${1:-} gb=0 days=0 devices=0
  valid_name "$name"; shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) gb=$2; shift 2 ;;
      --days) days=$2; shift 2 ;;
      --devices) devices=$2; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  [[ -z $(client "$name") ]] || die "Пользователь $name уже есть. Ссылка: kit user link $name"
  local ids sid body
  ids=$(non_awg_ids)
  [[ $ids != "[]" ]] || die "На сервере нет подключений."
  sid=$(rand_id)
  body=$(jq -nc --arg e "$name" --arg s "$sid" --argjson t "$(gb_bytes "$gb")" --argjson x "$(days_ms "$days")" \
    --argjson ip "$devices" --argjson ids "$ids" --arg f "$(new_flow)" '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x,
    limitIp: $ip, enable: true, comment: "kit", flow: $f}, inboundIds: $ids}')
  api POST clients/add "$body" >/dev/null
  awg_attach "$name" "$sid" "$(gb_bytes "$gb")" "$(days_ms "$days")" "$devices"
  say "Пользователь $name добавлен во все протоколы ($(api GET inbounds/list | jq length))$( ((gb)) && echo ", лимит $gb ГБ")$( ((days)) && echo ", на $days дн")."
  show_link "$name" "$sid"
}

cmd_link() {
  local name=${1:-} all=${2:-} c
  valid_name "$name"
  c=$(client "$name"); [[ -n $c ]] || die "Нет пользователя $name"
  show_link "$name" "$(jq -r '.subId' <<<"$c")"
  if [[ $all == --all ]]; then
    local sid raw out="" suffix
    sid=$(jq -r '.subId' <<<"$c")
    for suffix in "" -awg; do
      raw=$(curl -fsSk -m 10 -A "v2rayN/7" -H "Host: $HOST" "http://127.0.0.1:$SUB_INTERNAL$SUB_PATH$sid$suffix" 2>/dev/null || true)
      grep -q '://' <<<"$raw" || raw=$(base64 -d <<<"$raw" 2>/dev/null || true)
      out+=$(grep -E '^(vpn|tg)://' <<<"$raw" || true)$'\n'
    done
    [[ ${SINGLE:-no} == yes ]] && out=$(sed "s/^\(tg:\/\/proxy?\)\(.*\)port=${MTPROTO_INNER:-10445}/\1\2port=443/" <<<"$out")
    echo; grep . <<<"$out" || echo "Отдельных ссылок нет."
  fi
}

cmd_list() {
  local now
  now=$(($(date +%s) * 1000))
  clients | jq -r --argjson now "$now" '
    map(select(.subId != null)) | group_by(.subId | sub("-awg[0-9]*$"; "")) | map(sort_by(.email | length) as $g | $g[0] + {used: ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add),
      seen: ([$g[] | .traffic.lastOnline // 0] | max)}) | sort_by(.email)[]
    | [.email, .used, (.totalGB // 0), (.expiryTime // 0), .enable, .seen] | @tsv' |
  {
    printf "${B}%-18s %-22s %-14s %-10s %s${N}\n" "Пользователь" "Трафик" "До" "Статус" "Был в сети"
    while IFS=$'\t' read -r email used total exp en last; do
      local tr till st seen
      tr="$(human "$used")"; ((total > 0)) && tr="$tr / $(human "$total")"
      if ((exp > 0)); then till=$(date -d "@$((exp / 1000))" +%d.%m.%Y); else till="бессрочно"; fi
      if [[ $en != true ]]; then st="${R}выключен${N}"
      elif ((exp > 0 && exp < $(date +%s) * 1000)); then st="${Y}истёк${N}"
      elif ((total > 0 && used >= total)); then st="${Y}лимит${N}"
      else st="${G}активен${N}"; fi
      if ((last > 0)); then seen=$(date -d "@$((last / 1000))" '+%d.%m %H:%M'); else seen="–"; fi
      printf "%-18s %-22s %-14s %-19s %s\n" "$email" "$tr" "$till" "$st" "$seen"
    done
  }
}

# Меняет все записи пользователя (основную и «двойников» AmneziaWG), каждую – от её собственных данных.
# flow передаём обязательно: запись без него панель сохраняет с пустым flow и стирает vision у REALITY.
update_user() { # имя jq-фильтр [аргументы jq...]
  local name=$1 filter=$2 e rec body
  shift 2
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c "$@" "{email, subId, totalGB, expiryTime, limitIp, enable, comment, flow: (.flow // \"\")} | $filter" <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
}

cmd_limit() {
  local name=${1:-} f="." gb="" days="" dev=""
  valid_name "$name"; shift
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) gb=$(gb_bytes "$2"); f+=" | .totalGB = \$gb"; shift 2 ;;
      --days) days=$(days_ms "$2"); f+=" | .expiryTime = \$days"; shift 2 ;;
      --devices) [[ $2 =~ ^[0-9]+$ ]] || die "--devices: целое число"; dev=$2; f+=" | .limitIp = \$dev"; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  update_user "$name" "$f" --argjson gb "${gb:-0}" --argjson days "${days:-0}" --argjson dev "${dev:-0}"
  say "Лимиты $name обновлены (0 – без ограничений)."
}

cmd_toggle() { # имя true|false
  valid_name "$1"
  [[ -n $(client "$1") ]] || die "Нет пользователя $1"
  update_user "$1" ".enable = \$v" --argjson v "$2"
  if [[ $2 == true ]]; then say "Пользователь $1 включён."; else say "Пользователь $1 выключен – подписка и подключения не работают."; fi
}

cmd_del() {
  local name=${1:-} ans=""
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  if [[ ${2:-} != -y && -t 0 ]]; then
    read -rp "Удалить $name со всех протоколов? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  local e
  for e in $(emails_of "$name"); do api POST "clients/del/$e" >/dev/null; done
  say "Пользователь $name удалён, его подписка больше не работает."
}

# ---------- версия и обновление ----------

# Открытый ключ, которым автор подписывает релизы (ssh-keygen -Y sign). Закрытая часть
# есть только у автора, поэтому подменить обновление, взломав один GitHub, не выйдет.
# Новый ключ приходит только в релизе, подписанном старым.
KIT_SIGNERS=(
  # SHA256:VDuGgJ8dOeCNXB4nBZf3+kRlWthw3+vh8rfMxzMSRIM (itsnotkubrick, 2026-09-30)
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGrTGCDhhnm8XO1ekpPJuSWRVCJiFiupEspfQxcbEBmz 3X-UI KIT releases"
)
KIT_SIG_NS="3x-ui-kit-release"
KIT_SIG_ID="releases@3x-ui-kit"
KIT_MANUAL=/etc/kit/manual-update
KIT_UPDATE_LOG=/var/log/kit-update.log

xray_version() {
  local b
  for b in /usr/local/x-ui/bin/xray-linux-*; do [[ -x $b ]] && "$b" version 2>/dev/null | awk 'NR==1 {print "v" $2}'; return; done
}
remote_version() { curl -fsS -m "${1:-5}" "$KIT_RAW/VERSION" 2>/dev/null | tr -d '[:space:]'; }
newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1) == "$1" ]]; }  # $1 новее $2?
auto_enabled() { systemctl is-enabled -q kit-update.timer 2>/dev/null; }

# Раз в сутки узнаём последнюю версию (не дольше 3 секунд) и подсказываем обновиться.
update_hint() {
  local latest=""
  if [[ ! -f $KIT_LATEST ]] || (($(date +%s) - $(stat -c %Y "$KIT_LATEST") > 86400)); then
    latest=$(remote_version 3) || true
    [[ $latest =~ ^[0-9]+(\.[0-9]+)+$ ]] && echo "$latest" >"$KIT_LATEST" || touch "$KIT_LATEST"
  fi
  latest=$(cat "$KIT_LATEST" 2>/dev/null || true)
  if [[ -n $latest ]] && newer "$latest" "$KIT_VERSION"; then
    echo
    if auto_enabled; then
      echo "${Y}↑ Вышла версия $latest${N} (у вас $KIT_VERSION). Встанет сама этой ночью или сейчас: ${B}kit update${N}"
    else
      echo "${Y}↑ Доступна версия $latest${N} (у вас $KIT_VERSION). Обновить: ${B}kit update${N}"
    fi
  fi
}

cmd_version() {
  echo "3X-UI KIT $KIT_VERSION"
  echo "${D}панель 3X-UI $(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo '?'), ядро Xray $(xray_version)${N}"
  if auto_enabled; then echo "${D}автообновление: включено (только подписанные релизы), журнал $KIT_UPDATE_LOG${N}"
  else echo "${D}автообновление: выключено, включить: kit update --auto${N}"; fi
  update_hint
}

# Что нового в версии $1 – из CHANGELOG.md, без разметки.
changelog_of() {
  curl -fsS -m 5 "$KIT_RAW/CHANGELOG.md" 2>/dev/null | awk -v v="## v$1" '
    index($0, v) == 1 { on = 1; t = substr($0, length(v) + 1); sub(/^[: ]+/, "", t); if (t != "") print t; next } on && /^## / { exit } on' | sed 's/\*\*//g; s/`//g' | grep -v '^[[:space:]]*$' | head -40 || true
}

# Скачивает релиз $1 в каталог $2 и проверяет: подпись SHA256SUMS нашим ключом, версию
# внутри подписанного файла и SHA256 каждого файла. Любое несовпадение – отказ.
fetch_release() { # версия каталог
  local v=$1 d=$2 raw f sum k
  ((${#KIT_SIGNERS[@]})) || { warn "В этой сборке kit нет ключа подписи – проверить обновление нечем."; return 1; }
  command -v ssh-keygen >/dev/null || { warn "Нет ssh-keygen (пакет openssh-client) – подпись не проверить."; return 1; }
  raw=$(kit_ref_raw "$v")
  curl -fsSL --retry 3 -o "$d/SHA256SUMS" "$raw/SHA256SUMS" && curl -fsSL --retry 3 -o "$d/SHA256SUMS.sig" "$raw/SHA256SUMS.sig" \
    || { warn "Не удалось скачать подпись релиза $v."; return 1; }
  : >"$d/allowed_signers"
  for k in "${KIT_SIGNERS[@]}"; do printf '%s namespaces="%s" %s\n' "$KIT_SIG_ID" "$KIT_SIG_NS" "$k" >>"$d/allowed_signers"; done
  if ! ssh-keygen -Y verify -f "$d/allowed_signers" -I "$KIT_SIG_ID" -n "$KIT_SIG_NS" -s "$d/SHA256SUMS.sig" <"$d/SHA256SUMS" >/dev/null 2>&1; then
    warn "Подпись релиза $v не сошлась с ключом автора – это не наш релиз. Ничего не ставлю."
    return 1
  fi
  # Версия записана внутри подписанного файла: старый подписанный релиз под видом нового не пройдёт.
  grep -qx "# 3X-UI KIT $v" "$d/SHA256SUMS" || { warn "Подписанный релиз не той версии – ничего не ставлю."; return 1; }
  for f in scripts/kit.sh scripts/kit-sub.py; do
    sum=$(awk -v f="$f" '$2 == f {print $1}' "$d/SHA256SUMS")
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || { warn "В подписанном списке нет $f."; return 1; }
    curl -fsSL --retry 3 -o "$d/${f##*/}" "$raw/$f" || { warn "Не удалось скачать $f."; return 1; }
    [[ $(sha256sum "$d/${f##*/}" | awk '{print $1}') == "$sum" ]] || { warn "$f не совпал с подписанным SHA256 – ничего не ставлю."; return 1; }
  done
}

# Юнит kit-sub: без root (DynamicUser), конфиг и сертификат – через LoadCredential.
# Сертификат Let's Encrypt на IP продлевается раз в несколько дней, поэтому при отдельном
# порте kit-sub перезапускается раз в сутки и берёт свежий.
kit_sub_unit() { # путь-к-сертификату путь-к-ключу (пусто – за nginx)
  cat <<UNIT
[Unit]
Description=kit-sub: подписка с учётом приложения (3X-UI KIT)
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/kit-sub/kit_sub.py
Restart=on-failure
RestartSec=5
DynamicUser=yes
LoadCredential=config.json:/etc/kit-sub/config.json
${1:+LoadCredential=cert.pem:$1}
${2:+LoadCredential=key.pem:$2}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=true
PrivateDevices=true
ProtectProc=invisible
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
MemoryMax=64M

[Install]
WantedBy=multi-user.target
UNIT
}

# Подписка отвечает? Берём настоящего пользователя и спрашиваем kit-sub изнутри сервера.
sub_ok() {
  local cfg=/etc/kit-sub/config.json port path scheme=http sid i
  port=$(jq -r '.port' "$cfg"); path=$(jq -r '.path' "$cfg")
  [[ -n $(jq -r '.cert // empty' "$cfg") ]] && scheme=https
  sid=$(clients 2>/dev/null | jq -r '[.[] | .subId // empty | select(. != "")][0] // empty' 2>/dev/null || true)
  for i in $(seq 1 10); do
    if [[ -n $sid ]]; then
      curl -fsSk -m 5 -o /dev/null -A "Happ/1.0" "$scheme://127.0.0.1:$port$path$sid" 2>/dev/null && return 0
    else
      # Пользователей нет – достаточно, что служба жива и слушает порт.
      systemctl is-active -q kit-sub && ss -Hltn "sport = :$port" | grep -q . && return 0
    fi
    sleep 1
  done
  return 1
}

# Сервер ещё не получил исправления 1.1 (например, kit обновили вручную из 1.0)?
needs_migration() {
  [[ -f /etc/cron.d/kit-xui-menu ]] && return 0
  [[ -f /etc/systemd/system/kit-sub.service ]] && ! grep -q '^DynamicUser=yes' /etc/systemd/system/kit-sub.service && return 0
  [[ ! -f $KIT_MANUAL ]] && ! auto_enabled && return 0
  return 1
}

# Автообновление: раз в сутки ночью со случайной задержкой, чтобы тысячи серверов не шли
# на GitHub в одну минуту. Ставит только подписанные релизы и только kit и kit-sub.
auto_on() {
  cat >/etc/systemd/system/kit-update.service <<UNIT
[Unit]
Description=3X-UI KIT: автообновление kit и kit-sub (только подписанные релизы)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kit update --unattended
StandardOutput=append:$KIT_UPDATE_LOG
StandardError=append:$KIT_UPDATE_LOG
UNIT
  cat >/etc/systemd/system/kit-update.timer <<'UNIT'
[Unit]
Description=3X-UI KIT: проверка обновлений раз в сутки

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  rm -f "$KIT_MANUAL"
  systemctl daemon-reload
  systemctl enable --now kit-update.timer >/dev/null 2>&1
}

auto_off() {
  systemctl disable --now kit-update.timer >/dev/null 2>&1 || true
  install -d -m 700 /etc/kit
  touch "$KIT_MANUAL"
}

cmd_update() {
  local force="" unattended=no latest tmp
  # Форк: подписанных релизов нет, а релиз автора затёр бы свои правила подписки.
  if [[ ${1:-} == --manual ]]; then auto_off; say "Автообновление выключено."; return; fi
  die "В форке kit update не используется. Обновиться из форка:
    cd /root/3X-UI_KIT && git pull
    install -m 755 scripts/kit.sh /usr/local/bin/kit
    install -m 644 scripts/kit-sub.py /usr/local/lib/kit-sub/kit_sub.py && systemctl restart kit-sub
    install -m 644 scripts/kit-whitelist.py /usr/local/lib/kit-sub/kit_whitelist.py && kit whitelist sync"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force) force=yes ;;
      --auto) auto_on; say "Автообновление включено: раз в сутки ночью, только подписанные релизы. Журнал: $KIT_UPDATE_LOG"; return ;;
      --manual) auto_off; say "Автообновление выключено. Обновляться вручную: kit update, включить снова: kit update --auto"; return ;;
      --unattended) unattended=yes ;;
      *) die "Неизвестный параметр: $1 (kit update [--force | --auto | --manual])" ;;
    esac
    shift
  done
  # Ночной запуск и ручной не должны встретиться.
  exec 9>/run/kit-update.lock
  flock -n 9 || die "Обновление уже идёт."
  [[ $unattended == yes ]] && echo "--- $(date '+%F %T') kit $KIT_VERSION: проверяю обновления"

  latest=$(remote_version) || true
  [[ $latest =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "Не удалось узнать последнюю версию: GitHub недоступен с сервера. Попробуйте позже."
  echo "$latest" >"$KIT_LATEST"
  # Откатить на старую версию нельзя даже с подписью: только вперёд или та же.
  newer "$KIT_VERSION" "$latest" && die "На GitHub версия $latest старше вашей $KIT_VERSION – ничего не делаю."
  if ! newer "$latest" "$KIT_VERSION" && [[ $force != yes ]] && ! needs_migration; then
    say "У вас последняя версия: $KIT_VERSION."
    [[ $unattended == yes ]] || echo "${D}Переустановить файлы kit той же версии: kit update --force${N}"
    return
  fi
  if [[ $latest == "$KIT_VERSION" ]]; then say "Применяю исправления версии $latest"; else say "3X-UI KIT $KIT_VERSION → $latest"; fi
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу: при выходе локальной переменной уже нет
  trap "rm -rf -- '$tmp'" EXIT
  fetch_release "$latest" "$tmp" || die "Сервер не тронут."
  bash -n "$tmp/kit.sh" && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$tmp/kit-sub.py" \
    || die "Файлы релиза не прошли проверку синтаксиса – сервер не тронут."

  # Подписка kit-sub: ставим новую, проверяем, что отвечает, иначе возвращаем старую.
  if [[ -f /usr/local/lib/kit-sub/kit_sub.py ]]; then
    cp /usr/local/lib/kit-sub/kit_sub.py "$tmp/kit_sub.old"
    cp /etc/systemd/system/kit-sub.service "$tmp/kit-sub.service.old"
    install -m 644 "$tmp/kit-sub.py" /usr/local/lib/kit-sub/kit_sub.py
    # С 1.1 kit-sub работает без root: переписываем юнит под DynamicUser и LoadCredential.
    local c k
    c=$(jq -r '.cert // empty' /etc/kit-sub/config.json); k=$(jq -r '.key // empty' /etc/kit-sub/config.json)
    kit_sub_unit "$c" "$k" >/etc/systemd/system/kit-sub.service
    [[ -n $c ]] && echo '19 4 * * * root systemctl restart kit-sub >/dev/null 2>&1' >/etc/cron.d/kit-sub-cert
    systemctl daemon-reload
    systemctl restart kit-sub
    sleep 2
    if sub_ok; then
      say "Подписка kit-sub обновлена и отвечает"
    else
      install -m 644 "$tmp/kit_sub.old" /usr/local/lib/kit-sub/kit_sub.py
      install -m 644 "$tmp/kit-sub.service.old" /etc/systemd/system/kit-sub.service
      grep -q '^LoadCredential=cert.pem' "$tmp/kit-sub.service.old" || rm -f /etc/cron.d/kit-sub-cert
      systemctl daemon-reload
      systemctl restart kit-sub
      die "Новая подписка не ответила – вернул прежнюю, kit остался версии $KIT_VERSION. Лог: journalctl -u kit-sub -n 30"
    fi
  fi

  # Исправления для установок 1.0.
  local all uri
  all=$(api POST setting/all)
  uri=${SUB_BASE:-}
  if [[ $uri == https://* && $(jq -r '.subURI // ""' <<<"$all") != "$uri" ]]; then
    api POST setting/update "$(jq -c --arg u "$uri" '.subURI = $u' <<<"$all")" >/dev/null
    say "Ссылка подписки в панели: $uri…"
  fi
  # 1.0 ставил cron, который каждый день правил файлы x-ui, – убираем.
  rm -f /etc/cron.d/kit-xui-menu
  # Автообновление включено по умолчанию, пока его не выключили командой kit update --manual.
  [[ -f $KIT_MANUAL ]] || auto_enabled || { auto_on; say "Включил автообновление: kit update --manual, чтобы выключить"; }

  # Через rename: bash дочитывает текущий kit по ходу работы, его файл трогать нельзя.
  install -m 755 "$tmp/kit.sh" /usr/local/bin/kit.new && mv -f /usr/local/bin/kit.new /usr/local/bin/kit
  echo
  echo "${G}✓ Готово: 3X-UI KIT $latest.${N} Пользователи, ссылки и подписки не менялись."
  [[ $unattended == yes ]] && return
  local news
  news=$(changelog_of "$latest")
  if [[ -n $news ]]; then echo; echo "${B}Что нового в $latest${N}"; echo "$news"; fi
}

# ---------- резервная копия ----------

# Всё, что нужно, чтобы поднять тот же сервер в другом месте: база панели (пользователи,
# ключи, подключения), настройки kit и kit-sub, nginx, сайт-заглушка, свои сертификаты.
# Сертификаты Let's Encrypt (на IP и на свой домен) не берём: на новом сервере он выпускается заново.
BACKUP_PATHS=(/etc/x-ui/install-result.env /etc/kit/kit.env /etc/kit-sub/config.json
  /etc/nginx/kit-stream.conf /etc/nginx/conf.d/kit.conf /var/www/kit /root/cert/self /root/cert/custom /root/3x-ui.txt)

cmd_backup() {
  local out tmp p ssl=none c
  out=/root/kit-backup-$(date +%Y%m%d-%H%M).tar.gz
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу: при выходе локальной переменной уже нет
  trap "rm -rf -- '$tmp'" EXIT
  install -d -m 700 "$tmp/etc/x-ui"
  # Снимок базы средствами SQLite: панель продолжает работать, копия целая.
  python3 - /etc/x-ui/x-ui.db "$tmp/etc/x-ui/x-ui.db" <<'PY' || die "Не удалось скопировать базу панели."
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PY
  for p in "${BACKUP_PATHS[@]}"; do if [[ -e $p ]]; then cp -a --parents "$p" "$tmp"; fi; done
  # Какой сертификат был у панели и подписки – новый сервер должен получить такой же.
  c=$(jq -r '.cert // empty' /etc/kit-sub/config.json 2>/dev/null || true)
  [[ -z $c && -f /etc/nginx/conf.d/kit.conf ]] && c=$(awk '$1 == "ssl_certificate" {sub(/;$/, "", $2); print $2; exit}' /etc/nginx/conf.d/kit.conf)
  case $c in
    /root/cert/ip/*) ssl=ip ;;
    /root/cert/custom/*) ssl=custom ;;
  esac
  {
    printf 'BACKUP_KIT_VERSION=%q\n' "$KIT_VERSION"
    printf 'BACKUP_HOST=%q\n' "$HOST"
    printf 'BACKUP_SSL=%q\n' "$ssl"
    printf 'BACKUP_DATE=%q\n' "$(date +%F)"
  } >"$tmp/kit-backup.env"
  (umask 077; tar -czf "$out" -C "$tmp" .)
  chmod 600 "$out"
  say "Резервная копия: ${B}$out${N} ($(du -h "$out" | cut -f1))"
  echo
  echo "В ней ключи и пароли от сервера, храните её как пароль. Скачать к себе (на компьютере):"
  echo "  ${B}scp root@$HOST:$out .${N}"
  echo
  echo "${D}Восстановление из копии на новом VPS появится в версии 1.2.${N}"
}

usage() {
  cat <<EOF
${B}kit${N} $KIT_VERSION – управление сервером 3X-UI KIT

Пользователи (один пользователь сразу на всех протоколах):
  kit user add имя [--gb 50] [--days 30] [--devices 3]   добавить и показать подписку
  kit user list                                           трафик, срок, статус
  kit user link имя [--all]                               подписка и QR; --all – ещё vpn:// и tg://
  kit user limit имя [--gb N] [--days N] [--devices N]    изменить лимиты (0 – без ограничений)
  kit user off имя  /  kit user on имя                    выключить и включить
  kit user del имя                                        удалить

Белый список (через VPN выходит только то, что в /etc/kit-sub/rules.yaml):
  kit whitelist on | off | status                          включить, выключить, состояние
  kit whitelist test домен                                куда сервер отправит соединение

Сервер:
  kit update            обновить kit и подписку kit-sub сейчас (пользователи и ссылки не меняются)
  kit update --manual   выключить автообновление (--auto – включить обратно)
  kit backup            резервная копия сервера (восстановление из неё – в версии 1.2)
  kit version           версия kit, панели и ядра
EOF
}

case "${1:-} ${2:-}" in
  "user add") shift 2; cmd_add "$@" ;;
  "user list") cmd_list; update_hint ;;
  "user link") shift 2; cmd_link "$@" ;;
  "user limit") shift 2; cmd_limit "$@" ;;
  "user off") cmd_toggle "${3:-}" false ;;
  "user on") cmd_toggle "${3:-}" true ;;
  "user del") shift 2; cmd_del "$@" ;;
  "whitelist "*) shift; exec python3 /usr/local/lib/kit-sub/kit_whitelist.py "$@" ;;
  "update "*) shift; cmd_update "$@" ;;
  "backup "*) cmd_backup ;;
  "version "*|"--version "*|"-v "*) cmd_version ;;
  *) usage; update_hint ;;
esac
