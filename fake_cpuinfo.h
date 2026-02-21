/*
 * fake_cpuinfo.h — Generates /proc/cpuinfo for AMD Ryzen Threadripper 1900X
 * Version: 0.00.1
 *
 * Produces 16 processor blocks (8C/16T) with Zen 1 flags and bugs.
 * MHz randomized per-core via PRNG seeded from getpid().
 */
#ifndef FAKE_CPUINFO_H
#define FAKE_CPUINFO_H

#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Max buffer for full cpuinfo (16 cores * ~1KB each + margin) */
#define CPUINFO_BUF_SIZE  (32 * 1024)

/* Zen 1 (Threadripper 1900X) flags — Zen 3 features removed:
 * Removed: vaes vpclmulqdq rdpid user_shstk wbnoinvd rdpru
 *          v_spec_ctrl overflow_recov succor debug_swap mba
 */
#define ZEN1_FLAGS \
    "fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov " \
    "pat pse36 clflush mmx fxsr sse sse2 ht syscall nx mmxext fxsr_opt " \
    "pdpe1gb rdtscp lm constant_tsc rep_good nopl nonstop_tsc cpuid " \
    "extd_apicid aperfmperf rapl pni pclmulqdq monitor ssse3 fma cx16 " \
    "sse4_1 sse4_2 movbe popcnt aes xsave avx f16c rdrand lahf_lm " \
    "cmp_legacy svm extapic cr8_legacy abm sse4a misalignsse 3dnowprefetch " \
    "osvw skinit wdt tce topoext perfctr_core perfctr_nb bpext perfctr_llc " \
    "mwaitx cpb hw_pstate ssbd ibpb vmmcall fsgsbase bmi1 avx2 smep bmi2 " \
    "rdseed adx smap clflushopt sha xsaveopt xsavec xgetbv1 clzero irperf " \
    "xsaveerptr arat npt lbrv svm_lock nrip_save tsc_scale vmcb_clean " \
    "flushbyasid decodeassists pausefilter pfthreshold avic v_vmsave_vmload " \
    "vgif"

/* Zen 1 bugs — fewer than Zen 3 */
#define ZEN1_BUGS \
    "sysret_ss_attrs spectre_v1 spectre_v2 spec_store_bypass"

/*
 * Simple PRNG for per-core MHz jitter (nothing crypto, just variety).
 * Linear congruential — good enough for MHz values.
 */
static unsigned int _cpuinfo_prng_state;

static void cpuinfo_prng_seed(unsigned int seed) {
    _cpuinfo_prng_state = seed;
}

static unsigned int cpuinfo_prng_next(void) {
    _cpuinfo_prng_state = _cpuinfo_prng_state * 1103515245u + 12345u;
    return (_cpuinfo_prng_state >> 16) & 0x7FFF;
}

/* Returns a MHz value in [2200.000, 3800.000) */
static double cpuinfo_random_mhz(void) {
    return 2200.0 + (cpuinfo_prng_next() % 16000) / 10.0;
}

/*
 * generate_fake_cpuinfo() — fills buf with complete /proc/cpuinfo text
 *
 * APIC ID mapping for 8C/16T (2 threads per core, CCX-style):
 *   Core 0: apicid 0,1   Core 1: apicid 2,3   ... Core 7: apicid 14,15
 *   Processor 0-7 = first thread of each core (apicid 0,2,4,...,14)
 *   Processor 8-15 = second thread (apicid 1,3,5,...,15)
 *
 * Returns: length of generated text, or 0 on error
 */
static size_t generate_fake_cpuinfo(char *buf, size_t bufsize) {
    size_t pos = 0;
    int i;

    cpuinfo_prng_seed((unsigned int)getpid());

    for (i = 0; i < SPOOFED_THREADS; i++) {
        int core_id;
        int apicid;
        double mhz = cpuinfo_random_mhz();

        /* Processor 0-7 → first thread, 8-15 → HT sibling */
        if (i < SPOOFED_PHYS_CORES) {
            core_id = i;
            apicid  = i * 2;       /* 0, 2, 4, ..., 14 */
        } else {
            core_id = i - SPOOFED_PHYS_CORES;
            apicid  = core_id * 2 + 1;  /* 1, 3, 5, ..., 15 */
        }

        int written = snprintf(buf + pos, bufsize - pos,
            "processor\t: %d\n"
            "vendor_id\t: AuthenticAMD\n"
            "cpu family\t: %d\n"
            "model\t\t: %d\n"
            "model name\t: %s\n"
            "stepping\t: %d\n"
            "microcode\t: %s\n"
            "cpu MHz\t\t: %.3f\n"
            "cache size\t: 512 KB\n"
            "physical id\t: 0\n"
            "siblings\t: %d\n"
            "core id\t\t: %d\n"
            "cpu cores\t: %d\n"
            "apicid\t\t: %d\n"
            "initial apicid\t: %d\n"
            "fpu\t\t: yes\n"
            "fpu_exception\t: yes\n"
            "cpuid level\t: 13\n"
            "wp\t\t: yes\n"
            "flags\t\t: " ZEN1_FLAGS "\n"
            "bugs\t\t: " ZEN1_BUGS "\n"
            "bogomips\t: %s\n"
            "TLB size\t: 2560 4K pages\n"
            "clflush size\t: 64\n"
            "cache_alignment\t: 64\n"
            "address sizes\t: 48 bits physical, 48 bits virtual\n"
            "power management: ts ttp tm hwpstate cpb eff_freq_ro [13] [14]\n"
            "\n",
            i,                          /* processor */
            SPOOFED_CPU_FAMILY,         /* cpu family */
            SPOOFED_MODEL,              /* model */
            SPOOFED_MODEL_NAME,         /* model name */
            SPOOFED_STEPPING,           /* stepping */
            SPOOFED_MICROCODE,          /* microcode */
            mhz,                        /* cpu MHz */
            SPOOFED_SIBLINGS,           /* siblings */
            core_id,                    /* core id */
            SPOOFED_PHYS_CORES,         /* cpu cores */
            apicid,                     /* apicid */
            apicid,                     /* initial apicid */
            SPOOFED_BOGOMIPS            /* bogomips */
        );

        if (written < 0 || (size_t)written >= bufsize - pos)
            return 0;  /* buffer overflow */
        pos += (size_t)written;
    }

    return pos;
}

#endif /* FAKE_CPUINFO_H */
