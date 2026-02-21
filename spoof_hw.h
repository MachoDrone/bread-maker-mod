/*
 * spoof_hw.h — Configuration structs and constants for hardware spoof LD_PRELOAD
 * Version: 0.00.1
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
    SPOOF_DMI_TABLE,
    SPOOF_DMI_ENTRY_POINT,
    SPOOF_TYPE_COUNT
} spoof_type_t;

/* ── Runtime config (populated from env vars) ── */
typedef struct {
    int cpu;        /* SPOOF_CPU   — /proc/cpuinfo */
    int pcie;       /* SPOOF_PCIE  — sysfs link speed */
    int ddr;        /* SPOOF_DDR   — DMI tables */
    int topology;   /* SPOOF_TOPOLOGY — online/present/cache */
    int log;        /* SPOOF_LOG   — verbose stderr logging */
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

/* ── Spoofed constants ── */
#define SPOOFED_MODEL_NAME   "AMD Ryzen Threadripper 1900X 8-Core Processor"
#define SPOOFED_CPU_FAMILY   23
#define SPOOFED_MODEL        1
#define SPOOFED_STEPPING     1
#define SPOOFED_MICROCODE    "0x08001137"
#define SPOOFED_PHYS_CORES   8
#define SPOOFED_THREADS      16
#define SPOOFED_SIBLINGS     16
#define SPOOFED_BOGOMIPS     "7186.36"
#define SPOOFED_L3_PER_CCX   "4096K"

#define SPOOFED_PCIE_SPEED   "32.0 GT/s PCIe"
#define SPOOFED_CPU_ONLINE   "0-15"

/* ── Path constants ── */
#define PATH_CPUINFO         "/proc/cpuinfo"
#define PATH_CPU_ONLINE      "/sys/devices/system/cpu/online"
#define PATH_CPU_PRESENT     "/sys/devices/system/cpu/present"
#define PATH_DMI_TABLE       "/sys/firmware/dmi/tables/DMI"
#define PATH_DMI_ENTRY       "/sys/firmware/dmi/tables/smbios_entry_point"

/* GPU PCIe device — only spoof this slot */
#define PCIE_GPU_SLOT        "0000:05:00.0"

#endif /* SPOOF_HW_H */
