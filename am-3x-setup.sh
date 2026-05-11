#!/bin/bash
# ============================================================
# am-3x — Автоматическая настройка маршрутизации Amnezia через 3x-ui
# Версия: 2.2
# Запуск: bash am-3x-setup.sh
# Удаление: bash am-3x-setup.sh --uninstall
# Требования: Docker, 3x-ui, root
#
# Что делает:
#   Перехватывает TCP трафик контейнеров Amnezia через NAT REDIRECT
#   и направляет в xray (dokodemo-door) → VLESS outbound.
#   QUIC (UDP:443) блокируется чтобы приложения использовали TCP.
#   Это обеспечивает полную маршрутизацию: YouTube, Instagram,
#   стриминг — всё через прокси.
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

msg_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
msg_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
msg_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
msg_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
msg_step()  { echo -e "\n${BOLD}━━━ $1 ━━━${NC}\n"; }
msg_bullet(){ echo -e "  ${GREEN}●${NC} $1"; }

XUI_DB="/etc/x-ui/x-ui.db"
DOKO_PORT="${AM3X_DOKO_PORT:-12747}"
LOG="/tmp/am-3x-setup.log"

exec > >(tee -a "$LOG") 2>&1

# ─── Uninstall ───
if [[ "${1:-}" == "--uninstall" ]]; then
    msg_step "Удаление am-3x"

    SUBNET=$(grep -oP '\d+\.\d+\.\d+\.\d+/\d+' /etc/iptables.rules 2>/dev/null | grep -v '127.0.0.0\|10.0.0.0\|172.16.0.0\|192.168.0.0\|169.254.0.0\|0.0.0.0/0' | head -1 || true)

    if [[ -z "$SUBNET" ]]; then
        SUBNET=$(iptables-save 2>/dev/null | grep "AMNEZIA_REDIRECT" | grep "PREROUTING" | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -1 || true)
    fi

    if [[ -z "$SUBNET" ]]; then
        read -rp "Введи подсеть (например 172.29.172.0/24): " SUBNET
    fi

    msg_info "Удаляю правила для $SUBNET"

    iptables -t nat -D PREROUTING -s "$SUBNET" -j AMNEZIA_REDIRECT 2>/dev/null || true
    iptables -t nat -F AMNEZIA_REDIRECT 2>/dev/null || true
    iptables -t nat -X AMNEZIA_REDIRECT 2>/dev/null || true

    # Удаляем MASQUERADE
    for iface in $(iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep "$SUBNET" | awk '{print $7}' | sort -u); do
        iptables -t nat -D POSTROUTING -s "$SUBNET" -o "!$iface" -j MASQUERADE 2>/dev/null || true
    done
    iptables -t nat -D POSTROUTING -s "$SUBNET" -j MASQUERADE 2>/dev/null || true

    iptables-save > /etc/iptables.rules 2>/dev/null || true
    systemctl disable am-3x-restore.service 2>/dev/null || true
    rm -f /etc/systemd/system/am-3x-restore.service
    systemctl daemon-reload 2>/dev/null || true

    msg_ok "iptables правила удалены"
    msg_warn "dokodemo-door inbound и routing rules НЕ удалены — удали вручную в 3x-ui если нужно"
    echo -e "\n${GREEN}✅ am-3x удалён${NC}"
    exit 0
fi

# ═══════════════════════════════════════════════════════════
# 0. Проверки
# ═══════════════════════════════════════════════════════════
msg_step "0. Проверка окружения"

[[ $EUID -ne 0 ]] && { msg_err "Запусти от root: sudo bash am-3x-setup.sh"; exit 1; }
msg_ok "root"

command -v docker &>/dev/null || { msg_err "Docker не установлен"; exit 1; }
msg_ok "Docker"

command -v python3 &>/dev/null || { msg_err "python3 не установлен"; exit 1; }
msg_ok "python3"

if ! command -v jq &>/dev/null; then
    msg_info "Устанавливаю jq..."
    apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1
fi
msg_ok "jq"

# ═══════════════════════════════════════════════════════════
# 1. Контейнеры Amnezia
# ═══════════════════════════════════════════════════════════
msg_step "1. Поиск контейнеров Amnezia"

mapfile -t CONTAINERS < <(docker ps --filter "name=amnezia" --format "{{.Names}}" 2>/dev/null)
if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    mapfile -t CONTAINERS < <(docker ps --format "{{.Names}}" | grep -iE 'amnezia|awg|wg|wireguard|amn' 2>/dev/null || true)
fi
if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    msg_err "Контейнеры Amnezia не найдены."
    echo -e "  ${DIM}Убедись что контейнеры запущены и содержат 'amnezia' в названии${NC}"
    exit 1
fi

msg_ok "Найдено: ${#CONTAINERS[@]}"
for c in "${CONTAINERS[@]}"; do
    IMG=$(docker inspect "$c" --format "{{.Config.Image}}" 2>/dev/null || echo "?")
    PRT=$(docker port "$c" 2>/dev/null | tr '\n' ' ')
    msg_bullet "$c ($IMG) — $PRT"
done

# ═══════════════════════════════════════════════════════════
# 2. Сеть контейнеров
# ═══════════════════════════════════════════════════════════
msg_step "2. Определение сети"

SUBNETS=()
CUSTOM_NET=""
for c in "${CONTAINERS[@]}"; do
    while read -r net_name; do
        [[ -z "$net_name" ]] && continue
        sn=$(docker network inspect "$net_name" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | tr -d '\n')
        [[ -z "$sn" || "$sn" == "null" ]] && continue
        [[ "$sn" == "172.17.0.0/16" ]] && continue
        [[ " ${SUBNETS[*]} " =~ " ${sn} " ]] || SUBNETS+=("$sn")
        [[ -z "$CUSTOM_NET" ]] && CUSTOM_NET="$net_name"
    done < <(docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}' 2>/dev/null)
done

[[ ${#SUBNETS[@]} -eq 0 ]] && { msg_err "Подсеть не определена"; exit 1; }

if [[ ${#SUBNETS[@]} -eq 1 ]]; then
    SUBNET="${SUBNETS[0]}"
else
    echo -e "  ${YELLOW}Найдено несколько подсетей:${NC}"
    for i in "${!SUBNETS[@]}"; do
        echo -e "  ${BOLD}$((i+1)))${NC} ${SUBNETS[$i]}"
    done
    read -rp "Выбери подсеть [1-${#SUBNETS[@]}]: " SN_CHOICE
    SN_CHOICE="${SN_CHOICE:-1}"
    SUBNET="${SUBNETS[$((SN_CHOICE-1))]}"
fi
msg_ok "Подсеть: $SUBNET"
msg_ok "Сеть: $CUSTOM_NET"

# ═══════════════════════════════════════════════════════════
# 3. 3x-ui
# ═══════════════════════════════════════════════════════════
msg_step "3. Поиск 3x-ui"

if ! pgrep -f "x-ui" >/dev/null 2>&1; then
    msg_err "3x-ui не запущен"
    exit 1
fi
msg_ok "3x-ui запущен"

[[ -f "$XUI_DB" ]] || { msg_err "БД не найдена: $XUI_DB"; exit 1; }

db_get() {
    python3 -c "
import sqlite3, sys
c = sqlite3.connect('$XUI_DB').cursor()
c.execute(\"SELECT value FROM settings WHERE key='$1'\")
r = c.fetchone()
print(r[0] if r else '')
" 2>/dev/null
}

XUI_PORT=$(db_get "webPort")
XUI_PATH=$(db_get "webBasePath")
[[ -z "$XUI_PORT" ]] && { msg_err "Порт панели не определён"; exit 1; }
[[ -z "$XUI_PATH" ]] && XUI_PATH="/"

XUI_REAL_PORT=""
for p in "$XUI_PORT" 2096 2053 54321 8888 80 443; do
    curl -sk "http://127.0.0.1:${p}${XUI_PATH}" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -qE "200|302" && { XUI_REAL_PORT="$p"; break; }
done
[[ -z "$XUI_REAL_PORT" ]] && XUI_REAL_PORT="$XUI_PORT"

msg_ok "Панель: http://127.0.0.1:${XUI_REAL_PORT}${XUI_PATH}"

# ═══════════════════════════════════════════════════════════
# 4. Авторизация
# ═══════════════════════════════════════════════════════════
msg_step "4. Авторизация в 3x-ui"

XUI_BASE="http://127.0.0.1:${XUI_REAL_PORT}${XUI_PATH}"

XUI_USER=$(python3 -c "
import sqlite3
c = sqlite3.connect('$XUI_DB').cursor()
c.execute('SELECT username FROM users LIMIT 1')
print((c.fetchone() or ['admin'])[0])
" 2>/dev/null)

echo -e "  Пользователь: ${BOLD}$XUI_USER${NC}"
if [[ -n "${AM3X_PASSWORD:-}" ]]; then
    XUI_PASS="$AM3X_PASSWORD"
else
    read -rsp "  Пароль (Enter = admin): " XUI_PASS; echo ""
    XUI_PASS="${XUI_PASS:-admin}"
fi

CF=$(mktemp)
LOGIN_BODY=$(curl -sk "${XUI_BASE}login" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$XUI_USER\",\"password\":\"$XUI_PASS\"}" \
    -c "$CF" 2>/dev/null)

if ! echo "$LOGIN_BODY" | jq -e '.success' >/dev/null 2>&1; then
    msg_warn "Пароль не подходит. Сбрасываю на 'admin'..."
    python3 << 'PYRESET'
import sqlite3, subprocess, sys
try:
    import bcrypt
except ImportError:
    subprocess.run(["python3", "-m", "pip", "install", "bcrypt", "-q"], capture_output=True)
    import bcrypt
h = bcrypt.hashpw(b"admin", bcrypt.gensalt(10)).decode().replace("$2b$", "$2a$")
c = sqlite3.connect("/etc/x-ui/x-ui.db").cursor()
c.execute("UPDATE users SET password=? WHERE id=1", (h,))
c.connection.commit()
PYRESET
    XUI_PASS="admin"
    LOGIN_BODY=$(curl -sk "${XUI_BASE}login" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$XUI_USER\",\"password\":\"admin\"}" \
        -c "$CF" 2>/dev/null)
    if ! echo "$LOGIN_BODY" | jq -e '.success' >/dev/null 2>&1; then
        msg_err "Авторизация не удалась даже после сброса"
        rm -f "$CF"
        exit 1
    fi
fi

CK=$(grep "3x-ui" "$CF" | awk '{print $NF}')
COOKIE="3x-ui=$CK"
rm -f "$CF"
msg_ok "Авторизация успешна"

# ═══════════════════════════════════════════════════════════
# 5. Outbound
# ═══════════════════════════════════════════════════════════
msg_step "5. Определение outbound"

OBF=$(cat /usr/local/x-ui/bin/config.json 2>/dev/null || echo "{}")

mapfile -t O_TAGS < <(echo "$OBF" | jq -r '.outbounds[] | select(.protocol != "freedom" and .protocol != "blackhole") | .tag' 2>/dev/null)

if [[ ${#O_TAGS[@]} -eq 0 ]]; then
    msg_err "Не найдено outbound'ов (VLESS/VMess/Trojan и т.д.) в 3x-ui"
    msg_info "Сначала настрой outbound в панели 3x-ui, потом запусти скрипт"
    exit 1
fi

if [[ ${#O_TAGS[@]} -eq 1 ]]; then
    OTAG="${O_TAGS[0]}"
else
    echo -e "  ${YELLOW}Найдено несколько outbound'ов:${NC}"
    for i in "${!O_TAGS[@]}"; do
        addr=$(echo "$OBF" | jq -r --arg t "${O_TAGS[$i]}" '.outbounds[] | select(.tag == $t) | .settings.address // "?:"')
        port=$(echo "$OBF" | jq -r --arg t "${O_TAGS[$i]}" '.outbounds[] | select(.tag == $t) | .settings.port // ""')
        echo -e "  ${BOLD}$((i+1)))${NC} ${O_TAGS[$i]} → $addr:${port}"
    done
    read -rp "Выбери outbound [1-${#O_TAGS[@]}]: " O_CHOICE
    O_CHOICE="${O_CHOICE:-1}"
    OTAG="${O_TAGS[$((O_CHOICE-1))]}"
fi

OADDR=$(echo "$OBF" | jq -r --arg t "$OTAG" '.outbounds[] | select(.tag == $t) | .settings.address' | head -1)
OPORT=$(echo "$OBF" | jq -r --arg t "$OTAG" '.outbounds[] | select(.tag == $t) | .settings.port' | head -1)
OPROTO=$(echo "$OBF" | jq -r --arg t "$OTAG" '.outbounds[] | select(.tag == $t) | .protocol' | head -1)

OIP=""
if [[ -n "$OADDR" ]]; then
    OIP=$(getent hosts "$OADDR" 2>/dev/null | awk '{print $1}' | head -1 || true)
    [[ -z "$OIP" ]] && OIP=$(dig +short "$OADDR" 2>/dev/null | tail -1 || true)
    [[ -z "$OIP" ]] && OIP="$OADDR"
fi

msg_ok "Outbound: $OTAG ($OPROTO) → $OADDR:${OPORT} ($OIP)"

# ═══════════════════════════════════════════════════════════
# 6. Подтверждение
# ═══════════════════════════════════════════════════════════
msg_step "6. Подтверждение"

echo -e "  ${BOLD}Контейнеры:${NC}     ${#CONTAINERS[@]} шт."
for c in "${CONTAINERS[@]}"; do
    echo -e "  ${DIM}  - $c${NC}"
done
echo -e "  ${BOLD}Подсеть:${NC}        $SUBNET"
echo -e "  ${BOLD}Docker сеть:${NC}    $CUSTOM_NET"
echo -e "  ${BOLD}dokodemo-door:${NC}  0.0.0.0:$DOKO_PORT"
echo -e "  ${BOLD}Outbound:${NC}       $OTAG → $OADDR:${OPORT}"
echo ""
echo -e "  ${CYAN}TCP → через прокси ($OTAG)${NC}"
echo -e "  ${CYAN}QUIC (UDP:443) → заблокирован (приложения используют TCP)${NC}"
echo -e "  ${CYAN}Остальной UDP → напрямую${NC}"
echo ""
echo -e "  ${YELLOW}Весь TCP трафик контейнеров пойдёт через $OTAG${NC}"
echo ""

read -rp "Продолжить? [Y/n]: " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && { msg_info "Отменено"; exit 0; }

# ═══════════════════════════════════════════════════════════
# 7. Создание dokodemo-door inbound
# ═══════════════════════════════════════════════════════════
msg_step "7. Создание dokodemo-door inbound"

# Удаляем старые am-3x inbound'ы
for id in $(curl -sk "${XUI_BASE}panel/api/inbounds/list" -H "Cookie: $COOKIE" 2>/dev/null | jq -r '.obj[] | select(.protocol=="dokodemo-door" and (.remark | test("am-3x|transparent"))) | .id' 2>/dev/null || true); do
    msg_info "Удаляю старый inbound #$id"
    curl -sk "${XUI_BASE}panel/api/inbounds/del/$id" -H "Cookie: $COOKIE" -X POST >/dev/null 2>&1
done

RESP=$(curl -sk "${XUI_BASE}panel/api/inbounds/add" -X POST \
    -H "Cookie: $COOKIE" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
        --arg port "$DOKO_PORT" \
        '{
            enable:true,
            listen:"0.0.0.0",
            port:($port|tonumber),
            protocol:"dokodemo-door",
            settings:"{\"network\":\"tcp,udp\",\"followRedirect\":true}",
            streamSettings:"{\"network\":\"tcp\"}",
            tag:"transparent-proxy",
            sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"routeOnly\":false,\"metadataOnly\":false}",
            remark:"am-3x-transparent-proxy"
        }'
    )" 2>/dev/null)

if echo "$RESP" | jq -e '.success' >/dev/null 2>&1; then
    msg_ok "dokodemo-door создан на порту $DOKO_PORT"
else
    msg_err "Ошибка создания inbound: $RESP"
    exit 1
fi

# ═══════════════════════════════════════════════════════════
# 8. Настройка DNS и routing в шаблоне xray
# ═══════════════════════════════════════════════════════════
msg_step "8. Настройка DNS и routing"

python3 << PYDNS
import sqlite3, json
c = sqlite3.connect("$XUI_DB").cursor()
c.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'")
r = c.fetchone()
if r:
    t = json.loads(r[0])
    changed = False

    # DNS
    if not t.get("dns") or t.get("dns") is None:
        t["dns"] = {"servers": ["1.1.1.1", "8.8.8.8", "localhost"]}
        changed = True

    # domainStrategy
    if t.get("routing", {}).get("domainStrategy") != "IPIfNonMatch":
        t.setdefault("routing", {})["domainStrategy"] = "IPIfNonMatch"
        changed = True

    # Routing rules: QUIC block BEFORE general proxy rule
    rules = t["routing"]["rules"]
    
    # Remove existing QUIC blocks and our custom rules
    rules = [r for r in rules if r.get("outboundTag") == "api"]
    
    # 1. QUIC block (MUST be before general proxy rule!)
    rules.append({
        "type": "field",
        "outboundTag": "blocked",
        "port": "443",
        "network": "udp",
        "inboundTag": ["dokodemo-door"]
    })
    # 2. General proxy rule
    rules.append({
        "type": "field",
        "inboundTag": ["dokodemo-door"],
        "outboundTag": "$OTAG"
    })
    # 3. Private IP block
    rules.append({
        "type": "field",
        "outboundTag": "blocked",
        "ip": ["geoip:private"]
    })
    # 4. Bittorrent block
    rules.append({
        "type": "field",
        "outboundTag": "blocked",
        "protocol": ["bittorrent"]
    })
    
    t["routing"]["rules"] = rules
    changed = True

    if changed:
        c.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(t, ensure_ascii=False),))
        c.connection.commit()
        print("UPDATED")
    else:
        print("ALREADY_OK")
else:
    print("NO_TEMPLATE")
PYDNS

# ═══════════════════════════════════════════════════════════
# 9. Перезапуск 3x-ui
# ═══════════════════════════════════════════════════════════
msg_step "9. Перезапуск 3x-ui"

x-ui restart >/dev/null 2>&1 || systemctl restart x-ui >/dev/null 2>&1
sleep 3

for i in $(seq 1 15); do
    if ss -tlnp | grep -q ":${DOKO_PORT}"; then
        break
    fi
    sleep 1
done

if ss -tlnp | grep -q ":${DOKO_PORT}"; then
    msg_ok "3x-ui перезапущен, dokodemo-door слушает :$DOKO_PORT"
else
    msg_warn "Порт $DOKO_PORT не обнаружен, проверь логи: journalctl -u x-ui -n 20"
fi

# ═══════════════════════════════════════════════════════════
# 10. iptables — TCP NAT REDIRECT
# ═══════════════════════════════════════════════════════════
msg_step "10. Настройка iptables"

msg_info "TCP: NAT REDIRECT → :$DOKO_PORT"

iptables -t nat -N AMNEZIA_REDIRECT 2>/dev/null || iptables -t nat -F AMNEZIA_REDIRECT

iptables -t nat -A AMNEZIA_REDIRECT -d 127.0.0.0/8 -j RETURN
iptables -t nat -A AMNEZIA_REDIRECT -d 10.0.0.0/8 -j RETURN
iptables -t nat -A AMNEZIA_REDIRECT -d 172.16.0.0/12 -j RETURN
iptables -t nat -A AMNEZIA_REDIRECT -d 192.168.0.0/16 -j RETURN
iptables -t nat -A AMNEZIA_REDIRECT -d 169.254.0.0/16 -j RETURN

if [[ -n "$OIP" ]]; then
    iptables -t nat -A AMNEZIA_REDIRECT -d "$OIP" -j RETURN
fi

iptables -t nat -A AMNEZIA_REDIRECT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

iptables -t nat -A AMNEZIA_REDIRECT -p tcp -j REDIRECT --to-port "$DOKO_PORT"

iptables -t nat -D PREROUTING -s "$SUBNET" -j AMNEZIA_REDIRECT 2>/dev/null || true
iptables -t nat -A PREROUTING -s "$SUBNET" -j AMNEZIA_REDIRECT
msg_ok "NAT REDIRECT (TCP через прокси, QUIC заблокирован в xray routing)"

# --- MASQUERADE ---
if [[ -n "$CUSTOM_NET" ]]; then
    iptables -t nat -D POSTROUTING -s "$SUBNET" -o ! "$CUSTOM_NET" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -s "$SUBNET" -o ! "$CUSTOM_NET" -j MASQUERADE
else
    iptables -t nat -C POSTROUTING -s "$SUBNET" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s "$SUBNET" -j MASQUERADE
fi
msg_ok "MASQUERADE"

# --- TCP MSS clamping ---
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
msg_ok "TCP MSS clamping"

# ═══════════════════════════════════════════════════════════
# 11. Persistence
# ═══════════════════════════════════════════════════════════
msg_step "11. Сохранение настроек"

iptables-save > /etc/iptables.rules
msg_ok "/etc/iptables.rules"

cat > /etc/rc.local << RCEOF
#!/bin/bash
# am-3x v2.2: TCP NAT REDIRECT + QUIC blocked in xray routing
iptables-restore < /etc/iptables.rules
exit 0
RCEOF
chmod +x /etc/rc.local
msg_ok "/etc/rc.local"

cat > /etc/systemd/system/am-3x-restore.service << SVCEOF
[Unit]
Description=am-3x iptables restore
After=network.target docker.service x-ui.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'iptables-restore < /etc/iptables.rules'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload 2>/dev/null
systemctl enable am-3x-restore.service 2>/dev/null
msg_ok "systemd: am-3x-restore.service"

# ═══════════════════════════════════════════════════════════
# 12. Проверка
# ═══════════════════════════════════════════════════════════
msg_step "12. Проверка"

TC="${CONTAINERS[0]}"
msg_info "Тест из $TC ..."

TIP=""
for url in "https://api.ipify.org" "http://ifconfig.me/ip" "https://api.ip.sb"; do
    TIP=$(docker exec "$TC" sh -c "curl -s --connect-timeout 8 '$url' 2>/dev/null || wget -qO- --timeout=8 '$url' 2>/dev/null" 2>/dev/null || true)
    if [[ "$TIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    TIP=""
done

echo ""
if [[ -n "$TIP" ]]; then
    if [[ "$TIP" == "$OIP" ]]; then
        msg_ok "✅ $TC → $TIP (через outbound $OTAG)"
    else
        msg_warn "⚠️  $TC → $TIP (ожидали $OIP через $OTAG)"
        msg_info "Проверь routing rules в панели 3x-ui"
    fi
else
    msg_warn "⚠️  Не удалось проверить IP (нет curl/wget в контейнере)"
    msg_info "Проверь вручную: docker exec $TC curl -s https://api.ipify.org"
fi

# ═══════════════════════════════════════════════════════════
# 13. Итог
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ am-3x v2.2 настроен!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Контейнеры:${NC}     ${#CONTAINERS[@]} шт."
echo -e "  ${BOLD}Подсеть:${NC}        $SUBNET"
echo -e "  ${BOLD}Docker сеть:${NC}    $CUSTOM_NET"
echo -e "  ${BOLD}dokodemo-door:${NC}  0.0.0.0:$DOKO_PORT"
echo -e "  ${BOLD}Outbound:${NC}       $OTAG → $OADDR:${OPORT}"
echo ""
echo -e "  ${CYAN}TCP → прокси ($OTAG)${NC}"
echo -e "  ${CYAN}QUIC (UDP:443) → заблокирован (приложения → TCP)${NC}"
echo -e "  ${CYAN}Остальной UDP → напрямую${NC}"
echo ""
echo -e "  ${YELLOW}⚠️  Порты для проброса на роутере:${NC}"
for c in "${CONTAINERS[@]}"; do
    PRT=$(docker port "$c" 2>/dev/null)
    [[ -n "$PRT" ]] && echo -e "  ${YELLOW}   $c: $PRT${NC}"
done
echo ""
echo -e "  ${DIM}Лог установки: $LOG${NC}"
echo -e "  ${DIM}Удалить: sudo bash am-3x-setup.sh --uninstall${NC}"
echo ""
echo -e "  ${YELLOW}Важно:${NC} routing rules в 3x-ui должны быть в таком порядке:"
echo -e "  ${YELLOW}  1. QUIC block (UDP:443 → blocked)${NC}"
echo -e "  ${YELLOW}  2. dokodemo-door → $OTAG${NC}"
echo -e "  ${YELLOW}  3. private IP → blocked${NC}"
echo -e "  ${YELLOW}Если порядок неправильный — QUIC не заблокируется!${NC}"
echo ""
