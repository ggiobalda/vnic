// rawnc: a tiny, netcat-like Ethernet payload sender/receiver for Linux.
// It deliberately has no connection, ordering, retry, or fragmentation
// protocol. It is useful for proving an L2 path such as the vnic forwarder.

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

// An experimental, locally administered EtherType. Both rawnc endpoints
// filter on it, so ordinary ARP/IPv4/IPv6 traffic is never printed as data.
#define RAWNC_ETHERTYPE 0x88B5

static void usage(const char *program) {
    fprintf(stderr,
            "Usage:\n"
            "  %s -l IFACE                  receive rawnc payloads to stdout\n"
            "  %s [-d MAC] IFACE             send stdin as rawnc Ethernet frames\n\n"
            "Options:\n"
            "  -l, --listen       receive mode\n"
            "  -d, --dest MAC     destination MAC (default: ff:ff:ff:ff:ff:ff)\n"
            "  -h, --help         show this help\n\n"
            "Raw Ethernet needs root or CAP_NET_RAW. Each stdin read is one frame\n"
            "(at most %d payload bytes); this is a small L2 test tool, not TCP.\n",
            program, program, ETH_DATA_LEN);
}

static int parse_mac(const char *text, unsigned char mac[ETH_ALEN]) {
    unsigned int octets[ETH_ALEN];
    if (sscanf(text, "%x:%x:%x:%x:%x:%x", &octets[0], &octets[1], &octets[2],
               &octets[3], &octets[4], &octets[5]) != ETH_ALEN) {
        return -1;
    }
    for (size_t i = 0; i < ETH_ALEN; ++i) {
        if (octets[i] > 0xff) {
            return -1;
        }
        mac[i] = (unsigned char)octets[i];
    }
    return 0;
}

static int write_all(int fd, const void *data, size_t length) {
    const unsigned char *cursor = data;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        cursor += (size_t)written;
        length -= (size_t)written;
    }
    return 0;
}

static int open_bound_socket(const char *interface, unsigned char own_mac[ETH_ALEN],
                             int *ifindex) {
    if (strlen(interface) >= IFNAMSIZ) {
        errno = ENAMETOOLONG;
        return -1;
    }

    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) {
        return -1;
    }

    struct ifreq request = {0};
    strncpy(request.ifr_name, interface, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &request) < 0) {
        close(fd);
        return -1;
    }
    *ifindex = request.ifr_ifindex;

    if (ioctl(fd, SIOCGIFHWADDR, &request) < 0) {
        close(fd);
        return -1;
    }
    memcpy(own_mac, request.ifr_hwaddr.sa_data, ETH_ALEN);

    struct sockaddr_ll address = {0};
    address.sll_family = AF_PACKET;
    address.sll_protocol = htons(ETH_P_ALL);
    address.sll_ifindex = *ifindex;
    if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int send_stdin(int fd, int ifindex, const unsigned char own_mac[ETH_ALEN],
                      const unsigned char destination[ETH_ALEN]) {
    unsigned char frame[ETH_FRAME_LEN];
    struct ethhdr *ethernet = (struct ethhdr *)frame;
    memcpy(ethernet->h_dest, destination, ETH_ALEN);
    memcpy(ethernet->h_source, own_mac, ETH_ALEN);
    ethernet->h_proto = htons(RAWNC_ETHERTYPE);

    struct sockaddr_ll peer = {0};
    peer.sll_family = AF_PACKET;
    peer.sll_ifindex = ifindex;
    peer.sll_halen = ETH_ALEN;
    memcpy(peer.sll_addr, destination, ETH_ALEN);

    for (;;) {
        ssize_t bytes = read(STDIN_FILENO, frame + ETH_HLEN, ETH_DATA_LEN);
        if (bytes == 0) {
            return 0;
        }
        if (bytes < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        size_t frame_length = ETH_HLEN + (size_t)bytes;
        if (sendto(fd, frame, frame_length, 0, (const struct sockaddr *)&peer, sizeof(peer)) !=
            (ssize_t)frame_length) {
            return -1;
        }
    }
}

static int receive_stdout(int fd) {
    unsigned char frame[ETH_FRAME_LEN];
    for (;;) {
        struct sockaddr_ll sender = {0};
        socklen_t sender_length = sizeof(sender);
        ssize_t bytes = recvfrom(fd, frame, sizeof(frame), 0, (struct sockaddr *)&sender,
                                 &sender_length);
        if (bytes < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        // AF_PACKET also sees the process's own transmit frames. They are
        // not traffic received from the other end of the virtual cable.
        if (sender.sll_pkttype == PACKET_OUTGOING || bytes < ETH_HLEN) {
            continue;
        }
        const struct ethhdr *ethernet = (const struct ethhdr *)frame;
        if (ntohs(ethernet->h_proto) != RAWNC_ETHERTYPE) {
            continue;
        }
        if (write_all(STDOUT_FILENO, frame + ETH_HLEN, (size_t)bytes - ETH_HLEN) < 0) {
            return -1;
        }
    }
}

int main(int argc, char **argv) {
    bool listen = false;
    bool destination_set = false;
    unsigned char destination[ETH_ALEN] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    static const struct option options[] = {
        {"listen", no_argument, NULL, 'l'},
        {"dest", required_argument, NULL, 'd'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0},
    };

    int option;
    while ((option = getopt_long(argc, argv, "ld:h", options, NULL)) != -1) {
        switch (option) {
        case 'l':
            listen = true;
            break;
        case 'd':
            if (parse_mac(optarg, destination) < 0) {
                fprintf(stderr, "invalid MAC address: %s\n", optarg);
                return EXIT_FAILURE;
            }
            destination_set = true;
            break;
        case 'h':
            usage(argv[0]);
            return EXIT_SUCCESS;
        default:
            usage(argv[0]);
            return EXIT_FAILURE;
        }
    }
    if (argc - optind != 1 || (listen && destination_set)) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    unsigned char own_mac[ETH_ALEN];
    int ifindex;
    int fd = open_bound_socket(argv[optind], own_mac, &ifindex);
    if (fd < 0) {
        perror("opening raw socket");
        return EXIT_FAILURE;
    }

    int result = listen ? receive_stdout(fd) : send_stdin(fd, ifindex, own_mac, destination);
    if (result < 0) {
        perror(listen ? "receiving frame" : "sending frame");
    }
    close(fd);
    return result == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
