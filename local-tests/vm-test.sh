# Script per automatizzare il test manuale descritto in VM-test.md
# 
# Lo scopo di questo script è poi essere tradotto comando per comando
# in main.rs, solo che effettuare modifiche prima sullo script è più
# semplice per trovare bug rispetto al codice rust definitivo.
#
# Differenze con VM-test.md:
# - inezione di file oggetto eBPF fatta nel cloud-config
# - comandi da eseguire in VM caricati nel cloud-config
# - tcpdump solo su tap0 e tap1
#
# Differenze con main.rs saranno:
# - codice eBPF caricato dall'utente, mentre qui se ne usa uno di test
# - aggiunta di compatibilità con codice P4, che vnic traducerà in eBPF
# - rimozione dei bridge, il cui lavoro di inoltro viene fatto
#   direttamente dal daemon vnic

# stop su errori (-e), variabili non definite (-u) o errori nelle pipe (-o pipefail)
set -euo pipefail

# ------------------------------ UTILITY ------------------------------

IMG="debian-12-generic-amd64.qcow2"
SEED="seed.iso"
UD="user-data"
MD="meta-data"

SRC="my_prog.c"
OBJ="my_prog.o"

MAC0="52:54:00:12:34:56"
MAC1="52:54:00:12:34:57"

# files di appoggio per pid del processo qemu e log di qemu
QEMU_PID_FILE="/tmp/smartnic-vm.pid"
QEMU_LOG="/tmp/smartnic-vm.log"

# packet capture: tcpdump su tap0 e tap1 salvato in formato .pcap
PCAP_DIR="/tmp/smartnic-captures"
PCAP_SECONDS=8

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

# ---------------------------- FILTRO EBPF ----------------------------

compile_ebpf() {
    require_file "$SRC"
    log "comiplazione $SRC -> $OBJ"
    clang -O2 -target bpf -c "$SRC" -o "$OBJ"
}

# --------------------------------- VM ---------------------------------

generate_cloud_init() {
    require_file "$OBJ"
    log "generazione $UD e $MD"
    
    local ebpf_b64
    ebpf_b64="$(base64 -w0 "$OBJ")"

    cat > "$MD" <<EOF
instance-id: smartnic-test
local-hostname: smartnic-vm
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
  - [ ip, link, set, ens3, up ]
  - [ ip, link, set, ens4, up ]
  - [ ip, link, add, brVM, type, bridge ]
  - [ ip, link, set, brVM, up ]
  - [ ip, link, set, ens3, master, brVM ]
  - [ ip, link, set, ens4, master, brVM ]
  - [ ip, link, set, ens3, xdp, obj, /root/${OBJ}, sec, xdp ]
EOF
}

build_seed_iso() {
    log "generazione $SEED"
    xorriso -as genisoimage -output "$SEED" -volid cidata -joliet -rock "$UD" "$MD"
}

prepare_image() {
    log "disabilitazione servizio di rete systemd"
    LIBGUESTFS_BACKEND=direct virt-customize -a "$IMG" \
        --run-command 'systemctl mask systemd-networkd-wait-online.service'
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

    log "attesa boot e applicazione cloud-init (~20s)"
    sleep 20
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
    # pulizia pre test
    mkdir -p "$PCAP_DIR"
    sudo rm -f "$PCAP_DIR"/tap0.pcap "$PCAP_DIR"/tap1.pcap

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
    if [[ "$icmp_tap0" -lt 5 || "$icmp_tap1" -lt 5 ]]; then
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
        log "vedi $CAP_DIR/tap0.pcap e $CAP_DIR/tap1.pcap per il dettaglio"
        exit 1
    fi
}

# ---------------------------- ENTRY POINT ----------------------------
case "${1:-}" in
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
        log "infrastruttura e VM pronte; esegui './vm-test.sh run' per testare" 
        ;;
    
    run)
        run_test
        ;;

    status)
        ;;
    
    down)
        ;;
    
    *)
        echo "Uso: $0 {up|run|status|down}"
        exit 1
        ;;
esac