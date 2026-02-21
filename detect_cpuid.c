/*
 * detect_cpuid.c — Direct CPUID inline assembly reader
 * Version: 0.00.1
 *
 * Reads hardware identity straight from the CPU, immune to LD_PRELOAD.
 * Used by detect.sh to cross-check against spoofed /proc/cpuinfo values.
 *
 * Usage: ./detect_cpuid family|model|stepping|brand|has_vaes|all
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

static void cpuid(uint32_t leaf, uint32_t subleaf,
                  uint32_t *eax, uint32_t *ebx, uint32_t *ecx, uint32_t *edx) {
    __asm__ __volatile__(
        "cpuid"
        : "=a"(*eax), "=b"(*ebx), "=c"(*ecx), "=d"(*edx)
        : "a"(leaf), "c"(subleaf)
    );
}

static void get_family_model_stepping(int *family, int *model, int *stepping) {
    uint32_t eax, ebx, ecx, edx;
    cpuid(0x1, 0, &eax, &ebx, &ecx, &edx);

    int base_family = (eax >> 8) & 0xF;
    int base_model  = (eax >> 4) & 0xF;
    int ext_family   = (eax >> 20) & 0xFF;
    int ext_model    = (eax >> 16) & 0xF;

    *stepping = eax & 0xF;

    if (base_family == 0xF) {
        *family = base_family + ext_family;
        *model  = (ext_model << 4) | base_model;
    } else {
        *family = base_family;
        *model  = base_model;
    }
}

static void get_brand_string(char brand[49]) {
    uint32_t regs[12]; /* 3 leaves * 4 registers */
    int i;

    for (i = 0; i < 3; i++) {
        cpuid(0x80000002 + i, 0,
              &regs[i * 4 + 0], &regs[i * 4 + 1],
              &regs[i * 4 + 2], &regs[i * 4 + 3]);
    }
    memcpy(brand, regs, 48);
    brand[48] = '\0';

    /* Trim leading spaces */
    char *p = brand;
    while (*p == ' ') p++;
    if (p != brand)
        memmove(brand, p, strlen(p) + 1);
}

static int has_vaes(void) {
    uint32_t eax, ebx, ecx, edx;
    /* VAES: leaf 7, subleaf 0, ECX bit 9 */
    cpuid(0x7, 0, &eax, &ebx, &ecx, &edx);
    return (ecx >> 9) & 1;
}

static int has_vpclmulqdq(void) {
    uint32_t eax, ebx, ecx, edx;
    /* VPCLMULQDQ: leaf 7, subleaf 0, ECX bit 10 */
    cpuid(0x7, 0, &eax, &ebx, &ecx, &edx);
    return (ecx >> 10) & 1;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s family|model|stepping|brand|has_vaes|has_vpclmulqdq|all\n",
                argv[0]);
        return 1;
    }

    const char *cmd = argv[1];
    int family, model, stepping;
    char brand[49];

    if (strcmp(cmd, "family") == 0) {
        get_family_model_stepping(&family, &model, &stepping);
        printf("%d\n", family);
    } else if (strcmp(cmd, "model") == 0) {
        get_family_model_stepping(&family, &model, &stepping);
        printf("%d\n", model);
    } else if (strcmp(cmd, "stepping") == 0) {
        get_family_model_stepping(&family, &model, &stepping);
        printf("%d\n", stepping);
    } else if (strcmp(cmd, "brand") == 0) {
        get_brand_string(brand);
        printf("%s\n", brand);
    } else if (strcmp(cmd, "has_vaes") == 0) {
        printf("%d\n", has_vaes());
    } else if (strcmp(cmd, "has_vpclmulqdq") == 0) {
        printf("%d\n", has_vpclmulqdq());
    } else if (strcmp(cmd, "all") == 0) {
        get_family_model_stepping(&family, &model, &stepping);
        get_brand_string(brand);
        printf("brand:          %s\n", brand);
        printf("family:         %d\n", family);
        printf("model:          %d\n", model);
        printf("stepping:       %d\n", stepping);
        printf("has_vaes:       %d\n", has_vaes());
        printf("has_vpclmulqdq: %d\n", has_vpclmulqdq());
    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }

    return 0;
}
