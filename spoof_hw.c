/*
 * spoof_hw.c — LD_PRELOAD shared library for hardware identity spoofing
 * Version: 0.01.0
 *
 * Hooks glibc open/read/close (and stdio variants) to intercept reads of
 * /proc/cpuinfo, sysfs PCIe speed, sysfs CPU topology.
 *
 * Self-cloaking features:
 *   - Strips LD_PRELOAD and config env vars from environment on init
 *   - Re-injects LD_PRELOAD into child processes via execve hook
 *   - Filters /proc/self/maps to hide library presence
 *   - Filters /proc/self/environ to hide config env vars
 *   - Hooks opendir/readdir to hide extra CPU directories
 *
 * Build: gcc -shared -fPIC -o libhwcompat.so spoof_hw.c -ldl -lpthread
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
#include <dirent.h>
#include <linux/limits.h>

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
static DIR    *(*real_opendir)(const char *);
static struct dirent *(*real_readdir)(DIR *);
static int     (*real_closedir)(DIR *);
static int     (*real_execve)(const char *, char *const[], char *const[]);

/*
 * Lazy-resolve real libc functions. Called before the constructor runs
 * (e.g., dynamic linker calls open() during startup). Without this,
 * the hooks dereference NULL function pointers -> SIGSEGV.
 */
static void ensure_real_syms(void) {
    if (!real_open) {
        real_open     = dlsym(RTLD_NEXT, "open");
        real_openat   = dlsym(RTLD_NEXT, "openat");
        real_read     = dlsym(RTLD_NEXT, "read");
        real_close    = dlsym(RTLD_NEXT, "close");
        real_lseek    = dlsym(RTLD_NEXT, "lseek");
        real_fopen    = dlsym(RTLD_NEXT, "fopen");
        real_fread    = dlsym(RTLD_NEXT, "fread");
        real_fgets    = dlsym(RTLD_NEXT, "fgets");
        real_fclose   = dlsym(RTLD_NEXT, "fclose");
        real_opendir  = dlsym(RTLD_NEXT, "opendir");
        real_readdir  = dlsym(RTLD_NEXT, "readdir");
        real_closedir = dlsym(RTLD_NEXT, "closedir");
        real_execve   = dlsym(RTLD_NEXT, "execve");
    }
}

/* ──────────────────────────────────────────────────────────────────────
 * Global state
 * ────────────────────────────────────────────────────────────────────── */
static spoof_config_t  g_config;
static fd_table_t      g_fd_table;
static int             g_initialized = 0;

/* Saved LD_PRELOAD value for re-injection into child processes */
static char g_saved_preload[PATH_MAX];

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

/* Recursion guard — per-thread */
static __thread int in_hook = 0;

/* Directory tracking for CPU dir hiding */
#define MAX_TRACKED_DIRS 8
static struct {
    DIR *dp;
    int  is_cpu_dir;
} g_dir_table[MAX_TRACKED_DIRS];
static pthread_mutex_t g_dir_lock = PTHREAD_MUTEX_INITIALIZER;

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
 * /proc/self/maps filtering — strip lines containing our library name
 * ────────────────────────────────────────────────────────────────────── */
static char   g_fake_maps[256 * 1024];  /* 256KB should hold any maps */
static size_t g_fake_maps_len;

static void generate_filtered_maps(void) {
    ensure_real_syms();

    int fd = real_open(PATH_PROC_MAPS, O_RDONLY, 0);
    if (fd < 0) return;

    /* Read the real maps into a temp buffer */
    char raw[256 * 1024];
    size_t total = 0;
    ssize_t n;
    while ((n = real_read(fd, raw + total, sizeof(raw) - total - 1)) > 0)
        total += (size_t)n;
    real_close(fd);
    raw[total] = '\0';

    /* Filter out lines containing our library name */
    size_t out = 0;
    char *line = raw;
    while (*line) {
        char *eol = strchr(line, '\n');
        size_t len = eol ? (size_t)(eol - line + 1) : strlen(line);

        if (!strstr(line, LIB_SELF_NAME)) {
            if (out + len < sizeof(g_fake_maps)) {
                memcpy(g_fake_maps + out, line, len);
                out += len;
            }
        }

        line += len;
    }

    g_fake_maps_len = out;
}

/* ──────────────────────────────────────────────────────────────────────
 * /proc/self/environ filtering — strip entries matching _MC_ or LD_PRELOAD
 * Environ is null-delimited, not newline-delimited.
 * ────────────────────────────────────────────────────────────────────── */
static char   g_fake_environ[64 * 1024];
static size_t g_fake_environ_len;

static void generate_filtered_environ(void) {
    ensure_real_syms();

    int fd = real_open(PATH_PROC_ENVIRON, O_RDONLY, 0);
    if (fd < 0) return;

    char raw[64 * 1024];
    size_t total = 0;
    ssize_t n;
    while ((n = real_read(fd, raw + total, sizeof(raw) - total)) > 0)
        total += (size_t)n;
    real_close(fd);

    /* Walk null-delimited entries, skip ones we want to hide */
    size_t out = 0;
    size_t pos = 0;
    while (pos < total) {
        const char *entry = raw + pos;
        size_t elen = strlen(entry);

        int hide = 0;
        if (strncmp(entry, "_MC_", 4) == 0) hide = 1;
        if (strncmp(entry, "LD_PRELOAD=", 11) == 0) hide = 1;

        if (!hide && elen > 0) {
            if (out + elen + 1 < sizeof(g_fake_environ)) {
                memcpy(g_fake_environ + out, entry, elen + 1); /* include null */
                out += elen + 1;
            }
        }

        pos += elen + 1;
    }

    g_fake_environ_len = out;
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

    /* Self-cloaking: /proc/self/maps */
    if (g_config.cloak && strcmp(path, PATH_PROC_MAPS) == 0)
        return SPOOF_PROC_MAPS;

    /* Self-cloaking: /proc/self/environ */
    if (g_config.cloak && strcmp(path, PATH_PROC_ENVIRON) == 0)
        return SPOOF_PROC_ENVIRON;

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
        case SPOOF_PROC_MAPS:
            /* Regenerate on each open for freshness */
            generate_filtered_maps();
            buf = g_fake_maps; len = g_fake_maps_len; break;
        case SPOOF_PROC_ENVIRON:
            generate_filtered_environ();
            buf = g_fake_environ; len = g_fake_environ_len; break;
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
    real_open     = dlsym(RTLD_NEXT, "open");
    real_openat   = dlsym(RTLD_NEXT, "openat");
    real_read     = dlsym(RTLD_NEXT, "read");
    real_close    = dlsym(RTLD_NEXT, "close");
    real_lseek    = dlsym(RTLD_NEXT, "lseek");
    real_fopen    = dlsym(RTLD_NEXT, "fopen");
    real_fread    = dlsym(RTLD_NEXT, "fread");
    real_fgets    = dlsym(RTLD_NEXT, "fgets");
    real_fclose   = dlsym(RTLD_NEXT, "fclose");
    real_opendir  = dlsym(RTLD_NEXT, "opendir");
    real_readdir  = dlsym(RTLD_NEXT, "readdir");
    real_closedir = dlsym(RTLD_NEXT, "closedir");
    real_execve   = dlsym(RTLD_NEXT, "execve");

    /* Read config from innocuously-named env vars */
    g_config.cpu      = env_bool("_MC_C", 1);
    g_config.pcie     = env_bool("_MC_P", 1);
    g_config.topology = env_bool("_MC_T", 1);
    g_config.cloak    = env_bool("_MC_K", 1);
    g_config.log      = env_bool("_MC_L", 0);

    /* Self-cloak: save LD_PRELOAD for re-injection, then strip from env.
     * We zero the string data in-place first (so programs reading from the
     * envp parameter to main() also see blanks), then formally unsetenv().
     * The execve hook re-injects LD_PRELOAD so child processes still load us. */
    g_saved_preload[0] = '\0';
    if (g_config.cloak) {
        const char *preload = getenv("LD_PRELOAD");
        if (preload) {
            strncpy(g_saved_preload, preload, sizeof(g_saved_preload) - 1);
            g_saved_preload[sizeof(g_saved_preload) - 1] = '\0';
        }

        /* Zero string content in-place (fools envp-based readers like bash) */
        extern char **environ;
        if (environ) {
            for (int i = 0; environ[i]; i++) {
                if (strncmp(environ[i], "LD_PRELOAD=", 11) == 0 ||
                    strncmp(environ[i], "_MC_", 4) == 0) {
                    memset(environ[i], 0, strlen(environ[i]));
                }
            }
        }
        /* Formally remove from environ array */
        unsetenv("LD_PRELOAD");
        unsetenv("_MC_C");
        unsetenv("_MC_P");
        unsetenv("_MC_T");
        unsetenv("_MC_K");
        unsetenv("_MC_L");
    }

    /* Init FD table */
    fd_table_init();

    /* Init dir table */
    for (int i = 0; i < MAX_TRACKED_DIRS; i++)
        g_dir_table[i].dp = NULL;

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
    snprintf(cache_buf, sizeof(cache_buf), "%s\n", SPOOFED_L3_CACHE);
    g_fake_cache_size     = cache_buf;
    g_fake_cache_size_len = strlen(cache_buf);

    LOG("initialized — cpu=%d pcie=%d topology=%d cloak=%d",
        g_config.cpu, g_config.pcie, g_config.topology, g_config.cloak);
    if (g_fake_cpuinfo_len > 0)
        LOG("fake cpuinfo: %zu bytes, %d processors", g_fake_cpuinfo_len, SPOOFED_THREADS);
}

/* ──────────────────────────────────────────────────────────────────────
 * Hooked: execve() — re-inject LD_PRELOAD into child processes
 *
 * When cloaking is active, we strip LD_PRELOAD from our environment so
 * it's invisible to checks. But child processes need it to load our
 * library. This hook transparently injects LD_PRELOAD into the envp
 * array before calling the real execve.
 * ────────────────────────────────────────────────────────────────────── */
int execve(const char *pathname, char *const argv[], char *const envp[]) {
    ensure_real_syms();

    /* If cloaking is off or no saved preload, pass through */
    if (!g_config.cloak || g_saved_preload[0] == '\0')
        return real_execve(pathname, argv, envp);

    /* Count existing envp entries and check if LD_PRELOAD is already there */
    int count = 0;
    int has_preload = 0;
    if (envp) {
        for (count = 0; envp[count]; count++) {
            if (strncmp(envp[count], "LD_PRELOAD=", 11) == 0)
                has_preload = 1;
        }
    }

    if (has_preload)
        return real_execve(pathname, argv, envp);

    /* Build new envp with LD_PRELOAD injected */
    static char preload_entry[PATH_MAX + 16];
    snprintf(preload_entry, sizeof(preload_entry), "LD_PRELOAD=%s", g_saved_preload);

    /* Allocate on stack for small env, heap for large */
    char **new_envp;
    char *stack_envp[256];
    if (count + 2 <= 256) {
        new_envp = stack_envp;
    } else {
        new_envp = malloc((count + 2) * sizeof(char *));
        if (!new_envp)
            return real_execve(pathname, argv, envp);
    }

    /* Copy existing entries + add LD_PRELOAD */
    new_envp[0] = preload_entry;
    for (int i = 0; i < count; i++)
        new_envp[i + 1] = (char *)envp[i];
    new_envp[count + 1] = NULL;

    int ret = real_execve(pathname, argv, new_envp);

    /* If execve returns, it failed — clean up if we malloc'd */
    int saved_errno = errno;
    if (new_envp != stack_envp)
        free(new_envp);
    errno = saved_errno;
    return ret;
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
            LOG("open(%s) -> fd %d, spoof type %d", pathname, fd, type);
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
            LOG("openat(%s) -> fd %d, spoof type %d", pathname, fd, type);
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
        LOG("read(fd=%d) -> served %zd fake bytes", fd, result);
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
            LOG("fopen(%s) -> fd %d, spoof type %d", pathname, fd, type);
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

/* ──────────────────────────────────────────────────────────────────────
 * Directory hooks — hide cpuNN directories where NN >= SPOOFED_THREADS
 *
 * This makes `ls /sys/devices/system/cpu/` show cpu0-cpu15 only,
 * hiding the real cpu16-cpu23.
 * ────────────────────────────────────────────────────────────────────── */

/* Check if a CPU directory entry should be hidden */
static int should_hide_cpu_entry(const char *name) {
    /* Match cpuNN where NN is a number */
    if (strncmp(name, "cpu", 3) != 0) return 0;
    const char *p = name + 3;
    if (*p < '0' || *p > '9') return 0;

    int num = 0;
    while (*p >= '0' && *p <= '9') {
        num = num * 10 + (*p - '0');
        p++;
    }
    if (*p != '\0') return 0;  /* not a pure cpuNN entry */

    return num >= SPOOFED_THREADS;
}

DIR *opendir(const char *name) {
    ensure_real_syms();
    if (in_hook || !g_initialized || !g_config.topology || !g_config.cloak)
        return real_opendir(name);

    in_hook = 1;
    DIR *dp = real_opendir(name);

    /* Match with or without trailing slash */
    size_t nlen = strlen(name);
    size_t plen = strlen(PATH_CPU_DIR);
    int is_cpu_path = (strcmp(name, PATH_CPU_DIR) == 0) ||
                      (nlen == plen + 1 && strncmp(name, PATH_CPU_DIR, plen) == 0
                       && name[plen] == '/');
    if (dp && is_cpu_path) {
        pthread_mutex_lock(&g_dir_lock);
        for (int i = 0; i < MAX_TRACKED_DIRS; i++) {
            if (g_dir_table[i].dp == NULL) {
                g_dir_table[i].dp = dp;
                g_dir_table[i].is_cpu_dir = 1;
                break;
            }
        }
        pthread_mutex_unlock(&g_dir_lock);
        LOG("opendir(%s) -> tracked for CPU dir filtering", name);
    }

    in_hook = 0;
    return dp;
}

struct dirent *readdir(DIR *dirp) {
    ensure_real_syms();
    if (in_hook || !g_initialized)
        return real_readdir(dirp);

    /* Check if this is a tracked CPU directory */
    int is_cpu = 0;
    pthread_mutex_lock(&g_dir_lock);
    for (int i = 0; i < MAX_TRACKED_DIRS; i++) {
        if (g_dir_table[i].dp == dirp) {
            is_cpu = g_dir_table[i].is_cpu_dir;
            break;
        }
    }
    pthread_mutex_unlock(&g_dir_lock);

    if (!is_cpu)
        return real_readdir(dirp);

    /* Skip entries for hidden CPUs */
    in_hook = 1;
    struct dirent *entry;
    while ((entry = real_readdir(dirp)) != NULL) {
        if (!should_hide_cpu_entry(entry->d_name))
            break;
        LOG("readdir: hiding %s", entry->d_name);
    }
    in_hook = 0;
    return entry;
}

int closedir(DIR *dirp) {
    ensure_real_syms();
    if (!in_hook && g_initialized) {
        pthread_mutex_lock(&g_dir_lock);
        for (int i = 0; i < MAX_TRACKED_DIRS; i++) {
            if (g_dir_table[i].dp == dirp) {
                g_dir_table[i].dp = NULL;
                g_dir_table[i].is_cpu_dir = 0;
                break;
            }
        }
        pthread_mutex_unlock(&g_dir_lock);
    }
    return real_closedir(dirp);
}
