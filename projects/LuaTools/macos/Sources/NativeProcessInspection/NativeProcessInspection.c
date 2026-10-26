#include "NativeProcessInspection.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>

int lt_tcp_listener_owners(uint16_t port, LTListenerOwner* owners, int capacity) {
    if (!port || !owners || capacity <= 0 || capacity > 1024) return -1;
    const int process_capacity = 65536;
    int* pids = calloc(process_capacity, sizeof(int));
    if (!pids) return -1;
    int count = proc_listallpids(pids, process_capacity * (int)sizeof(int));
    if (count <= 0 || count >= process_capacity) { free(pids); return -1; }
    int found = 0;
    for (int index = 0; index < count; ++index) {
        if (pids[index] <= 0) continue;
        int needed = proc_pidinfo(pids[index], PROC_PIDLISTFDS, 0, NULL, 0);
        if (needed <= 0) continue; // Exited or inaccessible process.
        if (needed > 16 * 1024 * 1024) { free(pids); return -1; }
        int bytes = needed + 64 * (int)sizeof(struct proc_fdinfo);
        struct proc_fdinfo* descriptors = malloc(bytes);
        if (!descriptors) { free(pids); return -1; }
        int actual = proc_pidinfo(pids[index], PROC_PIDLISTFDS, 0, descriptors, bytes);
        if (actual >= bytes || (actual > 0 && actual % sizeof(struct proc_fdinfo))) { free(descriptors); free(pids); return -1; }
        int owns = 0, loopback = 1;
        for (int offset = 0; actual > 0 && offset < actual / (int)sizeof(struct proc_fdinfo); ++offset) {
            if (descriptors[offset].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo socket = {0};
            if (proc_pidfdinfo(pids[index], descriptors[offset].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)) continue;
            if (socket.psi.soi_kind != SOCKINFO_TCP || socket.psi.soi_protocol != IPPROTO_TCP || socket.psi.soi_type != SOCK_STREAM) continue;
            const struct tcp_sockinfo* tcp = &socket.psi.soi_proto.pri_tcp;
            if (tcp->tcpsi_state != TSI_S_LISTEN || ntohs((uint16_t)tcp->tcpsi_ini.insi_lport) != port) continue;
            owns = 1;
            if (socket.psi.soi_family == AF_INET) {
                const uint32_t address = ntohl(tcp->tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr);
                if ((address & 0xff000000u) != 0x7f000000u) loopback = 0;
            } else if (socket.psi.soi_family == AF_INET6) {
                if (!IN6_IS_ADDR_LOOPBACK(&tcp->tcpsi_ini.insi_laddr.ina_6)) loopback = 0;
            } else { loopback = 0; }
        }
        free(descriptors);
        if (!owns) continue;
        if (found >= capacity) { free(pids); return -1; }
        LTListenerOwner* owner = &owners[found++];
        memset(owner, 0, sizeof(*owner)); owner->pid = pids[index]; owner->loopback_only = loopback;
        // Unknown executable identity is retained as an empty path, so callers
        // reject it instead of silently dropping a discovered listener owner.
        if (proc_pidpath(pids[index], owner->executable, sizeof(owner->executable)) <= 0) owner->executable[0] = 0;
    }
    free(pids); return found;
}
