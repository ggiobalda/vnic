#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

#define BLOCKED_PORT 8080

SEC("xdp")
int tcp_port_filter(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    struct iphdr *ip = data + sizeof(*eth);

    if ((void *)(eth + 1) > data_end ||
        (void *)(ip + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != __constant_htons(ETH_P_IP) ||
        ip->protocol != IPPROTO_TCP)
        return XDP_PASS;

    struct tcphdr *tcp = (void *)ip + ip->ihl * 4;

    if ((void *)(tcp + 1) > data_end)
        return XDP_PASS;

    return tcp->dest == __constant_htons(BLOCKED_PORT)
           ? XDP_DROP
           : XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
