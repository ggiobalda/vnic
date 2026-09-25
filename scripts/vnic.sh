#!/usr/bin/env bash
# vnic.sh — emulazione di una SmartNIC tramite VM QEMU
#
# Crea due namespace (ns0, ns1) collegati attraverso una VM Debian e,
# opzionalmente, carica un programma eBPF o P4 come XDP sull'interfaccia di ingresso della VM (ens3).
#
# vnic si occupa SOLO dell'infrastruttura e del caricamento del programma.
# La generazione del traffico e la verifica del comportamento del programma
# sono lasciate all'utente (vedi examples/).

# stop su errori (-e), variabili non definite (-u) o errori nelle pipe (-o pipefail)
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(dirname "$0")"

# ----------------------------- COSTANTI -----------------------------

# cartella dei file generati/scaricati (gitignored)
# realpath -m rende il percorso assoluto, anche se la cartella non esiste ancora
TESTBED_DIR="$(realpath -m "$SCRIPT_DIR/../testbed")"

# immagine base Debian
BASE_IMG="$TESTBED_DIR/debian-12-generic-amd64.qcow2"
BASE_IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"

# file temporanei, creati da 'up' e rimossi da 'down'
IMG="$TESTBED_DIR/debian-overlay.qcow2"
SEED="$TESTBED_DIR/seed.iso"
MD="$TESTBED_DIR/meta-data"
NC="$TESTBED_DIR/network-config"
UD="$TESTBED_DIR/user-data"
OBJ_OUT="$TESTBED_DIR/obj.o"
P4_C_OUT="$TESTBED_DIR/code-p4.c"

# indirizzi MAC delle interfacce della VM
MAC0="52:54:00:12:34:56"
MAC1="52:54:00:12:34:57"

# timeout (s) per l'attesa del boot della VM
BOOT_TIMEOUT=60

# ------------------------------ UTILITY ------------------------------

log() {
    echo "[vnic] $*"
}

die() {
    echo "[vnic] errore: $*" >&2
    exit 1
}

require_root() {
    # id -u stampa uid
    if [[ "$(id -u)" -ne 0 ]]; then
        die "'$1' richiede privilegi di root, usa sudo"
    fi
}

require_file() {
    if [[ ! -f "$1" ]]; then
        die "file '$1' non trovato"
    fi
}

require_cmd() {
    # command -v <comando> stampa path del comando, vuoto se questo non esiste
    if ! command -v "$1" &>/dev/null; then
        die "comando '$1' non trovato, installalo prima di continuare"
    fi
}

link_exists() {
# output del comando scartato, ci interessa solo exit status
    ip link show dev "$1" &>/dev/null
}

netns_exists() {
# con flag -q grep ritorna 1 se trova la stringa, 0 altrimenti
    ip netns list | grep -qw "$1"
}

# set file pid/log specifici per ogni istanza
set_instance_files() {
    QEMU_PID_FILE="$TESTBED_DIR/vnic-$1.pid"
    QEMU_LOG="$TESTBED_DIR/vnic-$1.log"
}

# ------------------------------- HELP -------------------------------

usage() {
    cat <<EOF
Uso: $SCRIPT_NAME <comando> [opzioni]

Comandi:
    up <nome>       Crea l'infrastruttura e avvia la VM (con programma opzionale)
    down <nome>     Ferma la VM e rimuove l'infrastruttura
    status          Mostra lo stato di infrastruttura e VM
    help            Mostra questo messaggio

Opzioni per 'up':
    --attach-ebpf <file.c|file.o>   Carica un programma eBPF
    --attach-p4   <file.p4>         Carica un programma P4, tradotto in eBPF via p4c
    -y, --yes                       Non chiedere conferma per il download dell'immagine base

Note:
    L'immagine Debian cloud deve trovarsi in testbed/debian-12-generic-amd64.qcow2; se manca, 'up' propone di scaricarla.
    Le opzioni --attach-ebpf e --attach-p4 sono mutuamente esclusive.
    Senza --attach-ebpf né --attach-p4 la VM inoltra tutti i frame senza filtrarli.

Topologia creata:
    ns0 (192.168.100.1) -- tap0 -- [VM + programma] -- tap1 -- ns1 (192.168.100.2)

Esempi:
    sudo $SCRIPT_NAME up demo --attach-ebpf examples/drop-udp/drop_udp.c
    sudo $SCRIPT_NAME up demo --attach-p4 examples/tcp-port-filter/tcp_port_filter.p4
    sudo $SCRIPT_NAME status
    sudo ip netns exec ns0 ping -c 3 192.168.100.2
    sudo $SCRIPT_NAME down demo

Vedi examples/ per filtri di prova pronti all'uso, ciascuno con un proprio README e script verify.sh per simulare traffico.
EOF
}

# --------------------------- CONTROLLI UP ---------------------------

parse_up_args() {
    NAME=""
    ATTACH_EBPF=""
    ATTACH_P4=""
    ASSUME_YES=0

    # caso senza argomenti o con opzione come primo arg
    if [[ $# -eq 0 || "$1" == -* ]]; then
        log "errore: 'up' richiede un nome" >&2
        usage
        exit 1
    fi

    NAME="$1"
    shift # scala argomenti a sx di una posizione ($2->$1, $3->$2, ...)

    # loop sugli argomenti
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --attach-ebpf)
                if [[ -n "$ATTACH_P4" ]]; then
                    die "--attach-ebpf e --attach-p4 sono mutuamente esclusivi" >&2
                else
                    ATTACH_EBPF="$2"
                    shift 2 
                fi
                ;;

            --attach-p4)
                if [[ -n "$ATTACH_EBPF" ]]; then
                    die "--attach-ebpf e --attach-p4 sono mutuamente esclusivi" >&2
                else
                    ATTACH_P4="$2"
                    shift 2
                fi 
                ;;

            -y|--yes)
                ASSUME_YES=1
                shift 
                ;;

            *)
                die "opzione sconosciuta '$1'" >&2
                usage
                exit 1 
                ;;
        esac
    done
}

check_dependencies() {
    require_cmd ip
    require_cmd qemu-system-x86_64
    require_cmd qemu-img
    require_cmd xorriso
    if [[ "$ATTACH_EBPF" == *.c ]]; then require_cmd clang; fi
    if [[ -n "$ATTACH_P4" ]]; then require_cmd p4c-ebpf; fi
    return 0
}

# controlla che ci sia una sola istanza up alla volta
check_not_running() {
    for pid_file in "$TESTBED_DIR"/vnic-*.pid; do
        if [[ -f "$pid_file" ]]; then
            if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
                die "un'istanza è già attiva ($(basename "$pid_file" .pid)); usa 'down' prima di un nuovo 'up'"
            fi
        fi
    done
}

# ------------------------------ FILTRO ------------------------------

# produce in OBJ il file oggetto eBPF da caricare nella VM
# (vuoto se l'utente non ha inserito un programma P4 o EBPF)
resolve_obj() {
    OBJ=""

    if [[ -n "$ATTACH_EBPF" ]]; then
        require_file "$ATTACH_EBPF"
        case "$ATTACH_EBPF" in
            *.o)
                log "uso file oggetto eBPF $ATTACH_EBPF"
                OBJ="$ATTACH_EBPF"
                ;;

            *.c)
                log "compilazione $ATTACH_EBPF (clang, target bpf)"
                clang -O2 -target bpf -c "$ATTACH_EBPF" -o "$OBJ_OUT"
                OBJ="$OBJ_OUT"
                ;;

            *)
                die "--attach-ebpf accetta solo file .c o .o"
                ;;

        esac

    elif [[ -n "$ATTACH_P4" ]]; then
        require_file "$ATTACH_P4"
        if [[ "$ATTACH_P4" != *.p4 ]]; then
            die "--attach-p4 accetta solo file .p4"
        fi
        compile_p4
    fi
}

compile_p4() {
    die "[DEV] Implementare compilazione P4 -> eBPF" 
}

# --------------------------- INFRASTRUTTURA ---------------------------

setup_namespace() {
    netns_exists ns"$1" || ip netns add ns"$1"
}

setup_veth() {
    if ! link_exists veth"$1"-br; then
        ip link add veth"$1" type veth peer name veth"$1"-br
        ip link set veth"$1" netns ns"$1"
        ip netns exec ns"$1" ip addr add 192.168.100."$(( $1 + 1 ))"/24 dev veth"$1"
        ip netns exec ns"$1" ip link set veth"$1" up
        ip netns exec ns"$1" ip link set lo up
    fi
}

setup_tap() {
    link_exists tap"$1" || ip tuntap add dev tap"$1" mode tap
    ip link set tap"$1" up
}

setup_host_bridge() {
    if ! link_exists br"$1"; then
        ip link add br"$1" type bridge
        ip link set br"$1" up
        ip link set tap"$1" master br"$1"
        ip link set veth"$1"-br master br"$1"
        ip link set veth"$1"-br up
    fi
}

# --------------------------------- VM ---------------------------------

# ritorna 0 se immagine già presente in testbed/, altrimenti la scarica
ensure_base_image() {
    if [[ -f "$BASE_IMG" ]]; then return 0; fi

    log "immagine base non trovata in $TESTBED_DIR"
    if [[ "$ASSUME_YES" -eq 0 ]]; then
        local answer
        read -rp "[vnic] scaricarla ora da cloud.debian.org (~400MB)? [s/N] " answer
        if [[ "$answer" != [sS] ]]; then
            die "download annullato"
        fi
    fi

    require_cmd wget
    log "download immagine base..."
    # scarico su file temporaneo: se il download si interrompe non resta un'immagine corrotta
    wget -O "$BASE_IMG.part" "$BASE_IMG_URL"
    mv "$BASE_IMG.part" "$BASE_IMG"
}

generate_cloud_init() {
    cat > "$MD" <<EOF
instance-id: smartnic-$NAME-$RANDOM
local-hostname: smartnic-vm
EOF

    # assegnamento IP statici evita che il boot resti bloccato in attesa di un DHCP
    cat > "$NC" <<EOF
version: 2
ethernets:
  ens3:
    addresses:
      - 10.0.0.1/24
  ens4:
    addresses:
      - 10.0.0.2/24
EOF

    # blocchi presenti solo se c'è un filtro da caricare
    local write_files_block=""
    local xdp_attach_cmd=""
    if [[ -n "$OBJ" ]]; then
        local obj_b64
        obj_b64="$(base64 -w0 "$OBJ")"
        write_files_block="write_files:
  - path: /root/filter.o
    encoding: b64
    content: ${obj_b64}
    permissions: '0644'"
        xdp_attach_cmd="  - ip link set ens3 xdp obj /root/filter.o sec xdp"
    fi

    cat > "$UD" <<EOF
#cloud-config
password: smartnic
chpasswd:
  expire: false
ssh_pwauth: true
${write_files_block}
runcmd:
  - ip link set ens3 up
  - ip link set ens4 up
  - ip link add brVM type bridge
  - ip link set brVM up
  - ip link set ens3 master brVM
  - ip link set ens4 master brVM
${xdp_attach_cmd}
EOF
}

build_seed_iso() {
    xorriso -as genisoimage -output "$SEED" -volid cidata -joliet -rock "$MD" "$NC" "$UD" &>/dev/null
}

prepare_image() {
    qemu-img create -F qcow2 -b "$BASE_IMG" -f qcow2 "$IMG" &>/dev/null
}

start_vm() {
    qemu-system-x86_64 \
        -enable-kvm -m 1024 -smp 2 \
        -drive file="$IMG",if=virtio \
        -drive file="$SEED",if=virtio,format=raw \
        -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
        -device virtio-net-pci,netdev=n0,mac="$MAC0" \
        -netdev tap,id=n1,ifname=tap1,script=no,downscript=no \
        -device virtio-net-pci,netdev=n1,mac="$MAC1" \
        -nographic \
        > "$QEMU_LOG" 2>&1 & # file descriptor 1 (stdout) e 2 (stderr) entrambi redirezionati in QEMU_LOG
    echo $! > "$QEMU_PID_FILE"

    # polling della VM: attendo termine cloud-init leggendo QEMU_LOG
    log "avvio VM, attesa boot e cloud-init (30s circa)..."
    local elapsed=0
    while [[ $elapsed -lt $BOOT_TIMEOUT ]]; do
        # QEMU terminato prematuramente
        if ! kill -0 "$(cat "$QEMU_PID_FILE")" 2>/dev/null; then
            die "QEMU è terminato, controlla $QEMU_LOG"
        fi
        if grep -qi "Cloud-init.*finished" "$QEMU_LOG" 2>/dev/null; then
            log "VM pronta (completato in ${elapsed}s)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    die "timeout attesa VM dopo ${BOOT_TIMEOUT}s, controlla $QEMU_LOG"
}

stop_vm() {
    # individua pid di qemu, invia SIGTERM e aspetta che termini
    if [[ -f "$QEMU_PID_FILE" ]]; then
        local pid
        pid="$(cat "$QEMU_PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            log "arresto QEMU (pid: $pid)"
            kill "$pid"
            
            # finché processo QEMU esiste rimane nel loop 
            while kill -0 "$pid" 2>/dev/null; do
                sleep 0.5;
            done
        fi
        rm -f "$QEMU_PID_FILE"
    else
        log "nessuna VM attiva da fermare"
    fi
}

# ------------------------------ PULIZIA ------------------------------

teardown() {
    log "rimozione infrastruttura host e file temporanei"

    for iface in tap0 tap1 br0 br1 veth0-br veth1-br; do
        if link_exists "$iface"; then
            ip link del "$iface"
        fi
    done

    for ns in ns0 ns1; do
        if netns_exists "$ns"; then
            ip netns del "$ns"
        fi
    done

    rm -f "$IMG" "$SEED" "$MD" "$NC" "$UD" "$OBJ_OUT" "$P4_C_OUT" "$QEMU_LOG"
}

# ------------------------------ COMANDI ------------------------------

cmd_up() {
    parse_up_args "$@"
    require_root "up"
    set_instance_files "$NAME"
    mkdir -p "$TESTBED_DIR"

    check_dependencies
    check_not_running

    ensure_base_image
    resolve_obj
    
    for i in {0,1}; do
        log "infrastruttura lato $i: ns$i (192.168.100.$((i + 1))), veth$i, br$i, tap$i"
        setup_namespace $i
        setup_veth $i
        setup_tap $i
        setup_host_bridge $i
    done

    log "preparazione VM: cloud-init, seed.iso, overlay dell'immagine base"
    generate_cloud_init
    build_seed_iso
    prepare_image
    start_vm

    log "istanza '$NAME' pronta"
    log "  programma: ${ATTACH_EBPF:-${ATTACH_P4:-nessuno, la VM inoltra tutti i frame}}"
    log "  ns0:       192.168.100.1 (trasmette)"
    log "  ns1:       192.168.100.2 (riceve)"
    log "  log VM:    $QEMU_LOG"
    log "  prova:     sudo ip netns exec ns0 ping -c 3 192.168.100.2"
    log "  stop:      sudo $0 down $NAME"
}

cmd_down() {
    if [[ $# -lt 1 ]]; then die "'down' richiede un nome"; fi
    
    NAME="$1"
    require_root "down"
    set_instance_files "$NAME"

    stop_vm
    teardown
    log "istanza '$NAME' rimossa"
}

cmd_status() {
    local found=0
    for pid_file in "$TESTBED_DIR"/vnic-*.pid; do
        if [[ -f "$pid_file" ]]; then
            found=1 
            local name pid
            name="$(basename "$pid_file" .pid)"
            name="${name#vnic-}"
            pid="$(cat "$pid_file")"
            if kill -0 "$pid" 2>/dev/null; then
                log "istanza '$name': VM in esecuzione (pid $pid)"
            else
                log "istanza '$name': VM non in esecuzione (pid file obsoleto)"
            fi
        fi
    done
    if [[ $found -eq 0 ]]; then
        log "nessuna VM in esecuzione"
    fi

    local ns_list="" iface_list=""
    for i in ns0 ns1; do
        if netns_exists "$i"; then ns_list+=" $i"; fi
    done
    for i in veth0-br br0 tap0 tap1 br1 veth1-br; do
        if link_exists "$i"; then iface_list+=" $i"; fi
    done
    log "  namespace presenti: ${ns_list:- nessuno}"
    log "  interfacce presenti:${iface_list:- nessuna}"
}

# ---------------------------- ENTRY POINT ----------------------------

case "${1:-help}" in # se $1 assente il caso default è help
    help|-h|--help)
        usage
        ;;

    up)
        shift # scarta 'up' dagli args
        cmd_up "$@"
        ;;

    down)
        shift # scarta 'down' dagli args
        cmd_down "$@"
        ;;
    
    status)
        cmd_status
        ;;
    
    *)
        log "errore: comando sconosciuto '$1'" >&2
        usage
        exit 1
        ;;
esac