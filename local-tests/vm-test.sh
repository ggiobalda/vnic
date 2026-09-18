# Script per automatizzare il test manuale descritto in VM-test.md
# 
# Lo scopo di questo script è poi essere tradotto comando per comando
# in main.rs, solo che effettuare modifiche prima sullo script è più
# semplice per trovare bug rispetto al codice rust definitivo.
#
# Differenze con main.rs saranno:
# - codice eBPF caricato dall'utente, mentre qui se ne usa uno di test
# - aggiunta di compatibilità con codice P4, che vnic traducerà in eBPF
# - rimozione dei bridge, il cui lavoro di inoltro viene fatto
#   direttamente dal daemon vnic

# ------------------------------ UTILITY ------------------------------

IMG="debian-12-generic-amd64.qcow2"
SEED="seed.iso"
UD="user-data"
MD="meta-data"

SRC="my_prog.c"
OBJ="my_prog.o"

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
    if !link_exists veth"$1"-br; then
        sudo ip link add veth"$1" type veth peer name veth"$1"-br
        sudo ip link set veth"$1" netns ns"$1"
        sudo ip netns exec ns"$1" ip addr add 192.168.100."$1"/24 dev veth"$1"
        sudo ip netns exec ns"$1" ip link set veth"$1" up
        sudo ip netns exec ns"$1" ip link set lo up
    fi
}

setup_tap() {
    log "creazione tap$1"
    link_exists tap"$1" || sudo up tuntap add dev tap"$1" mode tap user "$(whoami)"
    sudo ip link set tap"$1" up
}

setup_host_bridge() {
    log "creazione br$1"
    if !link_exists br"$1"; then
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

# ---------------------------- ENTRY POINT ----------------------------
case "${1:-}" in
    up)
        compile_ebpf
        setup_namespace 1
        setup_namespace 2
        setup_veth 1
        setup_veth 2
        setup_tap 1
        setup_tap 2
        setup_host_bridge 1
        setup_host_bridge 2
        ;;
    
    run)
        ;;

    status)
        ;;
    
    down)
        ;;
    
    *)
        echo "Uso: $0 {up|test|status|down}"
        exit 1
        ;;
esac