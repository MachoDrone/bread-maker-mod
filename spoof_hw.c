/*
 * spoof_hw.c — LD_PRELOAD shared library for hardware identity spoofing
 * Version: 0.00.1
 *
 * Hooks glibc open/read/close (and stdio variants) to intercept reads of
 * /proc/cpuinfo, sysfs PCIe speed, sysfs CPU topology, and DMI tables.
 *
 * Build: gcc -shared -fPIC -o spoof_hw.so spoof_hw.c -ldl -lpthread
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <pthread.h>
#include <sys/types.h>

#include "spoof_hw.h"
#include "fake_cpuinfo.h"

/* ──────────────────────────────────────────────────────────────────────
 * Real libc function pointers
 * ────────────────────────────────────────────────────────────────────── */
static int     (*real_open)(const char *, int, ...);
static int     (*real_openat)(int, const char *, int, ...);
static ssize_t (*real_read)(int, void *, size_t);
static int     (*real_close)(int);
static off_t   (*real_lseek)(int, off_t, int);
static FILE   *(*real_fopen)(const char *, const char *);
static size_t  (*real_fread)(void *, size_t, size_t, FILE *);
static char   *(*real_fgets)(char *, int, FILE *);
static int     (*real_fclose)(FILE *);

/*
 * Lazy-resolve real libc functions. Called before the constructor runs
 * (e.g., dynamic linker calls open() during startup). Without this,
 * the hooks dereference NULL function pointers → SIGSEGV.
 */
static void ensure_real_syms(void) {
    if (!real_open) {
        real_open   = dlsym(RTLD_NEXT, "open");
        real_openat = dlsym(RTLD_NEXT, "openat");
        real_read   = dlsym(RTLD_NEXT, "read");
        real_close  = dlsym(RTLD_NEXT, "close");
        real_lseek  = dlsym(RTLD_NEXT, "lseek");
        real_fopen  = dlsym(RTLD_NEXT, "fopen");
        real_fread  = dlsym(RTLD_NEXT, "fread");
        real_fgets  = dlsym(RTLD_NEXT, "fgets");
        real_fclose = dlsym(RTLD_NEXT, "fclose");
    }
}

/* ──────────────────────────────────────────────────────────────────────
 * Global state
 * ────────────────────────────────────────────────────────────────────── */
static spoof_config_t  g_config;
static fd_table_t      g_fd_table;
static int             g_initialized = 0;

/* Fake content buffers */
static char g_fake_cpuinfo[CPUINFO_BUF_SIZE];
static size_t g_fake_cpuinfo_len;

/* Static string buffers for simple spoofs */
static const char *g_fake_pcie_speed;
static size_t      g_fake_pcie_speed_len;
static const char *g_fake_cpu_online;
static size_t      g_fake_cpu_online_len;
static const char *g_fake_cache_size;
static size_t      g_fake_cache_size_len;

/* DMI spoof buffer */
static char   g_fake_dmi[4096];
static size_t g_fake_dmi_len;
static char   g_fake_dmi_entry[32];
static size_t g_fake_dmi_entry_len;

/* Recursion guard — per-thread */
static __thread int in_hook = 0;

/* ──────────────────────────────────────────────────────────────────────
 * Logging (safe: uses dprintf to avoid stdio recursion)
 * ────────────────────────────────────────────────────────────────────── */
#define LOG(fmt, ...) do { \
    if (g_config.log) \
        dprintf(STDERR_FILENO, "[spoof] " fmt "\n", ##__VA_ARGS__); \
} while (0)

/* ──────────────────────────────────────────────────────────────────────
 * Env var helper
 * ────────────────────────────────────────────────────────────────────── */
static int env_bool(const char *name, int default_val) {
    const char *v = getenv(name);
    if (!v) return default_val;
    return atoi(v);
}

/* ──────────────────────────────────────────────────────────────────────
 * DMI table generation — SMBIOS Type 17 (Memory Device) with DDR5
 *
 * Minimal valid DMI structure: just enough Type 17 entries to claim DDR5.
 * Real DMI tables are much larger; we only produce what's needed for
 * dmidecode to report DDR5 memory type.
 * ────────────────────────────────────────────────────────────────────── */
static void generate_fake_dmi(void) {
    /*
     * SMBIOS Type 17 structure (Memory Device), version 3.3+
     * We create 2 entries (2 DIMMs of DDR5-4800).
     */
    unsigned char type17[] = {
        17,         /* type */
        84,         /* length (SMBIOS 3.3 Type 17 = 84 bytes) */
        0, 0,       /* handle (filled per entry) */
        0xFF, 0xFF, /* physical memory array handle */
        0xFF, 0xFF, /* memory error info handle */
        64, 0,      /* total width: 64 bits */
        64, 0,      /* data width: 64 bits */
        0x40, 0x00, /* size: 16384 MB = 16 GB (0x4000) */
        0x09,       /* form factor: DIMM */
        0,          /* device set */
        1,          /* device locator string index */
        2,          /* bank locator string index */
        34,         /* memory type: DDR5 (0x22 = 34) */
        0x00, 0x00, /* type detail */
        0xC0, 0x12, /* speed: 4800 MHz (0x12C0) */
        3,          /* manufacturer string */
        4,          /* serial number string */
        5,          /* asset tag string */
        6,          /* part number string */
        0,          /* attributes */
        0, 0, 0, 0, /* extended size */
        0xC0, 0x12, /* configured speed: 4800 */
        0x00, 0x00, /* min voltage */
        0x00, 0x00, /* max voltage */
        0x00, 0x00, /* configured voltage */
        0,          /* memory technology */
        0x00, 0x00, /* operating mode capability */
        0,          /* firmware version */
        0x00, 0x00, /* module manufacturer ID */
        0x00, 0x00, /* module product ID */
        0x00, 0x00, /* memory subsystem controller manufacturer ID */
        0x00, 0x00, /* memory subsystem controller product ID */
        0, 0, 0, 0, 0, 0, 0, 0, /* non-volatile size */
        0, 0, 0, 0, 0, 0, 0, 0, /* volatile size */
        0, 0, 0, 0, 0, 0, 0, 0, /* cache size */
        0, 0, 0, 0, 0, 0, 0, 0, /* logical size */
    };

    /* Pad to declared length */
    size_t entry_struct_len = 84;
    /* Strings follow the struct, terminated by double-null */
    const char *strings =
        "DIMM_A1\0"     /* string 1: device locator */
        "BANK 0\0"      /* string 2: bank locator */
        "Samsung\0"     /* string 3: manufacturer */
        "12345678\0"    /* string 4: serial */
        "AssetTag0\0"   /* string 5: asset tag */
        "M425R2GA3BB0-CQKOL\0"  /* string 6: part number (DDR5 part) */
        ;               /* final \0 from string literal = double-null */
    size_t strings_len = 7 + 1 + 6 + 1 + 7 + 1 + 8 + 1 + 9 + 1 + 19 + 1 + 1;

    size_t pos = 0;
    /* Entry 1 — handle 0x0040 */
    type17[2] = 0x40; type17[3] = 0x00;
    memcpy(g_fake_dmi + pos, type17, entry_struct_len);
    pos += entry_struct_len;
    memcpy(g_fake_dmi + pos, strings, strings_len);
    pos += strings_len;

    /* Entry 2 — handle 0x0041, different locator */
    type17[2] = 0x41; type17[3] = 0x00;
    const char *strings2 =
        "DIMM_B1\0"
        "BANK 1\0"
        "Samsung\0"
        "12345679\0"
        "AssetTag1\0"
        "M425R2GA3BB0-CQKOL\0"
        ;
    size_t strings2_len = 7 + 1 + 6 + 1 + 7 + 1 + 8 + 1 + 9 + 1 + 19 + 1 + 1;

    memcpy(g_fake_dmi + pos, type17, entry_struct_len);
    pos += entry_struct_len;
    memcpy(g_fake_dmi + pos, strings2, strings2_len);
    pos += strings2_len;

    /* End-of-table marker (Type 127) */
    g_fake_dmi[pos++] = 127;  /* type */
    g_fake_dmi[pos++] = 4;    /* length */
    g_fake_dmi[pos++] = 0xFF; /* handle */
    g_fake_dmi[pos++] = 0xFF;
    g_fake_dmi[pos++] = 0;    /* double-null terminator */
    g_fake_dmi[pos++] = 0;

    g_fake_dmi_len = pos;

    /* SMBIOS 3.0 64-bit entry point */
    unsigned char entry_point[] = {
        '_', 'S', 'M', '3', '_',  /* anchor */
        0,                          /* checksum (placeholder) */
        24,                         /* entry point length */
        3, 3,                       /* SMBIOS 3.3 */
        1,                          /* docrev */
        0x01,                       /* entry point revision */
        0,                          /* reserved */
        0, 0, 0, 0,                /* structure table max size */
        0, 0, 0, 0, 0, 0, 0, 0,   /* structure table address */
    };
    /* Set table max size */
    unsigned int table_size = (unsigned int)pos;
    entry_point[12] = table_size & 0xFF;
    entry_point[13] = (table_size >> 8) & 0xFF;

    /* Compute checksum */
    unsigned char sum = 0;
    for (size_t i = 0; i < sizeof(entry_point); i++)
        sum += entry_point[i];
    entry_point[5] = (unsigned char)(256 - sum);

    memcpy(g_fake_dmi_entry, entry_point, sizeof(entry_point));
    g_fake_dmi_entry_len = sizeof(entry_point);
}

/* ──────────────────────────────────────────────────────────────────────
 * Path classification — determines what type of spoof content to serve
 * ────────────────────────────────────────────────────────────────────── */
static spoof_type_t classify_path(const char *path) {
    if (!path) return SPOOF_NONE;

    /* CPU info */
    if (g_config.cpu && strcmp(path, PATH_CPUINFO) == 0)
        return SPOOF_CPUINFO;

    /* Topology */
    if (g_config.topology) {
        if (strcmp(path, PATH_CPU_ONLINE) == 0)
            return SPOOF_CPU_ONLINE;
        if (strcmp(path, PATH_CPU_PRESENT) == 0)
            return SPOOF_CPU_ONLINE;  /* same content */

        /* Cache size: .../cpuN/cache/index3/size */
        if (strstr(path, "/cache/index3/size") != NULL &&
            strstr(path, "/sys/devices/system/cpu/cpu") == path)
            return SPOOF_CACHE_SIZE;
    }

    /* PCIe speed — only for our GPU slot */
    if (g_config.pcie && strstr(path, PCIE_GPU_SLOT) != NULL) {
        if (strstr(path, "/max_link_speed") != NULL)
            return SPOOF_PCIE_MAX_SPEED;
        if (strstr(path, "/current_link_speed") != NULL)
            return SPOOF_PCIE_CUR_SPEED;
    }

    /* DMI tables */
    if (g_config.ddr) {
        if (strcmp(path, PATH_DMI_TABLE) == 0)
            return SPOOF_DMI_TABLE;
        if (strcmp(path, PATH_DMI_ENTRY) == 0)
            return SPOOF_DMI_ENTRY_POINT;
    }

    return SPOOF_NONE;
}

/* ──────────────────────────────────────────────────────────────────────
 * FD tracking — static array, mutex-protected
 * ────────────────────────────────────────────────────────────────────── */
static void fd_table_init(void) {
    pthread_mutex_init(&g_fd_table.lock, NULL);
    for (int i = 0; i < MAX_TRACKED_FDS; i++)
        g_fd_table.entries[i].fd = -1;
}

static int fd_table_track(int fd, spoof_type_t type) {
    const char *buf = NULL;
    size_t len = 0;

    switch (type) {
        case SPOOF_CPUINFO:
            buf = g_fake_cpuinfo; len = g_fake_cpuinfo_len; break;
        case SPOOF_PCIE_MAX_SPEED:
        case SPOOF_PCIE_CUR_SPEED:
            buf = g_fake_pcie_speed; len = g_fake_pcie_speed_len; break;
        case SPOOF_CPU_ONLINE:
            buf = g_fake_cpu_online; len = g_fake_cpu_online_len; break;
        case SPOOF_CACHE_SIZE:
            buf = g_fake_cache_size; len = g_fake_cache_size_len; break;
        case SPOOF_DMI_TABLE:
            buf = g_fake_dmi; len = g_fake_dmi_len; break;
        case SPOOF_DMI_ENTRY_POINT:
            buf = g_fake_dmi_entry; len = g_fake_dmi_entry_len; break;
        default:
            return -1;
    }

    pthread_mutex_lock(&g_fd_table.lock);
    for (int i = 0; i < MAX_TRACKED_FDS; i++) {
        if (g_fd_table.entries[i].fd == -1) {
            g_fd_table.entries[i].fd       = fd;
            g_fd_table.entries[i].type     = type;
            g_fd_table.entries[i].fake_buf = buf;
            g_fd_table.entries[i].fake_len = len;
            g_fd_table.entries[i].offset   = 0;
            pthread_mutex_unlock(&g_fd_table.lock);
            return 0;
        }
    }
    pthread_mutex_unlock(&g_fd_table.lock);
    return -1;  /* table full */
}

static tracked_fd_t *fd_table_find(int fd) {
    /* Caller must hold lock or accept race — used under lock in read/close */
    for (int i = 0; i < MAX_TRACKED_FDS; i++) {
        if (g_fd_table.entries[i].fd == fd)
            return &g_fd_table.entries[i];
    }
    return NULL;
}

static void fd_table_untrack(int fd) {
    pthread_mutex_lock(&g_fd_table.lock);
    tracked_fd_t *e = fd_table_find(fd);
    if (e) e->fd = -1;
    pthread_mutex_unlock(&g_fd_table.lock);
}

/* ──────────────────────────────────────────────────────────────────────
 * Constructor — runs when .so is loaded
 * ────────────────────────────────────────────────────────────────────── */
__attribute__((constructor))
static void spoof_init(void) {
    if (g_initialized) return;
    g_initialized = 1;

    /* Resolve real libc functions */
    real_open   = dlsym(RTLD_NEXT, "open");
    real_openat = dlsym(RTLD_NEXT, "openat");
    real_read   = dlsym(RTLD_NEXT, "read");
    real_close  = dlsym(RTLD_NEXT, "close");
    real_lseek  = dlsym(RTLD_NEXT, "lseek");
    real_fopen  = dlsym(RTLD_NEXT, "fopen");
    real_fread  = dlsym(RTLD_NEXT, "fread");
    real_fgets  = dlsym(RTLD_NEXT, "fgets");
    real_fclose = dlsym(RTLD_NEXT, "fclose");

    /* Read config from env */
    g_config.cpu      = env_bool("SPOOF_CPU", 1);
    g_config.pcie     = env_bool("SPOOF_PCIE", 1);
    g_config.ddr      = env_bool("SPOOF_DDR", 1);
    g_config.topology = env_bool("SPOOF_TOPOLOGY", 1);
    g_config.log      = env_bool("SPOOF_LOG", 0);

    /* Init FD table */
    fd_table_init();

    /* Generate fake content */
    g_fake_cpuinfo_len = generate_fake_cpuinfo(g_fake_cpuinfo, CPUINFO_BUF_SIZE);

    /* Static string spoofs (include trailing newline) */
    static char pcie_buf[64];
    snprintf(pcie_buf, sizeof(pcie_buf), "%s\n", SPOOFED_PCIE_SPEED);
    g_fake_pcie_speed     = pcie_buf;
    g_fake_pcie_speed_len = strlen(pcie_buf);

    static char online_buf[32];
    snprintf(online_buf, sizeof(online_buf), "%s\n", SPOOFED_CPU_ONLINE);
    g_fake_cpu_online     = online_buf;
    g_fake_cpu_online_len = strlen(online_buf);

    static char cache_buf[32];
    snprintf(cache_buf, sizeof(cache_buf), "%s\n", SPOOFED_L3_PER_CCX);
    g_fake_cache_size     = cache_buf;
    g_fake_cache_size_len = strlen(cache_buf);

    /* Generate fake DMI */
    generate_fake_dmi();

    LOG("initialized — cpu=%d pcie=%d ddr=%d topology=%d",
        g_config.cpu, g_config.pcie, g_config.ddr, g_config.topology);
    if (g_fake_cpuinfo_len > 0)
        LOG("fake cpuinfo: %zu bytes, %d processors", g_fake_cpuinfo_len, SPOOFED_THREADS);
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: open()
 * ────────────────────────────────────────────────────────────────────── */
int open(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    ensure_real_syms();
    if (in_hook || !g_initialized)
        return real_open(pathname, flags, mode);

    in_hook = 1;

    spoof_type_t type = classify_path(pathname);
    int fd = real_open(pathname, flags, mode);

    if (fd >= 0 && type != SPOOF_NONE) {
        if (fd_table_track(fd, type) == 0) {
            LOG("open(%s) → fd %d, spoof type %d", pathname, fd, type);
        }
    }

    in_hook = 0;
    return fd;
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: openat()
 * ────────────────────────────────────────────────────────────────────── */
int openat(int dirfd, const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    ensure_real_syms();
    if (in_hook || !g_initialized)
        return real_openat(dirfd, pathname, flags, mode);

    in_hook = 1;

    spoof_type_t type = classify_path(pathname);
    int fd = real_openat(dirfd, pathname, flags, mode);

    if (fd >= 0 && type != SPOOF_NONE) {
        if (fd_table_track(fd, type) == 0) {
            LOG("openat(%s) → fd %d, spoof type %d", pathname, fd, type);
        }
    }

    in_hook = 0;
    return fd;
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: read()
 * ────────────────────────────────────────────────────────────────────── */
ssize_t read(int fd, void *buf, size_t count) {
    ensure_real_syms();
    if (in_hook || !g_initialized)
        return real_read(fd, buf, count);

    in_hook = 1;
    ssize_t result;

    pthread_mutex_lock(&g_fd_table.lock);
    tracked_fd_t *e = fd_table_find(fd);
    if (e) {
        /* Serve fake content */
        size_t remaining = e->fake_len - e->offset;
        if (remaining == 0) {
            result = 0;  /* EOF */
        } else {
            size_t to_copy = count < remaining ? count : remaining;
            memcpy(buf, e->fake_buf + e->offset, to_copy);
            e->offset += to_copy;
            result = (ssize_t)to_copy;
        }
        pthread_mutex_unlock(&g_fd_table.lock);
        LOG("read(fd=%d) → served %zd fake bytes", fd, result);
    } else {
        pthread_mutex_unlock(&g_fd_table.lock);
        result = real_read(fd, buf, count);
    }

    in_hook = 0;
    return result;
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: lseek()
 * ────────────────────────────────────────────────────────────────────── */
off_t lseek(int fd, off_t offset, int whence) {
    ensure_real_syms();
    if (in_hook || !g_initialized)
        return real_lseek(fd, offset, whence);

    in_hook = 1;
    off_t result;

    pthread_mutex_lock(&g_fd_table.lock);
    tracked_fd_t *e = fd_table_find(fd);
    if (e) {
        off_t new_off;
        switch (whence) {
            case SEEK_SET: new_off = offset; break;
            case SEEK_CUR: new_off = (off_t)e->offset + offset; break;
            case SEEK_END: new_off = (off_t)e->fake_len + offset; break;
            default: new_off = -1; break;
        }
        if (new_off < 0 || (size_t)new_off > e->fake_len) {
            result = (off_t)-1;
            errno = EINVAL;
        } else {
            e->offset = (size_t)new_off;
            result = new_off;
        }
        pthread_mutex_unlock(&g_fd_table.lock);
    } else {
        pthread_mutex_unlock(&g_fd_table.lock);
        result = real_lseek(fd, offset, whence);
    }

    in_hook = 0;
    return result;
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: close()
 * ────────────────────────────────────────────────────────────────────── */
int close(int fd) {
    ensure_real_syms();
    if (!in_hook && g_initialized)
        fd_table_untrack(fd);
    return real_close(fd);
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: fopen() — stdio variant
 * ────────────────────────────────────────────────────────────────────── */
FILE *fopen(const char *pathname, const char *mode) {
    ensure_real_syms();
    if (in_hook || !g_initialized)
        return real_fopen(pathname, mode);

    in_hook = 1;

    spoof_type_t type = classify_path(pathname);
    FILE *fp = real_fopen(pathname, mode);

    if (fp && type != SPOOF_NONE) {
        int fd = fileno(fp);
        if (fd >= 0 && fd_table_track(fd, type) == 0) {
            LOG("fopen(%s) → fd %d, spoof type %d", pathname, fd, type);
        }
    }

    in_hook = 0;
    return fp;
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: fread() — stdio variant
 * ────────────────────────────────────────────────────────────────────── */
size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream) {
    ensure_real_syms();
    if (in_hook || !g_initialized)
        return real_fread(ptr, size, nmemb, stream);

    in_hook = 1;
    size_t result;

    int fd = fileno(stream);
    pthread_mutex_lock(&g_fd_table.lock);
    tracked_fd_t *e = fd_table_find(fd);
    if (e) {
        size_t total = size * nmemb;
        size_t remaining = e->fake_len - e->offset;
        size_t to_copy = total < remaining ? total : remaining;
        if (to_copy > 0) {
            memcpy(ptr, e->fake_buf + e->offset, to_copy);
            e->offset += to_copy;
        }
        result = (size > 0) ? to_copy / size : 0;
        pthread_mutex_unlock(&g_fd_table.lock);
    } else {
        pthread_mutex_unlock(&g_fd_table.lock);
        result = real_fread(ptr, size, nmemb, stream);
    }

    in_hook = 0;
    return result;
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: fgets() — stdio variant
 * ────────────────────────────────────────────────────────────────────── */
char *fgets(char *s, int size, FILE *stream) {
    ensure_real_syms();
    if (in_hook || !g_initialized)
        return real_fgets(s, size, stream);

    in_hook = 1;
    char *result;

    int fd = fileno(stream);
    pthread_mutex_lock(&g_fd_table.lock);
    tracked_fd_t *e = fd_table_find(fd);
    if (e) {
        if (e->offset >= e->fake_len || size <= 1) {
            result = NULL;  /* EOF */
        } else {
            int max = size - 1;
            int i = 0;
            while (i < max && e->offset < e->fake_len) {
                s[i] = e->fake_buf[e->offset];
                e->offset++;
                i++;
                if (s[i - 1] == '\n') break;
            }
            s[i] = '\0';
            result = s;
        }
        pthread_mutex_unlock(&g_fd_table.lock);
    } else {
        pthread_mutex_unlock(&g_fd_table.lock);
        result = real_fgets(s, size, stream);
    }

    in_hook = 0;
    return result;
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: fclose() — stdio variant
 * ────────────────────────────────────────────────────────────────────── */
int fclose(FILE *stream) {
    ensure_real_syms();
    if (!in_hook && g_initialized) {
        int fd = fileno(stream);
        fd_table_untrack(fd);
    }
    return real_fclose(stream);
}
