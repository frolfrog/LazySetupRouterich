#!/bin/sh
# =============================================================================
# RouteRich AX3000 (OpenWrt) — AmneziaWG + Split Tunneling Setup Script
# =============================================================================
# Использование:
#   sh <(wget -O - https://your-host/routerich-awg-setup.sh) /path/to/vpn.conf
#
# Или в два шага:
#   wget -O /tmp/setup.sh https://your-host/routerich-awg-setup.sh
#   sh /tmp/setup.sh /tmp/vpn.conf
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

echo ""
echo "============================================================"
echo "  RouteRich AX3000 — AmneziaWG Setup"
echo "============================================================"
echo ""

# =============================================================================
# Проверка аргумента — путь к конфигу
# =============================================================================
CONF_FILE="$1"

if [ -z "$CONF_FILE" ]; then
    log_error "Укажите путь к конфигу AWG:"
    echo ""
    echo "  sh <(wget -O - https://your-host/setup.sh) /path/to/vpn.conf"
    echo ""
    exit 1
fi

if [ ! -f "$CONF_FILE" ]; then
    log_error "Файл не найден: $CONF_FILE"
    exit 1
fi

log_info "Читаю конфиг: $CONF_FILE"

# =============================================================================
# Парсинг конфига
# =============================================================================
PRIVATE_KEY=$(grep -i "^PrivateKey"         "$CONF_FILE" | awk '{print $3}')
ADDRESS=$(grep -i "^Address"                "$CONF_FILE" | awk '{print $3}')
DNS=$(grep -i "^DNS"                        "$CONF_FILE" | awk '{print $3}')
PUBLIC_KEY=$(grep -i "^PublicKey"           "$CONF_FILE" | awk '{print $3}')
PRESHARED_KEY=$(grep -i "^PresharedKey"     "$CONF_FILE" | awk '{print $3}')
ENDPOINT=$(grep -i "^Endpoint"             "$CONF_FILE" | awk '{print $3}')
KEEPALIVE=$(grep -i "^PersistentKeepalive" "$CONF_FILE" | awk '{print $3}')

JC=$(grep -i   "^Jc\b"   "$CONF_FILE" | awk '{print $3}')
JMIN=$(grep -i "^Jmin\b" "$CONF_FILE" | awk '{print $3}')
JMAX=$(grep -i "^Jmax\b" "$CONF_FILE" | awk '{print $3}')
S1=$(grep -i   "^S1\b"   "$CONF_FILE" | awk '{print $3}')
S2=$(grep -i   "^S2\b"   "$CONF_FILE" | awk '{print $3}')
H1=$(grep -i   "^H1\b"   "$CONF_FILE" | awk '{print $3}')
H2=$(grep -i   "^H2\b"   "$CONF_FILE" | awk '{print $3}')
H3=$(grep -i   "^H3\b"   "$CONF_FILE" | awk '{print $3}')
H4=$(grep -i   "^H4\b"   "$CONF_FILE" | awk '{print $3}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$ENDPOINT" ]; then
    log_error "Конфиг неполный. Должны быть: PrivateKey, PublicKey, Endpoint"
    exit 1
fi

ENDPOINT_HOST=$(echo "$ENDPOINT" | cut -d: -f1)
ENDPOINT_PORT=$(echo "$ENDPOINT" | cut -d: -f2)
TUNNEL_IP=$(echo "$ADDRESS" | cut -d/ -f1)

# Параметры с умолчаниями
AWG_IFACE="awg1"
NTP_SERVER="194.190.168.1"

# Определяем шлюз WAN автоматически
WAN_GW=$(ip route show | grep "default via" | grep -v "$AWG_IFACE" | head -1 | awk '{print $3}')
if [ -z "$WAN_GW" ]; then
    log_warn "Не удалось определить шлюз WAN автоматически."
    printf "Введите IP шлюза WAN (например 192.168.1.1): "
    read -r WAN_GW
fi

# =============================================================================
# Подтверждение параметров
# =============================================================================
echo ""
log_info "Параметры установки:"
echo "  Интерфейс : $AWG_IFACE"
echo "  Endpoint  : $ENDPOINT_HOST:$ENDPOINT_PORT"
echo "  Tunnel IP : $TUNNEL_IP"
echo "  WAN шлюз  : $WAN_GW"
echo "  NTP       : $NTP_SERVER"
[ -n "$JC" ] && echo "  AWG 1.0   : Jc=$JC Jmin=$JMIN Jmax=$JMAX S1=$S1 S2=$S2"
[ -n "$H1" ] && echo "  AWG 2.0   : H1=$H1 H2=$H2 H3=$H3 H4=$H4"
echo ""

printf "Продолжить установку? (y/n): "
read -r CONFIRM
[ "$CONFIRM" != "y" ] && { log_warn "Отменено."; exit 0; }
echo ""

# =============================================================================
# ШАГ 1: Установка пакетов AmneziaWG
# =============================================================================
log_info "=== ШАГ 1: Установка пакетов AmneziaWG ==="

if opkg list-installed 2>/dev/null | grep -q "kmod-amneziawg"; then
    log_info "kmod-amneziawg уже установлен, пропускаю"
else
    log_info "Устанавливаю через скрипт Shchipunov (1-2 минуты)..."
    printf "n\nn\n" | sh <(wget -4 -O - \
        https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh) \
        2>&1 | grep -E "installed|error|ERROR" || true
    log_info "Пакеты установлены"
fi

# =============================================================================
# ШАГ 2: Создание VPN интерфейса через UCI
# =============================================================================
log_info "=== ШАГ 2: Создание VPN интерфейса ==="

uci delete network.$AWG_IFACE        2>/dev/null || true
uci delete network.${AWG_IFACE}_peer 2>/dev/null || true

uci set network.$AWG_IFACE=interface
uci set network.$AWG_IFACE.proto=amneziawg
uci set network.$AWG_IFACE.addresses="$ADDRESS"
uci set network.$AWG_IFACE.private_key="$PRIVATE_KEY"

[ -n "$DNS"  ] && uci set network.$AWG_IFACE.dns="$DNS"
[ -n "$JC"   ] && uci set network.$AWG_IFACE.jc="$JC"
[ -n "$JMIN" ] && uci set network.$AWG_IFACE.jmin="$JMIN"
[ -n "$JMAX" ] && uci set network.$AWG_IFACE.jmax="$JMAX"
[ -n "$S1"   ] && uci set network.$AWG_IFACE.s1="$S1"
[ -n "$S2"   ] && uci set network.$AWG_IFACE.s2="$S2"
[ -n "$H1"   ] && uci set network.$AWG_IFACE.h1="$H1"
[ -n "$H2"   ] && uci set network.$AWG_IFACE.h2="$H2"
[ -n "$H3"   ] && uci set network.$AWG_IFACE.h3="$H3"
[ -n "$H4"   ] && uci set network.$AWG_IFACE.h4="$H4"

uci set network.${AWG_IFACE}_peer=amneziawg_${AWG_IFACE}
uci set network.${AWG_IFACE}_peer.public_key="$PUBLIC_KEY"
uci set network.${AWG_IFACE}_peer.endpoint_host="$ENDPOINT_HOST"
uci set network.${AWG_IFACE}_peer.endpoint_port="$ENDPOINT_PORT"
uci set network.${AWG_IFACE}_peer.allowed_ips="0.0.0.0/0"
uci set network.${AWG_IFACE}_peer.route_allowed_ips="1"
[ -n "$PRESHARED_KEY" ] && uci set network.${AWG_IFACE}_peer.preshared_key="$PRESHARED_KEY"
[ -n "$KEEPALIVE"     ] && uci set network.${AWG_IFACE}_peer.persistent_keepalive="$KEEPALIVE"

uci commit network
log_info "Интерфейс $AWG_IFACE создан"

# =============================================================================
# ШАГ 3: Файрвол
# =============================================================================
log_info "=== ШАГ 3: Настройка файрвола ==="

uci delete firewall.awg_zone   2>/dev/null || true
uci delete firewall.lan_to_awg 2>/dev/null || true

uci set firewall.awg_zone=zone
uci set firewall.awg_zone.name=awg
uci set firewall.awg_zone.network="$AWG_IFACE"
uci set firewall.awg_zone.input=REJECT
uci set firewall.awg_zone.output=ACCEPT
uci set firewall.awg_zone.forward=REJECT
uci set firewall.awg_zone.masq=1
uci set firewall.awg_zone.mtu_fix=1

uci set firewall.lan_to_awg=forwarding
uci set firewall.lan_to_awg.src=lan
uci set firewall.lan_to_awg.dest=awg

uci set network.wan.metric=100

uci commit firewall
uci commit network
log_info "Файрвол настроен"

# =============================================================================
# ШАГ 4: Маршрутизация
# =============================================================================
log_info "=== ШАГ 4: Маршрутизация ==="

uci delete network.ntp_route 2>/dev/null || true
uci delete network.awg_route 2>/dev/null || true

uci set network.ntp_route=route
uci set network.ntp_route.interface=wan
uci set network.ntp_route.target="$NTP_SERVER"
uci set network.ntp_route.netmask=255.255.255.255
uci set network.ntp_route.metric=1

uci set network.awg_route=route
uci set network.awg_route.interface="$AWG_IFACE"
uci set network.awg_route.target=0.0.0.0
uci set network.awg_route.netmask=0.0.0.0
uci set network.awg_route.metric=20

uci commit network
log_info "Маршрутизация настроена"

# =============================================================================
# ШАГ 5: NTP
# =============================================================================
log_info "=== ШАГ 5: NTP ==="

uci add_list system.ntp.server="$NTP_SERVER" 2>/dev/null || true
uci commit system
log_info "NTP сервер добавлен: $NTP_SERVER"

# =============================================================================
# ШАГ 6: Split tunneling — российские IP напрямую
# =============================================================================
log_info "=== ШАГ 6: Split tunneling ==="

mkdir -p /etc/antifilter

cat > /etc/antifilter/update.sh << 'UPDATEEOF'
#!/bin/sh
logger -t antifilter "Updating RU subnet list..."

curl -s https://www.ipdeny.com/ipblocks/data/countries/ru.zone \
    -o /etc/antifilter/ru_subnets.lst

if [ ! -s /etc/antifilter/ru_subnets.lst ]; then
    logger -t antifilter "ERROR: Failed to download subnet list"
    exit 1
fi

(
echo "table inet fw4 {"
echo "  set ru_direct {"
echo "    type ipv4_addr;"
echo "    flags interval;"
echo "    elements = {"
sed '$!s/$/, /' /etc/antifilter/ru_subnets.lst | tr -d '\n'
echo ""
echo "    }"
echo "  }"
echo "}"
) > /etc/antifilter/ru_nft.txt

logger -t antifilter "Done: $(wc -l < /etc/antifilter/ru_subnets.lst) subnets"
UPDATEEOF

chmod +x /etc/antifilter/update.sh

log_info "Скачиваю список российских IP..."
/etc/antifilter/update.sh

if ! grep -q "antifilter" /etc/crontabs/root 2>/dev/null; then
    echo "0 4 * * * /etc/antifilter/update.sh" >> /etc/crontabs/root
fi
/etc/init.d/cron enable 2>/dev/null || true
/etc/init.d/cron restart
log_info "Автообновление: ежедневно в 4:00"

# =============================================================================
# ШАГ 7: Hotplug скрипт (фикс RouteRich + восстановление правил после reboot)
# =============================================================================
log_info "=== ШАГ 7: Hotplug скрипт ==="

cat > /etc/hotplug.d/iface/99-awg-fix << HOTPLUGEOF
#!/bin/sh
logger -t awg-fix "hotplug: ACTION=\$ACTION INTERFACE=\$INTERFACE"

if [ "\$ACTION" = "ifup" ] && [ "\$INTERFACE" = "$AWG_IFACE" ]; then
    sleep 3
    logger -t awg-fix "Starting $AWG_IFACE post-up setup..."

    # Фикс RouteRich: nftables не генерирует masquerade/forward для AWG
    nft add rule inet fw4 srcnat oifname "$AWG_IFACE" jump srcnat_${AWG_IFACE} 2>/dev/null
    nft add rule inet fw4 accept_to_${AWG_IFACE} oifname "$AWG_IFACE" counter accept 2>/dev/null

    # Загружаем nftables set с российскими подсетями
    if [ ! -f /etc/antifilter/ru_nft.txt ]; then
        /etc/antifilter/update.sh
    fi
    nft -f /etc/antifilter/ru_nft.txt 2>/dev/null

    # Трафик к российским IP → метка 0x1
    nft add rule inet fw4 mangle_prerouting \
        iifname "br-lan" ip daddr @ru_direct meta mark set 0x1 2>/dev/null

    # Помеченный трафик → напрямую через WAN (таблица 100)
    ip rule add fwmark 0x1 table 100 priority 100 2>/dev/null
    ip route add default via $WAN_GW dev eth1 table 100 2>/dev/null

    logger -t awg-fix "$AWG_IFACE setup complete"
fi
HOTPLUGEOF

chmod +x /etc/hotplug.d/iface/99-awg-fix
log_info "Hotplug скрипт создан"

# =============================================================================
# Применяем настройки
# =============================================================================
log_info "Применяю настройки..."
/etc/init.d/network reload  2>/dev/null || true
/etc/init.d/firewall reload 2>/dev/null || true

echo ""
echo "============================================================"
log_info "Установка завершена!"
echo ""
echo "  Интерфейс : $AWG_IFACE"
echo "  Endpoint  : $ENDPOINT_HOST:$ENDPOINT_PORT"
echo "  Tunnel IP : $TUNNEL_IP"
echo "  WAN шлюз  : $WAN_GW"
echo "  NTP       : $NTP_SERVER"
echo ""
log_warn "Перезагрузите роутер для применения всех настроек:"
echo ""
echo "  reboot"
echo "============================================================"
