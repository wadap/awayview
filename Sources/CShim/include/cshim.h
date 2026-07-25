#ifndef CSHIM_H
#define CSHIM_H

#include <stddef.h>
#include <stdint.h>

// net.inet.tcp.pcblist_n から「local port が local_port の ESTABLISHED 接続」の
// foreign IP を改行区切りで out へ書く。戻り値は件数 (エラー時 -1)。
// root 不要で全プロセスのソケットが見える (netstat と同じ情報源)。
int css_list_established_foreign(uint16_t local_port, char *out, size_t out_len);

#endif
