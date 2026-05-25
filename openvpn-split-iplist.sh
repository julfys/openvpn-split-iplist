#!/usr/bin/env bash

# Включаем строгий режим Bash:
# -e  — завершать скрипт при ошибке команды
# -u  — завершать скрипт при обращении к несуществующей переменной
# -o pipefail — считать ошибкой сбой любой команды в пайплайне
set -euo pipefail

# Директория, где будут храниться URL списка и сгенерированный файл маршрутов
BASE_DIR="/etc/openvpn/server/routes"

# Файл, в котором хранится URL iplist.opencck.org
URL_FILE="$BASE_DIR/iplist.url"

# Файл, который будет подключаться в конфиг OpenVPN через директиву config
ROUTES_FILE="$BASE_DIR/iplist-routes.conf"

# Python-скрипт, который скачивает CIDR-список и превращает его в OpenVPN push route
GEN_SCRIPT="/usr/local/sbin/update-openvpn-iplist-routes.py"

# systemd service для разового обновления маршрутов
SERVICE_FILE="/etc/systemd/system/openvpn-iplist-update.service"

# systemd timer для автоматического ежедневного обновления маршрутов
TIMER_FILE="/etc/systemd/system/openvpn-iplist-update.timer"

# URL списка сайтов. Его можно заменить через меню скрипта.
# Важно: format=text и data=cidr4 нужны, чтобы получить IPv4 CIDR-сети в текстовом виде.
DEFAULT_URL='https://iplist.opencck.org/?format=text&data=cidr4&site=aistudio.google.com&site=canva.com&site=chatgpt.com&site=claude.ai&site=copilot&site=deepl.com&site=deepseek.com&site=elevenlabs.io&site=grammarly.com&site=grok.com&site=kilo.ai&site=perplexity.ai&site=pollo.ai&site=discord.com&site=discord.gg&site=discord.media&site=telegram.org&site=whatsapp.com&site=youtube.com&site=instagram.com&site=facebook.com&site=x.com&site=tiktok.com&site=linkedin.com&site=netflix.com&site=spotify.com'

# Проверяем, что скрипт запущен от root.
# Это нужно, потому что мы меняем /etc/openvpn, systemd, iptables и sysctl.
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Ошибка: запусти скрипт от root: sudo $0"
    exit 1
  fi
}

# Пытаемся автоматически найти systemd-сервис OpenVPN.
# На разных системах он может называться по-разному:
# openvpn@server.service, openvpn-server@server.service и т.д.
detect_openvpn_service() {
  systemctl list-units --type=service --all 'openvpn-server@*' --no-legend | awk '{print $1}' | head -n1
}

# Пытаемся автоматически найти основной конфиг OpenVPN.
# Самые частые пути:
# /etc/openvpn/server/server.conf
# /etc/openvpn/server.conf
detect_openvpn_config() {
  local candidates=(
    "/etc/openvpn/server/server.conf"
    "/etc/openvpn/server.conf"
  )

  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return
    fi
  done

  # Если стандартные пути не подошли, ищем первый .conf внутри /etc/openvpn
  find /etc/openvpn -name '*.conf' 2>/dev/null | head -n1
}

# Устанавливаем зависимости, которые нужны для работы скрипта.
# curl — скачивание списка CIDR
# python3 — генерация OpenVPN-маршрутов
# iptables-persistent — сохранение NAT-правил после перезагрузки
install_deps() {
  apt-get update
  apt-get install -y curl python3 iptables-persistent
}

# Даём пользователю подтвердить или вручную указать путь к конфигу OpenVPN.
choose_config() {
  local detected
  detected="$(detect_openvpn_config || true)"

  echo
  echo "Найден конфиг OpenVPN: ${detected:-не найден}"
  read -rp "Путь к конфигу OpenVPN [$detected]: " OVPN_CONF
  OVPN_CONF="${OVPN_CONF:-$detected}"

  if [[ -z "${OVPN_CONF:-}" || ! -f "$OVPN_CONF" ]]; then
    echo "Ошибка: конфиг OpenVPN не найден."
    exit 1
  fi
}

# Даём пользователю подтвердить или вручную указать имя systemd-сервиса OpenVPN.
choose_service() {
  local detected
  detected="$(detect_openvpn_service || true)"

  echo
  echo "Найден systemd-сервис: ${detected:-не найден}"
  read -rp "Имя сервиса OpenVPN [$detected]: " OVPN_SERVICE
  OVPN_SERVICE="${OVPN_SERVICE:-$detected}"

  if [[ -z "${OVPN_SERVICE:-}" ]]; then
    echo "Ошибка: сервис OpenVPN не выбран."
    exit 1
  fi
}

# Создаём рабочие файлы:
# 1. директорию /etc/openvpn/server/routes
# 2. файл с URL списка
# 3. Python-генератор маршрутов
setup_files() {
  mkdir -p "$BASE_DIR"

  # Если URL ещё не задан, создаём файл с URL по умолчанию.
  if [[ ! -f "$URL_FILE" ]]; then
    printf '%s\n' "$DEFAULT_URL" > "$URL_FILE"
  fi

  # Создаём Python-скрипт, который скачивает CIDR-сети и формирует OpenVPN push route.
  cat > "$GEN_SCRIPT" <<'PY'
#!/usr/bin/env python3

# Модуль для безопасной проверки и разбора IP-сетей/CIDR
import ipaddress

# Модуль для запуска curl из Python
import subprocess

# Удобная работа с путями файловой системы
from pathlib import Path

# Файл с URL iplist.opencck.org
url_file = Path("/etc/openvpn/server/routes/iplist.url")

# Итоговый файл маршрутов для OpenVPN
out = Path("/etc/openvpn/server/routes/iplist-routes.conf")

# Временный файл. Сначала пишем в него, потом атомарно заменяем основной файл.
# Это защищает от ситуации, когда файл маршрутов будет повреждён при сбое.
tmp = out.with_suffix(".tmp")

# Читаем URL из файла
url = url_file.read_text().strip()

# Скачиваем список CIDR через curl.
# -f — ошибка при HTTP 4xx/5xx
# -s — тихий режим
# -S — показать ошибку, если она есть
# -L — следовать редиректам
# timeout=180 — не висеть бесконечно при проблемах с сетью
data = subprocess.check_output(["curl", "-fsSL", url], text=True, timeout=180)

# Начальные строки итогового файла маршрутов
lines = [
    "# Auto-generated by update-openvpn-iplist-routes.py",
    "# Do not edit manually.",
]

# Множество нужно, чтобы не добавлять дубликаты маршрутов
seen = set()

# Обрабатываем скачанный список построчно
for raw in data.splitlines():
    # Убираем пробелы по краям строки
    raw = raw.strip()

    # Пропускаем пустые строки и комментарии
    if not raw or raw.startswith("#"):
        continue

    try:
        # Пытаемся разобрать строку как IP-сеть
        # strict=False позволяет принять одиночный IP как сеть /32
        net = ipaddress.ip_network(raw, strict=False)
    except ValueError:
        # Если строка не является валидной сетью, просто пропускаем её
        continue

    # Этот скрипт рассчитан на IPv4, потому что URL использует data=cidr4
    if net.version != 4:
        continue

    # Приводим сеть к строке, чтобы проверить дубликаты
    key = str(net)
    if key in seen:
        continue

    seen.add(key)

    # OpenVPN route принимает адрес сети и маску, например:
    # push "route 1.2.3.0 255.255.255.0"
    lines.append(f'push "route {net.network_address} {net.netmask}"')

# Записываем новый файл маршрутов во временный файл
tmp.write_text("\n".join(lines) + "\n")

# Атомарно заменяем старый файл новым
tmp.replace(out)

# Выводим количество сгенерированных маршрутов
print(f"Generated {len(seen)} IPv4 OpenVPN routes")
PY

  chmod +x "$GEN_SCRIPT"
}

# Вносим изменения в конфиг OpenVPN.
# Скрипт не удаляет старый конфиг, а сначала делает бэкап.
patch_openvpn_config() {
  local conf="$1"
  local backup="${conf}.bak.$(date +%Y%m%d-%H%M%S)"

  cp "$conf" "$backup"
  echo "Бэкап конфига: $backup"

  # Отключаем redirect-gateway, если он есть.
  # Эта опция отправляет весь трафик клиента через VPN, а нам нужен split tunneling.
  sed -i 's/^[[:space:]]*push[[:space:]]*"redirect-gateway/# &/g' "$conf"

  # Подключаем файл маршрутов, если он ещё не подключён.
  if ! grep -qF "config $ROUTES_FILE" "$conf"; then
    printf '\n# Split tunneling routes from iplist\nconfig %s\n' "$ROUTES_FILE" >> "$conf"
  fi
}

# Включаем маршрутизацию IPv4 на сервере.
# Без этого сервер не будет пересылать трафик клиентов дальше в интернет.
setup_forwarding() {
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
  sysctl --system >/dev/null
}

# Настраиваем NAT для VPN-клиентов.
# Это нужно, чтобы сайты видели внешний IP сервера, а не приватный IP клиента из VPN-сети.
setup_nat() {
  echo
  echo "Список сетевых интерфейсов:"
  ip -brief link
  echo

  read -rp "Внешний интерфейс сервера, например eth0/ens3: " WAN_IF
  read -rp "VPN-сеть OpenVPN [10.8.0.0/24]: " VPN_NET
  VPN_NET="${VPN_NET:-10.8.0.0/24}"

  # Добавляем MASQUERADE только если такого правила ещё нет.
  if ! iptables -t nat -C POSTROUTING -s "$VPN_NET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$VPN_NET" -o "$WAN_IF" -j MASQUERADE
  fi

  # Сохраняем iptables-правила, чтобы они пережили перезагрузку сервера.
  netfilter-persistent save
}

# Генерируем файл маршрутов из текущего URL.
generate_routes() {
  "$GEN_SCRIPT"
  echo "Файл маршрутов: $ROUTES_FILE"
}

# Перезапускаем OpenVPN, чтобы он перечитал конфиг и новый файл маршрутов.
# Уже подключённым клиентам всё равно нужно переподключиться, чтобы получить новые route push.
restart_openvpn() {
  local service="$1"
  systemctl restart "$service"
  systemctl status "$service" --no-pager -l || true
}

# Создаём systemd service и timer для автоматического обновления списка маршрутов.
setup_timer() {
  local service="$1"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Update OpenVPN split routes from iplist

[Service]
Type=oneshot
ExecStart=$GEN_SCRIPT
ExecStartPost=/bin/systemctl restart $service
EOF

  cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Daily OpenVPN iplist route update

[Timer]
OnCalendar=*-*-* 05:20:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now openvpn-iplist-update.timer
}

# Полная установка и настройка.
install_all() {
  require_root
  install_deps
  choose_config
  choose_service
  setup_files
  generate_routes
  patch_openvpn_config "$OVPN_CONF"
  setup_forwarding
  setup_nat
  setup_timer "$OVPN_SERVICE"
  restart_openvpn "$OVPN_SERVICE"

  echo
  echo "Готово. Клиентам нужно переподключиться к OpenVPN, чтобы получить новые маршруты."
}

# Ручное обновление маршрутов без полной переустановки.
manual_update() {
  require_root

  if [[ ! -x "$GEN_SCRIPT" ]]; then
    echo "Генератор не установлен. Сначала выбери пункт установки."
    exit 1
  fi

  choose_service
  generate_routes
  restart_openvpn "$OVPN_SERVICE"
}

# Открываем файл URL в редакторе.
# По умолчанию используется nano, но можно задать EDITOR=vim.
edit_url() {
  require_root
  mkdir -p "$BASE_DIR"
  ${EDITOR:-nano} "$URL_FILE"
}

# Показываем диагностику текущей настройки.
diagnostics() {
  echo
  echo "OpenVPN services:"
  systemctl list-units --type=service --all 'openvpn*' --no-pager || true

  echo
  echo "Timer:"
  systemctl status openvpn-iplist-update.timer --no-pager -l || true

  echo
  echo "Routes file:"
  if [[ -f "$ROUTES_FILE" ]]; then
    wc -l "$ROUTES_FILE"
    head -n 10 "$ROUTES_FILE"
  else
    echo "Нет файла $ROUTES_FILE"
  fi

  echo
  echo "IP forward:"
  sysctl net.ipv4.ip_forward || true

  echo
  echo "NAT rules:"
  iptables -t nat -S POSTROUTING | grep MASQUERADE || true
}

# Откат интеграции с iplist.
# Важно: NAT-правило не удаляется автоматически, чтобы случайно не сломать рабочий VPN.
rollback() {
  require_root
  choose_config
  choose_service

  # Удаляем подключение файла маршрутов из конфига OpenVPN.
  sed -i "\|config $ROUTES_FILE|d" "$OVPN_CONF"

  # Отключаем и удаляем systemd timer/service.
  systemctl disable --now openvpn-iplist-update.timer 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE"
  systemctl daemon-reload

  restart_openvpn "$OVPN_SERVICE"

  echo "Откат выполнен. NAT-правило вручную не удалялось."
}

# Главное интерактивное меню.
menu() {
  while true; do
    echo
    echo "OpenVPN split tunneling via iplist"
    echo "1) Установить/настроить всё"
    echo "2) Обновить список маршрутов сейчас"
    echo "3) Изменить URL списка"
    echo "4) Диагностика"
    echo "5) Откатить интеграцию с iplist"
    echo "0) Выход"
    echo
    read -rp "Выбери пункт: " choice

    case "$choice" in
      1) install_all ;;
      2) manual_update ;;
      3) edit_url ;;
      4) diagnostics ;;
      5) rollback ;;
      0) exit 0 ;;
      *) echo "Неверный пункт." ;;
    esac
  done
}

# Запускаем меню.
menu
