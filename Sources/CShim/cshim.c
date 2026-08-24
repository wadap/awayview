#include "cshim.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>

// ---------------------------------------------------------------------------
// XNU の netstat 互換 ABI (bsd/netinet/in_pcb.h ほか)。公開 SDK に出ていない
// ため必要フィールドのみ写経。この ABI は netstat 互換のため安定している。
// 注意: XNU はこれらを #pragma pack(4) で定義している (32/64bit レイアウト統一
// のため)。pack を忘れると inp_ppcb 以降のオフセットが 4 ずれて全滅する。
// ---------------------------------------------------------------------------

#pragma pack(4)

struct my_xinpgen {
    uint32_t xig_len;
    uint32_t xig_count;
    uint64_t xig_gen;
    uint64_t xig_sogen;
};

struct my_in_addr_4in6 {
    uint32_t ia46_pad32[3];
    struct in_addr ia46_addr4;
};

struct my_xinpcb_n {
    uint32_t xi_len;
    uint32_t xi_kind; /* XSO_INPCB = 0x10 */
    uint64_t xi_inpp;
    uint16_t inp_fport; /* network byte order */
    uint16_t inp_lport; /* network byte order */
    uint64_t inp_ppcb;
    uint64_t inp_gencnt;
    int32_t inp_flags;
    uint32_t inp_flow;
    uint8_t inp_vflag; /* INP_IPV4=0x1 / INP_IPV6=0x2 */
    uint8_t inp_ip_ttl;
    uint8_t inp_ip_p;
    union {
        struct my_in_addr_4in6 inp46_foreign;
        struct in6_addr inp6_foreign;
    } inp_dependfaddr;
    union {
        struct my_in_addr_4in6 inp46_local;
        struct in6_addr inp6_local;
    } inp_dependladdr;
    struct {
        uint8_t inp4_ip_tos;
    } inp_depend4;
    struct {
        uint8_t inp6_hlim;
        int32_t inp6_cksum;
        uint16_t inp6_ifindex;
        int16_t inp6_hops;
    } inp_depend6;
    uint32_t inp_flowhash;
    uint32_t inp_flags2;
};

struct my_xtcpcb_n {
    uint32_t xi_len;
    uint32_t xi_kind; /* XSO_TCPCB = 0x20 */
    uint64_t t_segq;
    int32_t t_dupacks;
    int32_t t_timer[4]; /* TCPT_NTIMERS_EXT */
    int32_t t_state;    /* TCPS_ESTABLISHED = 4 */
    /* 以降のフィールドは不要 */
};

#pragma pack()

#define MY_XSO_INPCB 0x10u
#define MY_XSO_TCPCB 0x20u
#define MY_INP_IPV4 0x1u
#define MY_INP_IPV6 0x2u
#define MY_TCPS_ESTABLISHED 4

int css_list_established_foreign(uint16_t local_port, char *out, size_t out_len) {
    if (out == NULL || out_len == 0) return -1;
    out[0] = '\0';

    /* サイズ取得と本取得の間にソケットテーブルが増えると本取得が ENOMEM で
       落ちる。ここで諦めると呼び出し側からは「接続 0 件」と見分けが付かず、
       画面共有中でも「切断」と判定されてしまう。余裕を広げながらやり直す。 */
    char *buf = NULL;
    size_t len = 0;
    int fetched = 0;

    for (int attempt = 0; attempt < 4 && !fetched; attempt++) {
        size_t need = 0;
        if (sysctlbyname("net.inet.tcp.pcblist_n", NULL, &need, NULL, 0) < 0) {
            free(buf);
            return -1;
        }
        need += (need / 8) << attempt; /* 余裕を 1/8, 1/4, 1/2, 1 と広げる */

        char *grown = realloc(buf, need);
        if (grown == NULL) {
            free(buf);
            return -1;
        }
        buf = grown;
        len = need;

        if (sysctlbyname("net.inet.tcp.pcblist_n", buf, &len, NULL, 0) == 0) {
            fetched = 1;
        } else if (errno != ENOMEM) {
            free(buf);
            return -1;
        }
    }
    if (!fetched) {
        free(buf);
        return -1;
    }

    size_t off = ((struct my_xinpgen *)buf)->xig_len;
    const struct my_xinpcb_n *inp = NULL;
    size_t used = 0;
    int count = 0;

    while (off + 2 * sizeof(uint32_t) <= len) {
        uint32_t xi_len, xi_kind;
        memcpy(&xi_len, buf + off, sizeof(xi_len));
        memcpy(&xi_kind, buf + off + 4, sizeof(xi_kind));
        if (xi_len == 0) break;

        if (xi_kind == MY_XSO_INPCB && off + sizeof(struct my_xinpcb_n) <= len) {
            inp = (const struct my_xinpcb_n *)(buf + off);
        } else if (xi_kind == MY_XSO_TCPCB && off + sizeof(struct my_xtcpcb_n) <= len) {
            const struct my_xtcpcb_n *tcp = (const struct my_xtcpcb_n *)(buf + off);
            if (inp != NULL && tcp->t_state == MY_TCPS_ESTABLISHED &&
                ntohs(inp->inp_lport) == local_port) {
                char ip[INET6_ADDRSTRLEN] = {0};
                if (inp->inp_vflag & MY_INP_IPV4) {
                    inet_ntop(AF_INET, &inp->inp_dependfaddr.inp46_foreign.ia46_addr4,
                              ip, sizeof(ip));
                } else if (inp->inp_vflag & MY_INP_IPV6) {
                    inet_ntop(AF_INET6, &inp->inp_dependfaddr.inp6_foreign, ip, sizeof(ip));
                }
                size_t iplen = strlen(ip);
                if (iplen > 0 && used + iplen + 2 < out_len) {
                    if (used > 0) out[used++] = '\n';
                    memcpy(out + used, ip, iplen);
                    used += iplen;
                    out[used] = '\0';
                    count++;
                }
            }
            inp = NULL;
        }
        /* ブロックは 8 バイト境界に切り上げて並ぶ (xnu の ROUNDUP64 相当) */
        off += (xi_len + 7u) & ~(size_t)7u;
    }

    free(buf);
    return count;
}
