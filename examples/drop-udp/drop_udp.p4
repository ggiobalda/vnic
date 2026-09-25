// core.p4: tipi base del linguaggio (packet_in, ...)
// ebpf_model.p4: modello ebpfFilter di p4c, l'unico che p4c-ebpf traduce in XDP
#include <core.p4>
#include <ebpf_model.p4>

const bit<16> ETH_P_IP    = 0x0800;
const bit<8>  IPPROTO_UDP = 17;

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

// insieme degli header che il parser può estrarre dal pacchetto
struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

// ------------------------------ PARSER ------------------------------

// legge ethernet e, solo se ethertype è IPv4, anche l'header IP
// (un header estratto diventa valido, vedi isValid() nel control)
parser drop_udp_parser(packet_in pkt, out headers_t hdr) {
    state start {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            ETH_P_IP: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition accept;
    }
}

// ------------------------------ CONTROL ------------------------------

// decide cosa fare del pacchetto tramite pass:
// true -> XDP_PASS (prosegue), false -> XDP_DROP (scartato)
control drop_udp(inout headers_t hdr, out bool pass) {
    action drop_packet() {
        pass = false;
    }

    apply {
        // di default il pacchetto passa
        pass = true;
        if (hdr.ipv4.isValid() && hdr.ipv4.protocol == IPPROTO_UDP) {
            drop_packet();
        }
    }
}

// collega parser e control, come SEC("xdp") + funzione nel .c
ebpfFilter(drop_udp_parser(), drop_udp()) main;
