# tcp-port-filter
Filtro XDP che scarta i pacchetti TCP diretti alla porta 8080 e lascia passare tutto il resto, compreso il TCP verso altre porte.

La cartella contiene il filtro in C (`tcp_port_filter.c`, che tiene conto anche di eventuali opzioni nell'header IPv4 usando `ihl * 4`), la versione P4 (`tcp_port_filter.p4`, ancora da scrivere) e lo script `verify.sh` per testarlo. La porta bloccata è definita da `BLOCKED_PORT` nel sorgente, se viene cambiata va aggiornata anche la variabile con lo stesso nome in `verify.sh`.

## Verifica
```bash
sudo examples/tcp-port-filter/verify.sh
```
Passando `p4` come argomento viene usata la versione P4, che per ora termina con errore dato che la traduzione P4 non è ancora implementata.

Lo script avvia vnic con il filtro, cattura il traffico su `tap0` e `tap1` e con `traffic.sh` invia 3 SYN verso la porta 9090 e 3 verso la 8080. Il test passa se i SYN verso la 9090 compaiono su entrambe le tap, mentre quelli verso la 8080 solo su `tap0`.
```
[verify] porta 9090: tap0=3 tap1=3 | porta 8080: tap0=3 tap1=0
[verify] PASS: porta 9090 raggiungibile, porta 8080 bloccata
```
Alla fine l'istanza viene fermata, le catture restano in `/tmp/vnic-verify-tcp-port-filter/` e si possono leggere con `tcpdump -r <file .pcap>`.
