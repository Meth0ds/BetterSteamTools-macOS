#pragma once
#include <stdint.h>

typedef struct LTListenerOwner {
    int32_t pid;
    int32_t loopback_only;
    char executable[4096];
} LTListenerOwner;

// Returns the owner count, or -1 for an invalid/truncated inventory. Each PID
// appears once even if it holds several descriptors for the same TCP listener.
int lt_tcp_listener_owners(uint16_t port, LTListenerOwner* owners, int capacity);
