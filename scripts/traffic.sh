#!/usr/bin/env bash
# traffic.sh — generazione di traffico di prova per vnic
#
# Invia pacchetti da un namespace (ns0 o ns1) verso l'altro, attraverso la VM
# creata da 'vnic.sh up'.
#
# Lo script non verifica il risultato: nping stampa i pacchetti inviati (SENT)
# e le eventuali risposte (RCVD), l'interpretazione è lasciata all'utente
# in base al filtro caricato. Per vedere cosa entra ed esce dalla VM usare
# anche tcpdump su tap0 (ingresso) e tap1 (uscita).

# stop su errori (-e), variabili non definite (-u) o errori nelle pipe (-o pipefail)
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# ------------------------------ UTILITY ------------------------------

log() {
    echo "[traffic] $*"
}

die() {
    echo "[traffic] errore: $*" >&2
    exit 1
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "servono privilegi di root, usa sudo"
    fi
}

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        die "comando '$1' non trovato, installalo prima di continuare"
    fi
}

netns_exists() {
    ip netns list | grep -qw "$1"
}

# ------------------------------- HELP -------------------------------

usage() {
    cat <<EOF
Uso: $SCRIPT_NAME <tipo> [opzioni]

Tipi di pacchetto:
    icmp            ICMP echo request (come ping)
    udp             datagrammi UDP
    tcp             segmenti TCP (di default SYN)
    arp             ARP request

Opzioni:
    --src-ip <ip>           IP sorgente nell'header del pacchetto
    --src-mac <mac>         MAC sorgente nell'header del pacchetto
    --dst-mac <mac>         MAC di destinazione
    --src-port <n>          Porta sorgente (udp, tcp)
    --dst-port <n>          Porta di destinazione (udp, tcp)
    --flags <lista>         Flag TCP separati da virgola, es. syn,ack
    --ttl <n>               TTL dell'header IP
    --payload <testo>       Contenuto del pacchetto
    --count <n>             Numero di pacchetti da inviare (default: 5)

Note:
    Richiede un'istanza vnic attiva (sudo vnic.sh up <nome>).
    Indirizzi: ns0 = 192.168.100.1 (veth0), ns1 = 192.168.100.2 (veth1).
    Se dst-mac è diverso da quella di veth1 o broadcast il pacchetto verrà scartato in ns1

Esempi:
    sudo $SCRIPT_NAME icmp
    sudo $SCRIPT_NAME udp --dst-port 9999 --payload "ciao"
    sudo $SCRIPT_NAME tcp --dst-port 8080 --flags syn --count 3
    sudo $SCRIPT_NAME icmp --ttl 1 --src-ip 10.9.9.9
    sudo $SCRIPT_NAME udp --dst-mac ff:ff:ff:ff:ff:ff --dst-port 53
EOF
}

# ------------------------------ PARSING ------------------------------

parse_args() {
    FROM="ns0"
    TO="192.168.100.2"
    IFACE="veth0"
    COUNT=5

    TYPE=""
    SRC_IP=""
    SRC_MAC=""
    DST_MAC=""
    SRC_PORT=""
    DST_PORT=""
    FLAGS=""
    TTL=""
    PAYLOAD=""

    # caso senza argomenti o con opzione come primo arg
    if [[ $# -eq 0 || "$1" == -* ]]; then
        log "errore: specificare il tipo di pacchetto" >&2
        usage
        exit 1
    fi

    TYPE="$1"
    shift

    # loop sugli argomenti: ogni opzione è seguita dal suo valore
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --src-ip)   SRC_IP="$2";   shift 2 ;;
            --src-mac)  SRC_MAC="$2";  shift 2 ;;
            --dst-mac)  DST_MAC="$2";  shift 2 ;;
            --src-port) SRC_PORT="$2"; shift 2 ;;
            --dst-port) DST_PORT="$2"; shift 2 ;;
            --flags)    FLAGS="$2";    shift 2 ;;
            --ttl)      TTL="$2";      shift 2 ;;
            --payload)  PAYLOAD="$2";  shift 2 ;;
            --count)    COUNT="$2";    shift 2 ;;

            *)
                log "errore: opzione sconosciuta '$1'" >&2
                usage
                exit 1
                ;;
        esac
    done
}

check_topology() {
    if ! netns_exists "$FROM"; then
        die "namespace $FROM assente; avvia prima vnic con 'sudo vnic.sh up <nome>'"
    fi
}


# costruisce gli argomenti di nping nell'array ARGS
build_args() {
    # -e: interfaccia di uscita; --send-eth: invia frame ethernet completi,
    # necessario per poter impostare i MAC
    ARGS=(-e "$IFACE" --send-eth -c "$COUNT")

    case "$TYPE" in
        icmp) ARGS+=(--icmp) ;;
        udp)  ARGS+=(--udp) ;;
        tcp)  ARGS+=(--tcp) ;;
        arp)  ARGS+=(--arp --arp-type arp-request) ;;
        *)    die "tipo '$TYPE' non supportato (icmp, udp, tcp, arp)" ;;
    esac

    # ogni opzione viene aggiunta solo se l'utente l'ha specificata
    if [[ -n "$SRC_IP" ]];   then ARGS+=(-S "$SRC_IP"); fi
    if [[ -n "$SRC_MAC" ]];  then ARGS+=(--source-mac "$SRC_MAC"); fi
    if [[ -n "$DST_MAC" ]];  then ARGS+=(--dest-mac "$DST_MAC"); fi
    if [[ -n "$SRC_PORT" ]]; then ARGS+=(-g "$SRC_PORT"); fi
    if [[ -n "$DST_PORT" ]]; then ARGS+=(-p "$DST_PORT"); fi
    if [[ -n "$FLAGS" ]];    then ARGS+=(--flags "$FLAGS"); fi
    if [[ -n "$TTL" ]];      then ARGS+=(--ttl "$TTL"); fi
    if [[ -n "$PAYLOAD" ]];  then ARGS+=(--data-string "$PAYLOAD"); fi

    # la destinazione va per ultima
    ARGS+=("$TO")
}

# ---------------------------- ENTRY POINT ----------------------------

case "${1:-help}" in # se $1 assente il caso default è help
    help|-h|--help)
        usage
        ;;

    *)
        parse_args "$@"
        require_root
        require_cmd nping
        check_topology
        build_args

        log "da $FROM ($IFACE) verso $TO"
        log "comando: ip netns exec $FROM nping ${ARGS[*]}"
        ip netns exec "$FROM" nping "${ARGS[@]}"
        ;;
esac