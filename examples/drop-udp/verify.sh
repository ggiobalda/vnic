#!/usr/bin/env bash
# Uso: sudo ./verify.sh [ebpf|p4]     (default: ebpf)

set -euo pipefail

EXAMPLE_DIR="$(dirname "$0")"
VNIC="$EXAMPLE_DIR/../../scripts/vnic.sh"
TRAFFIC="$EXAMPLE_DIR/../../scripts/traffic.sh"
NAME="drop-udp"

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
        FILE="$EXAMPLE_DIR/drop_udp.c"
        ;;
    p4)
        OPTION="--attach-p4"
        FILE="$EXAMPLE_DIR/drop_udp.p4"
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
FILTER="(icmp or udp) and host 192.168.100.2"

log "cattura su tap0 e tap1 per ${CAPTURE_SECONDS}s"
# -Z root: tcpdump non cede i privilegi, così può scrivere in PCAP_DIR
timeout "$CAPTURE_SECONDS" tcpdump -i tap0 -n -Z root -w "$PCAP_DIR/tap0.pcap" "$FILTER" &>/dev/null &
PID_TAP0=$!
timeout "$CAPTURE_SECONDS" tcpdump -i tap1 -n -Z root -w "$PCAP_DIR/tap1.pcap" "$FILTER" &>/dev/null &
PID_TAP1=$!
sleep 1 # evita race condition fra tcpdump e traffico

log "ICMP: 5 echo request ns0 -> ns1 (devono passare)"
"$TRAFFIC" icmp --count 5 >/dev/null

log "UDP: 1 pacchetto ns0 -> ns1:9999 (deve essere scartato)"
"$TRAFFIC" udp --dst-port 9999 --count 1 >/dev/null
wait "$PID_TAP0" "$PID_TAP1" || true

# ------------------------------ RISULTATO ------------------------------

ICMP_TAP0=$(count tap0 icmp)
ICMP_TAP1=$(count tap1 icmp)
UDP_TAP0=$(count tap0 udp)
UDP_TAP1=$(count tap1 udp)
log "ICMP: tap0=$ICMP_TAP0 tap1=$ICMP_TAP1 | UDP: tap0=$UDP_TAP0 tap1=$UDP_TAP1"

OK=1
# controllo risultato in base al numero di pacchetti registrati sulle tap
# 5 richieste + 5 risposte devono passare da entrambe le tap
if [[ $ICMP_TAP0 -lt 10 || $ICMP_TAP1 -lt 10 ]]; then
    log "FAIL: ICMP non ha attraversato la VM"
    OK=0
fi
# UDP deve entrare nella VM (tap0) ma non uscirne (tap1)
if [[ $UDP_TAP0 -lt 1 || $UDP_TAP1 -ne 0 ]]; then
    log "FAIL: UDP non è stato scartato dal filtro"
    OK=0
fi

if [[ $OK -eq 1 ]]; then
    log "PASS: ICMP attraversa la VM, UDP viene scartato"
else
    log "catture disponibili in $PCAP_DIR"
    exit 1
fi
