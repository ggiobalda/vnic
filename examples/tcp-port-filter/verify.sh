#!/usr/bin/env bash
# Uso: sudo ./verify.sh [ebpf|p4]     (default: ebpf)

set -euo pipefail

EXAMPLE_DIR="$(dirname "$0")"
VNIC="$EXAMPLE_DIR/../../scripts/vnic.sh"
TRAFFIC="$EXAMPLE_DIR/../../scripts/traffic.sh"
NAME="tcp-port-filter"

# deve coincidere con BLOCKED_PORT in tcp_port_filter.c
BLOCKED_PORT=8080
ALLOWED_PORT=9090

# pacchetti catturati
PCAP_DIR="/tmp/vnic-verify-$NAME"
CAPTURE_SECONDS=12

log() {
    echo "[verify] $*"
}

# conta i pacchetti di una cattura che corrispondono a un filtro tcpdump
count() {
    tcpdump -r "$PCAP_DIR/$1.pcap" -n "$2" 2>/dev/null | wc -l
}

if [[ "$(id -u)" -ne 0 ]]; then
    echo "errore: serve root, usa sudo" >&2
    exit 1
fi

# scelta della versione del filtro
case "${1:-ebpf}" in
    ebpf)
        OPTION="--attach-ebpf"
        FILE="$EXAMPLE_DIR/tcp_port_filter.c"
        ;;
    p4)
        OPTION="--attach-p4"
        FILE="$EXAMPLE_DIR/tcp_port_filter.p4"
        ;;
    *)
        echo "uso: $0 [ebpf|p4]" >&2
        exit 1
        ;;
esac

# ------------------------------ SETUP ------------------------------

log "avvio vnic con $FILE"
"$VNIC" up "$NAME" "$OPTION" "$FILE"

# al termine dello script o in caso di errore esegue 'down'
trap '"$VNIC" down "$NAME"' EXIT

# ------------------------------ TRAFFICO ------------------------------

mkdir -p "$PCAP_DIR"
FILTER="tcp and host 192.168.100.2"

log "cattura su tap0 e tap1 per ${CAPTURE_SECONDS}s"
# -Z root: tcpdump non cede i privilegi, così può scrivere in PCAP_DIR
timeout "$CAPTURE_SECONDS" tcpdump -i tap0 -n -Z root -w "$PCAP_DIR/tap0.pcap" "$FILTER" &>/dev/null &
PID_TAP0=$!
timeout "$CAPTURE_SECONDS" tcpdump -i tap1 -n -Z root -w "$PCAP_DIR/tap1.pcap" "$FILTER" &>/dev/null &
PID_TAP1=$!
sleep 1 # evita race condition fra tcpdump e traffico

log "TCP: 3 SYN ns0 -> ns1:$ALLOWED_PORT (devono passare)"
"$TRAFFIC" tcp --dst-port "$ALLOWED_PORT" --count 3 >/dev/null

log "TCP: 3 SYN ns0 -> ns1:$BLOCKED_PORT (devono essere scartati)"
"$TRAFFIC" tcp --dst-port "$BLOCKED_PORT" --count 3 >/dev/null
wait "$PID_TAP0" "$PID_TAP1" || true

# ------------------------------ RISULTATO ------------------------------

ALLOWED_TAP0=$(count tap0 "tcp dst port $ALLOWED_PORT")
ALLOWED_TAP1=$(count tap1 "tcp dst port $ALLOWED_PORT")
BLOCKED_TAP0=$(count tap0 "tcp dst port $BLOCKED_PORT")
BLOCKED_TAP1=$(count tap1 "tcp dst port $BLOCKED_PORT")
log "porta $ALLOWED_PORT: tap0=$ALLOWED_TAP0 tap1=$ALLOWED_TAP1 | porta $BLOCKED_PORT: tap0=$BLOCKED_TAP0 tap1=$BLOCKED_TAP1"

OK=1
# controllo risultato in base al numero di pacchetti registrati sulle tap
# i SYN verso la porta consentita devono passare da entrambe le tap
if [[ $ALLOWED_TAP0 -lt 3 || $ALLOWED_TAP1 -lt 3 ]]; then
    log "FAIL: TCP verso la porta $ALLOWED_PORT non ha attraversato la VM"
    OK=0
fi
# i SYN verso la porta bloccata devono entrare nella VM (tap0) ma non uscirne (tap1)
if [[ $BLOCKED_TAP0 -lt 1 || $BLOCKED_TAP1 -ne 0 ]]; then
    log "FAIL: TCP verso la porta $BLOCKED_PORT non è stato scartato dal filtro"
    OK=0
fi

if [[ $OK -eq 1 ]]; then
    log "PASS: porta $ALLOWED_PORT raggiungibile, porta $BLOCKED_PORT bloccata"
else
    log "catture disponibili in $PCAP_DIR"
    exit 1
fi
