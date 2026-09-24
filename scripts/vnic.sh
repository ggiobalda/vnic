#!/usr/bin/env bash
# vnic.sh — emulazione di una SmartNIC tramite VM QEMU
#
# Crea due namespace (ns0, ns1) collegati attraverso una VM Debian:
#
#   ns0 (veth0) -- veth0-br -- br0 -- tap0 == [VM: ens3 -> brVM -> ens4] == tap1 -- br1 -- veth1-br -- (veth1) ns1
#
# e, opzionalmente, carica un programma eBPF P4 come XDP sull'interfaccia di ingresso della VM (ens3).
#
# vnic si occupa SOLO dell'infrastruttura e del caricamento del programma.
# La generazione del traffico e la verifica del comportamento del programma
# sono lasciate all'utente (vedi examples/).

# stop su errori (-e), variabili non definite (-u) o errori nelle pipe (-o pipefail)
set -euo pipefail

# ------------------------------ UTILITY ------------------------------

BASE_IMG="debian-12-generic-amd64.qcow2"
IMG="debian-overlay.qcow2"
SEED="seed.iso"
MD="meta-data"
NC="network-config"
UD="user-data"

MAC0="52:54:00:12:34:56"
MAC1="52:54:00:12:34:57"

log() {
    echo "[vm-test] $*"
}

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "errore: '$1' non trovato"
        exit 1
    fi
}

# output del comando scartato, ci interessa solo exit status
link_exists() {
    ip link show dev "$1" &>/dev/null
}

# con flag -q grep ritorna 1 se trova la stringa, 0 altrimenti
netns_exists() {
    ip netns list | grep -qw "$1"
}

# --------------------------- INFRASTRUTTURA ---------------------------

setup_namespace() {
    log "creazione namespace ns$1"
    netns_exists ns"$1" || sudo ip netns add ns"$1"
}

setup_veth() {
    log "creazione veth$1, posizionamento e assegnamento IP"
    if ! link_exists veth"$1"-br; then
        sudo ip link add veth"$1" type veth peer name veth"$1"-br
        sudo ip link set veth"$1" netns ns"$1"
        sudo ip netns exec ns"$1" ip addr add 192.168.100."$(( $1 + 1 ))"/24 dev veth"$1"
        sudo ip netns exec ns"$1" ip link set veth"$1" up
        sudo ip netns exec ns"$1" ip link set lo up
    fi
}

setup_tap() {
    log "creazione tap$1"
    link_exists tap"$1" || sudo ip tuntap add dev tap"$1" mode tap user "$(whoami)"
    sudo ip link set tap"$1" up
}

setup_host_bridge() {
    log "creazione br$1"
    if ! link_exists br"$1"; then
        sudo ip link add br"$1" type bridge
        sudo ip link set br"$1" up
        sudo ip link set tap"$1" master br"$1"
        sudo ip link set veth"$1"-br master br"$1"
        sudo ip link set veth"$1"-br up
    fi
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
    ns0 (192.168.100.1) -- tap0 -- [VM + filtro] -- tap1 -- ns1 (192.168.100.2)

Esempi:
    sudo $SCRIPT_NAME up demo --attach-ebpf examples/drop-udp/drop_udp.c
    sudo $SCRIPT_NAME up demo --attach-p4 examples/tcp-port-filter/filter.p4
    sudo $SCRIPT_NAME status
    sudo ip netns exec ns0 ping -c 3 192.168.100.2
    sudo $SCRIPT_NAME down demo

Vedi examples/ per filtri di prova pronti all'uso, ciascuno con un proprio README e script verify.sh per simulare traffico.
EOF
}

# ---------------------------- FILTRO EBPF ----------------------------

compile_ebpf() {
    require_file "$SRC"
    log "comiplazione $SRC -> $OBJ"
    clang -O2 -target bpf -c "$SRC" -o "$OBJ"
}

# --------------------------------- VM ---------------------------------

generate_cloud_init() {
    require_file "$OBJ"
    log "generazione $MD, $NC e $UD"
    
    local ebpf_b64
    ebpf_b64="$(base64 -w0 "$OBJ")"

    cat > "$MD" <<EOF
instance-id: smartnic-test-$RANDOM
local-hostname: smartnic-vm
EOF

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

    cat > "$UD" <<EOF
#cloud-config
password: smartnic
chpasswd:
  expire: false
ssh_pwauth: true
write_files:
  - path: /root/${OBJ}
    encoding: b64
    content: ${ebpf_b64}
    permissions: '0644'
runcmd:
  - ip link set ens3 up
  - ip link set ens4 up
  - ip link add brVM type bridge
  - ip link set brVM up
  - ip link set ens3 master brVM
  - ip link set ens4 master brVM
  - ip link set ens3 xdp obj /root/${OBJ} sec xdp
EOF
}

build_seed_iso() {
    log "generazione $SEED"
    xorriso -as genisoimage -output "$SEED" -volid cidata -joliet -rock "$MD" "$NC" "$UD" &>/dev/null
}

prepare_image() {
    require_file "$BASE_IMG"
    log "creazione overlay immagine VM"
    qemu-img create -F qcow2 -b "$BASE_IMG" -f qcow2 "$IMG" &>/dev/null
}

start_vm() {
    require_file "$IMG"
    require_file "$SEED"

    # controllo se esiste già VM in esecuzione con kill -0
    if [[ -f "$QEMU_PID_FILE" ]] && kill -0 "$(cat "$QEMU_PID_FILE")" 2>/dev/null; then
        log "una VM risulta già in esecuzione (pid $(cat "$QEMU_PID_FILE")); usa 'down' prima di riusare 'up'"
        exit 1
    fi

    # file descriptor 1 (stdout) e 2 (stderr) entrambi redirezionati in QEMU_LOG
    log "avvio QEMU in background (log: $QEMU_LOG)"
    qemu-system-x86_64 \
        -enable-kvm -m 1024 -smp 2 \
        -drive file="$IMG",if=virtio \
        -drive file="$SEED",if=virtio,format=raw \
        -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
        -device virtio-net-pci,netdev=n0,mac="$MAC0" \
        -netdev tap,id=n1,ifname=tap1,script=no,downscript=no \
        -device virtio-net-pci,netdev=n1,mac="$MAC1" \
        -nographic \
        > "$QEMU_LOG" 2>&1 &
    echo $! > "$QEMU_PID_FILE"

    # polling della VM: attendo termine cloud-init leggendo QEMU_LOG
    log "attesa completamento boot e cloud-init (30s circa)..."
    local timeout=40
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if grep -qi "Cloud-init.*finished" "$QEMU_LOG" 2>/dev/null; then
            log "VM pronta (completato in ${elapsed}s)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    log "errore: timeout attesa VM dopo ${timeout}s. Controlla $QEMU_LOG"
    exit 1
}

stop_vm() {
    # individua pid di qemu, invia SIGTERM e aspetta che termini
    if [[ -f "$QEMU_PID_FILE" ]]; then
        local pid
        pid="$(cat "$QEMU_PID_FILE")"
        if kill -0 "$pid" 2>/dev/null; then
            log "arresto QEMU (pid: $pid)"
            kill "$pid"
            wait "$pid" 2>/dev/null || true
        fi
        rm -f "$QEMU_PID_FILE"
    else
        log "nessuna VM attiva da fermare"
    fi
}

# ----------------------------- ESECUZIONE -----------------------------

run_test() {
    mkdir -p "$PCAP_DIR"
    local filter="(icmp or udp) and (host 192.168.100.1 or host 192.168.100.2)"

    # tcpdump su tap0 e tap1 con filtro su tipo di pacchetto e host
    # output salvato in apposita directory
    log "avvio cattura su tap0 e tap1 per ${PCAP_SECONDS}s"
    timeout "${PCAP_SECONDS}" sudo tcpdump -i tap0 -n "$filter" -w "$PCAP_DIR"/tap0.pcap &
    local pid_tap0=$!
    timeout "${PCAP_SECONDS}" sudo tcpdump -i tap1 -n "$filter" -w "$PCAP_DIR"/tap1.pcap &
    local pid_tap1=$!
    sleep 1 # evita race condition di tcpdump con ping

    log "ping ICMP ns0 -> ns1"
    sudo ip netns exec ns0 ping -c 5 -I veth0 192.168.100.2 || true

    log "traffico UDP ns0 -> ns1 (deve essere scartato dal filtro)"
    ( sudo ip netns exec ns1 timeout 3 nc -u -l 9999 & ) # in una subshell avvio in background il listener
    sleep 0.5 # evita race condition del listener con sender
    echo "test" | sudo ip netns exec ns0 nc -u -w1 -s 192.168.100.1 192.168.100.2 9999 || true

    wait "$pid_tap0" "$pid_tap1" 2>/dev/null || true # attende termine dei due tcpdump

    # output del test: numero di righe dei file pcap con icmp e udp (wc -l conta le righe)
    local icmp_tap0 icmp_tap1 udp_tap0 udp_tap1
    icmp_tap0=$(sudo tcpdump -r "$PCAP_DIR/tap0.pcap" -n icmp 2>/dev/null | wc -l)
    icmp_tap1=$(sudo tcpdump -r "$PCAP_DIR/tap1.pcap" -n icmp 2>/dev/null | wc -l)
    udp_tap0=$(sudo tcpdump -r "$PCAP_DIR/tap0.pcap" -n udp 2>/dev/null | wc -l)
    udp_tap1=$(sudo tcpdump -r "$PCAP_DIR/tap1.pcap" -n udp 2>/dev/null | wc -l)
    log "risultati: ICMP tap0=$icmp_tap0 tap1=$icmp_tap1 | UDP tap0=$udp_tap0 tap1=$udp_tap1"

    # controllo risultato in base al numero di pacchetti registrati sulle tap
    local ok=1
    if [[ "$icmp_tap0" -lt 10 || "$icmp_tap1" -lt 10 ]]; then
        log "FAIL: ICMP non ha attraversato la VM come atteso"
        ok=0
    fi
    if [[ "$udp_tap0" -lt 1 || "$udp_tap1" -ne 0 ]]; then
        log "FAIL: UDP non è stato droppato come atteso"
        ok=0
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "PASS: ICMP attraversa la VM, UDP viene droppato dal filtro XDP"
    else
        log "vedi $PCAP_DIR/tap0.pcap e $PCAP_DIR/tap1.pcap per il dettaglio"
        exit 1
    fi
}

# ------------------------------ PULIZIA ------------------------------

teardown() {
    log "rimozione infrastruttura host"
    link_exists tap0 && sudo ip link del tap0 || true
    link_exists tap1 && sudo ip link del tap1 || true
    link_exists br0 && sudo ip link del br0 || true
    link_exists br1 && sudo ip link del br1 || true
    link_exists veth0-br && sudo ip link del veth0-br || true
    link_exists veth1-br && sudo ip link del veth1-br || true
    netns_exists ns0 && sudo ip netns del ns0 || true
    netns_exists ns1 && sudo ip netns del ns1 || true
    rm -f  "$IMG" "$SEED" "$MD" "$NC" "$UD" "$OBJ"
    sudo rm -f "$PCAP_DIR"/tap0.pcap "$PCAP_DIR"/tap1.pcap
}

status() {
    if [[ -f "$QEMU_PID_FILE" ]] && kill -0 "$(cat "$QEMU_PID_FILE")" 2>/dev/null; then
        log "VM in esecuzione, pid: $(cat "$QEMU_PID_FILE")"
    else
        log "Nessuna VM in esecuzione"
    fi

    for i in ns0 ns1; do
        if netns_exists "$i"; then
            log "namespace $i presente"
        else
            log "namespace $i assente"
        fi
    done

    for i in veth0-br br0 tap0 tap1 br1 veth1-br; do
        if link_exists "$i"; then
            log "interfaccia $i presente"
        else
            log "interfaccia $i assente"
        fi
    done
}

# ---------------------------- ENTRY POINT ----------------------------
case "${1:-}" in
    help|-h|--help)
        usage
        ;;

    up)
        compile_ebpf
        setup_namespace 0
        setup_namespace 1
        setup_veth 0
        setup_veth 1
        setup_tap 0
        setup_tap 1
        setup_host_bridge 0
        setup_host_bridge 1
        generate_cloud_init
        build_seed_iso
        prepare_image
        start_vm
        log "infrastruttura e VM pronte" 
        ;;

    down)
        stop_vm
        teardown
        log "pulizia completata"
        ;;
    
    status)
        status
        ;;
    
    *)
        echo "Uso: $0 {up|run|status|down}"
        exit 1
        ;;
esac