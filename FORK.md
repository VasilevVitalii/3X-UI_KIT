# Отличия форка от itsnotkubrick/3X-UI_KIT

Основа – [3X-UI KIT](https://github.com/itsnotkubrick/3X-UI_KIT) версии 1.1. Что изменено:

1. **Свои правила маршрутизации в подписке.** Если на сервере есть `/etc/kit-sub/rules.yaml`,
   приложения на Mihomo (FlClash, Clash Verge Rev, Mihomo Party) получают конфиг, в котором
   через VPN идёт только перечисленное в `via_vpn`, а всё остальное – напрямую. Пример с
   пояснениями – `scripts/rules.example.yaml`, при установке он кладётся на сервер.
   Файл читается при каждом запросе подписки – после правки достаточно обновить подписку
   в приложении. Удалите файл – и подписка снова отдаёт конфиг 3X-UI как есть.
   Приложения со ссылками (Hiddify, v2rayNG, Happ) правила не получают.
2. **Белый список на сервере** (`kit whitelist on`). Тот же `rules.yaml` превращается в
   маршрутизацию Xray: перечисленное выходит с сервера, остальное с пользовательских
   подключений блокируется – даже если на устройстве выбран режим «весь трафик через VPN»
   или стоит приложение без правил. Категории GEOSITE раскрываются по той же базе, что
   у приложений (MetaCubeX geosite.dat), поэтому сервер и устройства согласованы.
   После правки `rules.yaml` применяется сам (systemd path), база обновляется раз в неделю.
   Если Xray с новыми правилами не запустился – прежние возвращаются автоматически.
3. **Адреса** в скриптах указывают на этот форк.
4. **Автообновление выключено, `kit update` не работает:** подписанный релиз автора
   перезаписал бы `kit-sub.py` с правилами.

## Установка

```bash
apt-get update && apt-get install -y git
git clone https://github.com/VasilevVitalii/3X-UI_KIT.git /root/3X-UI_KIT
bash /root/3X-UI_KIT/scripts/3x-ui.sh
```

Запуск из клона берёт `kit.sh`, `kit-sub.py`, `kit-whitelist.py` и пример правил прямо из него.

## Правила

```bash
nano /etc/kit-sub/rules.yaml        # список via_vpn
journalctl -u kit-sub -n 20         # видно, если какое-то правило пропущено
kit whitelist on                    # белый список на сервере по тому же файлу
kit whitelist status
kit whitelist test ya.ru            # blocked – через VPN не выйдет; direct – выйдет
journalctl -u kit-whitelist -n 20   # что произошло при автоматическом применении
```

## Обновление из форка

Сначала влить изменения автора в форк (на GitHub: Sync fork, или локально
`git pull https://github.com/itsnotkubrick/3X-UI_KIT.git main`), проверить, затем на сервере:

```bash
cd /root/3X-UI_KIT && git pull
install -m 755 scripts/kit.sh /usr/local/bin/kit
install -m 644 scripts/kit-sub.py /usr/local/lib/kit-sub/kit_sub.py && systemctl restart kit-sub
install -m 644 scripts/kit-whitelist.py /usr/local/lib/kit-sub/kit_whitelist.py && kit whitelist sync
```

Если автор поменял что-то в установке панели (версии 3X-UI, Xray), смотрите его
CHANGELOG.md: такие изменения на уже установленный сервер этими командами не приезжают.
