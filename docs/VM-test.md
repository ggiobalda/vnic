# Introduzione
Questo test serve a simulare l'infrastruttura e la VM utilizzate per emulare una smartNIC. L'intento è quello di tradurre questo test manuale in una espansione del tool **vnic**. Nel test viene utilizzato un semplice programma eBPF che scarta i paccchetti UDP per testare se la VM esegue correttamente la logica di rete.

# Architettura
L'infrastruttura di rete utilizzate per testare l'inoltro di pacchetti attraverso una VM, visualizzabile tramite un grafico di flusso in `docs/smartnic_packet_path.svg`, è così formata:
- due **network namespace** (`ns0` e `ns1`), funzionalità del kernel che crea una copia isolata dello stack di rete. Questi servono a simulare due calcolatori distinti, ognuno con proprie interfacce, indirizzi IP, etc. Il primo rappresenta il trasmettitore, il secondo il ricevitore.
- due **veth pair** (`veth0`-`veth0-br` e `veth1`-`veth1-br`), ogni coppia rappresenta i due capi di un cavo ethernet virtuale. Servono a collegare i namespaces isolati col namespace di default, quello dell'host che esegue vnic.
- due **bridge software** (`br0` e `br1`), rappresentano degli switch e servono a inoltrare i pacchetti fra VM e host, che a sua volta inoltra/riceve dai namespaces. Questi componenti sono utili solo per questo test, in quanto svolgo essenzialmente lo stesso compito della funzione `forward`.
- due **TAP devices** (`tap0` e `tap1`), interfacce virtuali su cui un programma in userspace può leggere/scrive frame ethernet grezzi. Sono il punto di aggancio per l'hypervisor QEMU per poter comunicare con la VM.
- due **interfacce di rete** (`ens3` e `ens4`), si trovato all'interno della VM e corrispondo ai due TAP a cui è collegato QEMU. Il nome è scelto arbitrariamente dal sistema utilizzato (in questo caso Debian).
- un **bridge software** (`brVM`), collega internamente alla VM le due interfacce `ens3` e `ens4`.

# Realizzazione
## Infrastruttura
Innanzitutto è necessario realizzare l'infrastruttura sopra spiegata.

#### 1. Creazione namespaces
```bash
sudo ip netns add ns0
sudo ip netns add ns1
```

#### 2. Creazione veth pairs
```bash
sudo ip link add veth0 type veth peer name veth0-br
sudo ip link add veth1 type veth peer name veth1-br
```

#### 3. Posizionamento capi veth pairs nei namespaces
```bash
sudo ip link set veth0 netns ns0
sudo ip link set veth1 netns ns1
```

#### 4. Assegnamento IP e attivazione interfacce nei namespaces
Il comando `ip netns exec [namespace-name]` permette di eseguire un comando all'interno del namespace scelto. I comandi senza esso vengono eseguiti nel namespace default dell'host, quello in cui sono posizionati `vethX-br` e `tapX`.
```bash
sudo ip netns exec ns0 ip addr add 192.168.100.1/24 dev veth0
sudo ip netns exec ns0 ip link set veth0 up
sudo ip netns exec ns0 ip link set lo up
```
```bash
sudo ip netns exec ns1 ip addr add 192.168.100.2/24 dev veth1
sudo ip netns exec ns1 ip link set veth1 up
sudo ip netns exec ns1 ip link set lo up
```

#### 5. Creazione e attivazione tap devices
Il comando `ip tuntap` serve a gestire queste interfacce particolari usate per tunnelling, che possono essere di due tipi:
+ `tun`, lavora a livello di rete
+ `tap`, lavora a livello data-link (frame ethernet)
```bash
sudo ip tuntap add dev tap0 mode tap user $(whoami)
sudo ip tuntap add dev tap1 mode tap user $(whoami)
sudo ip link set tap0 up
sudo ip link set tap1 up
```

#### 6. Creazione e attivazione dei bridge software
+ `br0` collega `veth0-br` (uscita `ns0`) con `tap0` (ingresso VM)
+ `br1` collega `tap1` (uscita VM) con `veth1-br` (ingresso `ns1`)
```bash
sudo ip link add br0 type bridge
sudo ip link set br0 up
sudo ip link set tap0 master br0
sudo ip link set veth0-br master br0
sudo ip link set veth0-br up
```
```bash
sudo ip link add br1 type bridge
sudo ip link set br1 up
sudo ip link set tap1 master br1
sudo ip link set veth1-br master br1
sudo ip link set veth1-br up
```

## Filtro eBPF
Il filtro che verrà eseguito nella VM tramite XDP è scritto in C e compilato in bytecode eBPF con `clang`.

#### 1. Codice sorgente
Il programma droppa i pacchetti UDP e lascia passare tutto il resto (incluso ICMP, usato più avanti per il test). Creare un file contenente questo codice.
```c
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>

SEC("xdp")
int drop_udp(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    struct iphdr *ip = data + sizeof(*eth);

    if ((void *)(eth + 1) > data_end ||
        (void *)(ip + 1) > data_end)
        return XDP_PASS;

    return eth->h_proto == __constant_htons(ETH_P_IP) &&
           ip->protocol == IPPROTO_UDP
           ? XDP_DROP
           : XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
```

#### 2. Compilazione
Serve `clang` con target BPF, più gli header di `libbpf`.
```bash
clang -O2 -target bpf -c my_prog.c -o my_prog.o
```

Verifica facoltativa del bytecode generato:
```bash
llvm-objdump -S my_prog.o
```

Il cui risultato dovrebbe essere:
```bash
my_prog.o:	file format elf64-bpf

Disassembly of section xdp:

0000000000000000 <drop_udp>:
       0:	b4 00 00 00 02 00 00 00	w0 = 0x2
       1:	61 12 00 00 00 00 00 00	w2 = *(u32 *)(r1 + 0x0)
       2:	61 11 04 00 00 00 00 00	w1 = *(u32 *)(r1 + 0x4)
       3:	bf 23 00 00 00 00 00 00	r3 = r2
       4:	07 03 00 00 0e 00 00 00	r3 += 0xe
       5:	2d 13 0c 00 00 00 00 00	if r3 > r1 goto +0xc <L0>
       6:	bf 23 00 00 00 00 00 00	r3 = r2
       7:	07 03 00 00 22 00 00 00	r3 += 0x22
       8:	2d 13 09 00 00 00 00 00	if r3 > r1 goto +0x9 <L0>
       9:	71 21 0c 00 00 00 00 00	w1 = *(u8 *)(r2 + 0xc)
      10:	71 23 0d 00 00 00 00 00	w3 = *(u8 *)(r2 + 0xd)
      11:	64 03 00 00 08 00 00 00	w3 <<= 0x8
      12:	4c 13 00 00 00 00 00 00	w3 |= w1
      13:	56 03 04 00 08 00 00 00	if w3 != 0x8 goto +0x4 <L0>
      14:	71 21 17 00 00 00 00 00	w1 = *(u8 *)(r2 + 0x17)
      15:	b4 00 00 00 01 00 00 00	w0 = 0x1
      16:	16 01 01 00 11 00 00 00	if w1 == 0x11 goto +0x1 <L0>
      17:	b4 00 00 00 02 00 00 00	w0 = 0x2
<L0>:
      18:	95 00 00 00 00 00 00 00	exit
```

## VM
Per realizzare la VM ho scelto di usare l'hypervisor QEMU, data la semplicità di gestione e leggerezza. Nella VM gira il sistema Debian 12, ed in particolare si usa l'immagine base `debian-12-generic-amd64.qcow2`. Questa è un'immagine cloud,cioè fatta per essere configurata e gestita senza intervento umano: niente installer, driver di virtualizzazione già presenti e soprattutto un meccanismo (*cloud-init*) pensato per inizializzare la VM.
**cloud-init**, durante il boot, scansiona i dispositivi collegati alla VM cercandone uno con volume etichettato `cidata` (formato ISO9660 o FAT); una volta trovato, legge i file `user-data`, `meta-data` e `vendor-data` al suo interno e applica la configurazione.

#### 1. Download immagine base
```bash
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
```
#### 2. Installazione tools necessari
QEMU come hypervisor, `xorriso` per generare files.iso, `tcpdump` per sniffing dei pacchetti e `guestfs-tools` per usare il comando `virt-customize` (vedi più avanti).
```bash
sudo *** install qemu-x86 qemu-tools xorriso tcpdump guestfs-tools
# *** = apt, zypper, dnf, ....
```

#### 3. Creazione dei file di configurazione
Guida completa al link https://docs.cloud-init.io/en/latest/tutorial/qemu.html.
```bash
cat > user-data <<'EOF'
#cloud-config
password: smartnic
chpasswd:
  expire: false
ssh_pwauth: true
EOF

cat > meta-data << 'EOF'
instance-id: smartnic-test
local-hostname: smartnic-vm
EOF
```

#### 4. Generazione del disco per cloud-init
Nominato `seed.iso`, gli si assegna volume id `cidata` altrimenti cloud-init non lo legge. `joliet` e `rock` sono due estensioni al formato ISO9660 richieste da cloud-init.
```bash
xorriso -as genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data
```

L'output del comando dovrebbe essere simile a questo:
```bash
Drive current: -outdev 'stdio:seed.iso'
Media current: stdio file, overwriteable
Media status : is blank
Media summary: 0 sessions, 0 data blocks, 0 data,  239g free
xorriso : WARNING : -volid text does not comply to ISO 9660 / ECMA 119 rules
Added to ISO image: file '/user-data'='/home/gio/uni/thesis/local-tests/user-data'
xorriso : UPDATE :       1 files added in 1 seconds
Added to ISO image: file '/meta-data'='/home/gio/uni/thesis/local-tests/meta-data'
xorriso : UPDATE :       2 files added in 1 seconds
ISO image produced: 185 sectors
Written to medium : 185 sectors at LBA 0
Writing to 'stdio:seed.iso' completed successfully.
```

#### 5. Disabilitazione servizio di rete systemd e iniezione dell'eseguibile compilato
Necessario in quanto all'avvio systemd cerca invano un DHCP per assegnare indirizzo IP alle interfacce fornite alla VM, bloccando il boot. Utilizziamo inoltre lo stesso comando (`virt-customize`) per copiare il file eBPF compilato `my_prog.o` nell'immagine, così che sia disponibile al boot della VM.
```bash
LIBGUESTFS_BACKEND=direct virt-customize -a debian-12-generic-amd64.qcow2 \
  --run-command 'systemctl mask systemd-networkd-wait-online.service' \
  --copy-in my_prog.o:/root/
```

Sono necessari una manciata di secondi per eseguire l'azione, e l'output dovrebbe essere così:
```bash
[   0.0] Examining the guest ...
[  10.2] Setting a random seed
[  10.2] Running: systemctl mask systemd-networkd-wait-online.service
[  10.2] Copying: my_prog.o to /root/
[  10.3] SELinux relabelling
[  10.3] Finishing off
```

#### 6. Avvio della VM con QEMU
Per avviare la macchina applicando le impostazioni preparate prima e altre necessario il comando utilizza le seguenti opzioni:
+ `-enable-kvm`, abilita la virtualizzazione hardware della CPU
+ `-m 1024 -smp 2`, assegna 1024 MB di RAM e 2 CPU virtuali
+ `-drive file=debian...,if=virtio`, collega il disco col sistema Debian, esposto tramite l'interfaccia paravirtualizzata virtio 
+ `-drive file=seed.iso,if=virtio,format=raw`, collega il secondo disco, il seed cloud-init, in formato raw (byte grezzi, non qcow2)
+ `-netdev tap,id=n0,ifname=tap0,script=no,downscript=no`, definisce il backend di rete: collega la VM al tap0 già esistente sull'host
+ `-device virtio-net-pci,netdev=n0,mac=...`, crea la scheda di rete vista dalla VM, collegata al backend n0 appena definito
+ la seconda coppia `-netdev/-device` ripete lo stesso schema per tap1, dando alla VM una seconda scheda di rete
+ `-nographic`, forza la console seriale nel terinale dell'host

Nota che `script=no/downscript=no` dice a QEMU di non provare a creare/configurare l'interfaccia, e che l'indirizzo MAC dei dispositivi è fissato esplicitamente, altrimenti QEMU ne genera uno casuale a ogni avvio.

```bash
qemu-system-x86_64 \
  -enable-kvm -m 1024 -smp 2 \
  -drive file=debian-12-generic-amd64.qcow2,if=virtio \
  -drive file=seed.iso,if=virtio,format=raw \
  -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
  -netdev tap,id=n1,ifname=tap1,script=no,downscript=no \
  -device virtio-net-pci,netdev=n1,mac=52:54:00:12:34:57 \
  -nographic
```

#### 7. Accesso alla VM
Una volta eseguiti i passaggi precedenti dovremmo avere il terminale collegato con la VM. Dopo il boot (circa 10 secondi) effettuare il login:
+ user: `debian` (utente default)
+ password: `smartnic` (scelta in `user-data`)

#### 8. Creazione bridge interno VM
Fatto ciò va creato il bridge interno alla VM, quello che per il momento inoltra tutti i pacchetti ma che andrà sostituito con un filtro che esegue codice eBPF/P4. Verificare il nome delle interfacce nella VM con `ip a`, di default dovrebbero essere `ens3` e `ens4`.
```bash
sudo ip link set ens3 up
sudo ip link set ens4 up
sudo ip link add brVM type bridge
sudo ip link set brVM up
sudo ip link set ens3 master brVM
sudo ip link set ens4 master brVM
```

#### 9. Attacco del filtro XDP
Il file `my_prog.o` è già presente in `/root/` grazie all'iniezione fatta al punto 5. Lo agganciamo a `ens3`, l'interfaccia da cui entrano i pacchetti nella VM.
```bash
sudo ip link set ens3 xdp obj /root/my_prog.o sec xdp
ip link show ens3
```
L'output deve mostrare `prog/xdp id ...` accanto a `ens3`.

# Esecuzione
A questo punto è tutto pronto per fare un test dove si prova a spedire dei pacchetti dal namespace `ns0` a `ns1`, verificando che quelli di tipo ICMP arrivino a destinazione e quelli di tipo UDP vengano droppati dal filtro eBPF nella VM.

#### 1. Packet sniffing tap0 e tap1
Aprire un nuovo terminale ed eseguire tcpdump sull'interfaccia `tap0`, per controllare che i pacchetti entrino nella VM.
```bash
sudo tcpdump -i tap0 -n "icmp or udp"
```
Ripetere il comando in un nuovo terminale per controllare l'interfaccia `tap1`, uscita della VM.
```bash
sudo tcpdump -i tap1 -n "icmp or udp"
```

#### 2. Packet sniffing brVM
Per essere sicuri che i pacchetti attraversino la VM eseguiamo un'altro `tcpdump`, stavolta nel terminale della VM già aperto.
```bash
sudo tcpdump -i brVM -n "icmp or udp"
```

#### 3. Ping
Eseguiamo prima il comando di ping dal namespace `ns0`, attraverso la sua interfaccia `veth0`, verso l'indirizzo IP dell'interfaccia `veth1`, appartente al namespace `ns1`. Si limita a 5 pacchetti.
```bash
sudo ip netns exec ns0 ping -c 5 -I veth0 192.168.100.2 
```

#### 4. Traffico UDP (verifica del drop)
Oltre al ping, generiamo traffico UDP per verificare che questo venga effettivamente scartato dal filtro.

Aprire un terminale che funge da ricevitore ed eseguire:
```bash
sudo ip netns exec ns1 nc -u -l 9999
```

Su un altro terminale inviamo un messaggio UDP verso il ricevitore:
```bash
# terminale B (mittente, ns0)
echo "test" | sudo ip netns exec ns0 nc -u -w1 -s 192.168.100.1 192.168.100.2 9999
```

# Risultato
Il risultato corretto deve registrare, su ognuno dei 3 tcpdump, il passaggio dei 5 pacchetti ICMP, mentre il pacchetto UDP deve essere registrati solo su `tap0`.

```bash
IP 192.168.100.1 > 192.168.100.2: ICMP echo request, id 17831, seq 1, length 64
IP 192.168.100.2 > 192.168.100.1: ICMP echo reply, id 17831, seq 1, length 64
IP 192.168.100.1 > 192.168.100.2: ICMP echo request, id 17831, seq 2, length 64
IP 192.168.100.2 > 192.168.100.1: ICMP echo reply, id 17831, seq 2, length 64
IP 192.168.100.1 > 192.168.100.2: ICMP echo request, id 17831, seq 3, length 64
IP 192.168.100.2 > 192.168.100.1: ICMP echo reply, id 17831, seq 3, length 64
IP 192.168.100.1 > 192.168.100.2: ICMP echo request, id 17831, seq 4, length 64
IP 192.168.100.2 > 192.168.100.1: ICMP echo reply, id 17831, seq 4, length 64
IP 192.168.100.1 > 192.168.100.2: ICMP echo request, id 17831, seq 5, length 64
IP 192.168.100.2 > 192.168.100.1: ICMP echo reply, id 17831, seq 5, length 64
```

Il comando di ping deve avere un output come questo:
```bash
PING 192.168.100.2 (192.168.100.2) from 192.168.100.1 veth0: 56(84) bytes of data.
64 bytes from 192.168.100.2: icmp_seq=1 ttl=64 time=0.567 ms
64 bytes from 192.168.100.2: icmp_seq=2 ttl=64 time=0.481 ms
64 bytes from 192.168.100.2: icmp_seq=3 ttl=64 time=0.293 ms
64 bytes from 192.168.100.2: icmp_seq=4 ttl=64 time=0.573 ms
64 bytes from 192.168.100.2: icmp_seq=5 ttl=64 time=0.590 ms

--- 192.168.100.2 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4134ms
rtt min/avg/max/mdev = 0.293/0.500/0.590/0.110 ms
```
Una cosa da notare è che il TTL (Time To Live) rimane invariato per i 3 punti di ascolto: questo è corretto perché TTL viene decrementato a livello di rete, quando ad esempio attraversa un router, mentre qua i pacchetti viaggiano tramite dispositivi livello data-link, i bridge.

### Controprova
Come controprova è possibile testare se i pacchetti arrivano a destinazione nonostante il bridge della VM sia interrotto:
```bash
sudo ip link set ens3 nomaster
```
A questo punto dovremmo avere l'output di tap1 vuoto, dato che un'interruzione del bridge (ens3 scollegata) comporta interruzione dell'inoltro dei pacchetti attraverso la VM.

### Fallimento
Se il test fallisce è possibile individuare facilmente dove è localizzato il problema rimuovendo il filtro di `icmp` (rieseguire tutti i tcpdump senza `-n icmp`), ed in base a quali registrano dei movimenti:
+ nessuno: problema del veth pair `veth0`-`veth0-br` o del bridge `br0`
+ solo tap0: problema dell'interfaccia `ens3`
+ tap0 e brVM: problema dell'interfaccia `ens4`
+ tutti ma ping fallisce (packet loss): problema del bridge `br1` o del veth pair `veth1`-`veth1-br`