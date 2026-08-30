# Introduzione
Questo test serve a simulare l'infrastruttura e la VM utilizzate per emulare una smartNIC. L'intento è quello di tradurre questo test manuale in una espansione del tool **vnic**, implementando inoltre la logica interna alla VM necessaria per poter processare i frame ethernet. Al momento quindi la VM non processa ma inoltra semplicemente i pacchetti in arrivo.

# Architettura
L'infrastruttura di rete utilizzate per testare l'inoltro di pacchetti attraverso una VM, visualizzabile tramite un grafico di flusso in `docs/smartnic_packet_path.svg`, è così formata:
- due **network namespace** (`ns0` e `ns1`), funzionalità del kernel che crea una copia isolata dello stack di rete. Questi servono a simulare due calcolatori distinti, ognuno con proprie interfacce, indirizzi IP, etc. Il primo rappresenta il trasmettitore, il secondo il ricevitore.
- due **veth pair** (`veth0`-`veth0-br` e `veth1`-`veth1-br`), ogni coppia rappresenta i due capi di un cavo ethernet virtuale. Servono a collegare i namespaces isolati col namespace di default, quello dell'host che esegue vnic.
- due **bridge software** (`br0` e `br1`), rappresentano degli switch e servono a inoltrare i pacchetti fra VM e host, che a sua volta inoltra/riceve dai namespaces. Questi componenti sono utili solo per questo test, in quanto svolgo essenzialmente lo stesso compito della funzione `forward`.
- due **TAP devices** (`tap0` e `tap1`), interfacce virtuali su cui un programma in userspace può leggere/scrive frame ethernet grezzi. Sono il punto di aggancio per l'hypervisor QEMU per poter comunicare con la VM.
- due **interfacce di rete** (`ens3` e `ens4`), si trovato all'interno della VM e corrispondo ai due TAP a cui è collegato QEMU. Il nome è scelto arbitrariamente dal sistema utilizzato (in questo caso Debian).
- un **bridge software** (`brVM`), collega internamente alla VM le due interfacce. Questo componente al momento inoltra tutti i pacchetti in arrivo, ma verrà sostituito dalla logica di forwarding allegata con codice eBPF o P4.

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

## VM
Per realizzare la VM ho scelto di usare l'hypervisor QEMU, data la semplicità di gestione e leggerezza. Nella VM gira il sistema Debian 12, ed in particolare si usa l'immagine base `debian-12-generic-amd64.qcow2`. Questa è un'immagine cloud,cioè fatta per essere configurata e gestita senza intervento umano: niente installer, driver di virtualizzazione già presenti e soprattutto un meccanismo (*cloud-init*) pensato per inizializzare la VM.
**cloud-init**, durante il boot, scansiona i dispositivi collegati alla VM cercandone uno con volume etichettato `cidata` (formato ISO9660 o FAT); una volta trovato, legge i file `user-data`, `meta-data` e `vendor-data` al suo interno e applica la configurazione.

#### 1. Download immagine base
```bash
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
```
#### 2. Installazione tools necessari
QEMU come hypervisor, `xorriso` per generare files.iso e `guestfs-tools` per usare il comando `virt-customize` (vedi più avanti).
```bash
sudo *** install qemu-x86 qemu-tools xorriso guestfs-tools
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

#### 5. Disabilitazione servizio di rete systemd
Necessario in quanto all'avvio systemd cerca invano un DHCP per assegnare indirizzo IP alle interfacce fornite alla VM, bloccando il boot.
```bash
virt-customize -a debian-12-generic-amd64.qcow2 --run-command 'systemctl mask systemd-networkd-wait-online.service'
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
sudo ip link add brVM type bridge
sudo ip link set brVM up
sudo ip link set ens3 master brVM
sudo ip link set ens4 master brVM
```

# Esecuzione
A questo punto è tutto pronto per fare un test dove si prova a spedire dei pacchetti dal namespace `ns0` a `ns1`, verificando che questi passino attraverso la VM.

#### 1. Packet sniffing tap0 e tap1
Aprire un nuovo terminale ed eseguire tcpdump sull'interfaccia `tap0`, per controllare che i pacchetti entrino nella VM.
```bash
sudo tcpdump -i tap0 -n icmp
```
Ripetere il comando in un nuovo terminale per controllare l'interfaccia `tap1`, uscita della VM.
```bash
sudo tcpdump -i tap1 -n icmp
```

#### 2. Packet sniffing brVM
Per essere sicuri che i pacchetti attraversino la VM eseguiamo un'altro `tcpdump`, stavolta nel terminale della VM già aperto.
```bash
sudo tcpdump -i brVM -n icmp
```

#### 3. Ping
Eseguiamo infine il comando di ping dal namespace `ns0`, attraverso la sua interfaccia `veth0`, verso l'indirizzo IP dell'interfaccia `veth1`, appartente al namespace `ns1`. Si limita a 5 pacchetti.
```bash
sudo ip netns exec ns0 ping -c 5 -I veth0 192.168.100.2 
```

### Risultato
Il risultato corretto dovrebbe registrare, su ognuno dei 3 tcpdump, il passaggio dei 5 pacchetti. Una cosa da notare è che il TTL (Time To Live) rimane invariato per i 3 punti di ascolto: questo è corretto perché TTL viene decrementato a livello di rete, quando ad esempio attraversa un router, mentre qua i pacchetti viaggiano tramite dispositivi livello data-link, i bridge.

Come controprova è possibile testare se i pacchetti arrivano a destinazione nonostante il bridge della VM sia interrotto:
```bash
sudo ip link set ens3 nomaster
```
A questo punto dovremmo avere l'output di tap1 vuoto, dato che un'interruzione del bridge (ens3 scollegata) dovrebbe comportare interruzione dell'inoltro dei pacchetti attraverso la VM. 