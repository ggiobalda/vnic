// core.p4: tipi base del linguaggio (packet_in, ...)
// ebpf_model.p4: modello ebpfFilter di p4c, l'unico che p4c-ebpf traduce in XDP
#include <core.p4>
#include <ebpf_model.p4>

const bit<16> ETH_P_IP     = 0x0800;
const bit<8>  IPPROTO_TCP  = 6;
// deve coincidere con BLOCKED_PORT in tcp_port_filter.c e verify.sh
const bit<16> BLOCKED_PORT = 8080;

// ------------------------------ HEADER ------------------------------

// in P4 gli header vanno definiti a mano campo per campo (in bit),
// servono tutti i campi prima di quelli usati per sapere dove si trovano
header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<4>  res;
    bit<8>  flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

// insieme degli header che il parser può estrarre dal pacchetto
struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    tcp_t      tcp;
}

// ------------------------------ PARSER ------------------------------

// legge ethernet, poi IP se ethertype è IPv4, poi TCP se il protocollo è TCP
// (un header estratto diventa valido, vedi isValid() nel control)
parser tcp_port_filter_parser(packet_in pkt, out headers_t hdr) {
    state start {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            ETH_P_IP: parse_ipv4;
            default: accept;
        }
    }

    // TCP letto solo se IP senza opzioni (ihl = 5, header di 20 byte),
    // a differenza del .c che usa ihl * 4. Altrimenti il pacchetto passa
    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.ihl, hdr.ipv4.protocol) {
            (5, IPPROTO_TCP): parse_tcp;
            default: accept;
        }
    }

    state parse_tcp {
        pkt.extract(hdr.tcp);
        transition accept;
    }
}

// ------------------------------ CONTROL ------------------------------

// decide cosa fare del pacchetto tramite pass:
// true -> XDP_PASS (prosegue), false -> XDP_DROP (scartato)
control tcp_port_filter(inout headers_t hdr, out bool pass) {
    action drop_packet() {
        pass = false;
    }

    apply {
        // di default il pacchetto passa
        pass = true;
        if (hdr.tcp.isValid() && hdr.tcp.dstPort == BLOCKED_PORT) {
            drop_packet();
        }
    }
}

// collega parser e control, come SEC("xdp") + funzione nel .c
ebpfFilter(tcp_port_filter_parser(), tcp_port_filter()) main;
