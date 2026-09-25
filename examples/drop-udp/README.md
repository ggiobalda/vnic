# drop-udp
Filtro XDP che scarta tutti i pacchetti UDP su IPv4 e lascia passare il resto.

La cartella contiene il filtro in C (`drop_udp.c`, lo stesso usato in `docs/VM-test.md`), la versione P4 (`drop_udp.p4`, ancora da scrivere) e lo script `verify.sh` per testarlo.

## Verifica
```bash
sudo examples/drop-udp/verify.sh
```
Passando `p4` come argomento viene usata la versione P4, che per ora termina con errore dato che la traduzione P4 non è ancora implementata.

Lo script avvia vnic con il filtro, cattura il traffico su `tap0` (ingresso VM) e `tap1` (uscita VM) e con `traffic.sh` invia 5 ping e un pacchetto UDP da `ns0` a `ns1`. Il test passa se i ping (10 pacchetti tra richieste e risposte) compaiono su entrambe le tap, mentre il pacchetto UDP compare solo su `tap0`, cioè è stato scartato dentro la VM.
```
[verify] ICMP: tap0=10 tap1=10 | UDP: tap0=1 tap1=0
[verify] PASS: ICMP attraversa la VM, UDP viene scartato
```
Alla fine l'istanza viene fermata, le catture restano in `/tmp/vnic-verify-drop-udp/` e si possono leggere con `tcpdump -r <file .pcap>`.
