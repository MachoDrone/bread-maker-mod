/*
 * spoof_hw.h — Configuration structs and constants for hardware spoof LD_PRELOAD
 * Version: 0.01.0
 *
 * Identity: AMD Ryzen 7 5800X (CPUID-consistent with real 5900X)
 */
#ifndef SPOOF_HW_H
#define SPOOF_HW_H

#include <pthread.h>

/* ── Spoof type enum ── */
typedef enum {
    SPOOF_NONE = 0,
    SPOOF_CPUINFO,
    SPOOF_PCIE_MAX_SPEED,
    SPOOF_PCIE_CUR_SPEED,
    SPOOF_CPU_ONLINE,
    SPOOF_CPU_PRESENT,
    SPOOF_CACHE_SIZE,
    SPOOF_PROC_MAPS,
    SPOOF_PROC_ENVIRON,
    SPOOF_CPU_DIR,
    SPOOF_TYPE_COUNT
} spoof_type_t;

/* ── Runtime config (populated from env vars) ── */
typedef struct {
    int cpu;        /* _MC_C   — /proc/cpuinfo */
    int pcie;       /* _MC_P   — sysfs link speed */
    int topology;   /* _MC_T   — online/present/cache */
    int cloak;      /* _MC_K   — self-cloaking (maps/environ/dirs) */
    int log;        /* _MC_L   — verbose stderr logging */
} spoof_config_t;

/* ── Per-FD tracking entry ── */
#define MAX_TRACKED_FDS 64

typedef struct {
    int          fd;           /* real file descriptor (-1 = unused) */
    spoof_type_t type;         /* what kind of spoof content */
    const char  *fake_buf;     /* pointer to fake content */
    size_t       fake_len;     /* length of fake content */
    size_t       offset;       /* current read offset into fake_buf */
} tracked_fd_t;

/* ── FD tracking table ── */
typedef struct {
    tracked_fd_t entries[MAX_TRACKED_FDS];
    pthread_mutex_t lock;
} fd_table_t;

/* ── Spoofed constants: AMD Ryzen 7 5800X ──
 * Family/Model/Stepping match the real 5900X CPUID (Zen 3, Vermeer)
 * so CPUID cross-checks pass.
 */
#define SPOOFED_MODEL_NAME   "AMD Ryzen 7 5800X 8-Core Processor"
#define SPOOFED_CPU_FAMILY   25
#define SPOOFED_MODEL        33
#define SPOOFED_STEPPING     2
#define SPOOFED_MICROCODE    "0xa201210"
#define SPOOFED_PHYS_CORES   8
#define SPOOFED_THREADS      16
#define SPOOFED_SIBLINGS     16
#define SPOOFED_BOGOMIPS     "7386.54"
#define SPOOFED_L3_CACHE     "32768K"

#define SPOOFED_PCIE_SPEED   "16.0 GT/s PCIe"
#define SPOOFED_CPU_ONLINE   "0-15"

/* ── Path constants ── */
#define PATH_CPUINFO         "/proc/cpuinfo"
#define PATH_CPU_ONLINE      "/sys/devices/system/cpu/online"
#define PATH_CPU_PRESENT     "/sys/devices/system/cpu/present"
#define PATH_PROC_MAPS       "/proc/self/maps"
#define PATH_PROC_ENVIRON    "/proc/self/environ"
#define PATH_CPU_DIR         "/sys/devices/system/cpu"

/* GPU PCIe device — only spoof this slot */
#define PCIE_GPU_SLOT        "0000:05:00.0"

/* Library self-name for cloaking */
#define LIB_SELF_NAME        "libhwcompat.so"

#endif /* SPOOF_HW_H */
