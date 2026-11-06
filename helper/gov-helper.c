/*
 * gov-helper.c
 *
 * Narrow setuid-root helper for HardwareMonitor.
 *
 * DSM 7 forbids third-party packages from declaring run-as: root, so the
 * package runs as its service account. conf/privilege installs this binary
 * root:<package-group> 6550, which means only the package's own group can run
 * it. It accepts exactly one core (cpuN) and one governor name, checks the
 * name against the kernel's scaling_available_governors, and writes
 * scaling_governor. Nothing else is writable.
 *
 * This is deliberately freestanding: no libc, no dynamic loader, no glibc
 * version dependency. Build with
 *   gcc -nostdlib -static -no-pie -O2 -o gov-helper gov-helper.c
 * and add -DGOV_HELPER_TEST for the fixture test, which honours
 * GOV_HELPER_ROOT. Production builds never read the environment.
 */
#include <stddef.h>
#include <stdint.h>

#if defined(__x86_64__)
#define SYS_READ 0
#define SYS_WRITE 1
#define SYS_CLOSE 3
#define SYS_OPENAT 257
#define SYS_EXIT 60
#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_TRUNC 512

static long sc4(long n, long a, long b, long c, long d)
{
    long r;
    register long r10 __asm__("r10") = d;
    __asm__ volatile("syscall"
                     : "=a"(r)
                     : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10)
                     : "rcx", "r11", "memory");
    return r;
}

__attribute__((naked, noreturn)) void _start(void)
{
    __asm__ volatile(
        "xor %rbp, %rbp\n"
        "mov (%rsp), %rdi\n"
        "lea 8(%rsp), %rsi\n"
        "lea 16(%rsp,%rdi,8), %rdx\n"
        "call main\n"
        "mov %eax, %edi\n"
        "mov $60, %eax\n"
        "syscall\n"
        "hlt\n");
}
#elif defined(__aarch64__)
#define SYS_READ 63
#define SYS_WRITE 64
#define SYS_CLOSE 57
#define SYS_OPENAT 56
#define SYS_EXIT 93
#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_TRUNC 512

static long sc4(long n, long a, long b, long c, long d)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
}

__attribute__((naked, noreturn)) void _start(void)
{
    __asm__ volatile(
        "mov x0, sp\n"
        "ldr x1, [x0], #8\n"
        "mov x2, x0\n"
        "add x3, x2, x1, lsl #3\n"
        "add x3, x3, #8\n"
        "mov x0, x1\n"
        "mov x1, x2\n"
        "mov x2, x3\n"
        "bl main\n"
        "mov x8, #93\n"
        "svc #0\n");
}
#else
#error "gov-helper supports x86_64 and aarch64 only"
#endif

static long sys_read(int fd, void *buf, size_t n)
{
    return sc4(SYS_READ, fd, (long)buf, (long)n, 0);
}

static long sys_write(int fd, const void *buf, size_t n)
{
    return sc4(SYS_WRITE, fd, (long)buf, (long)n, 0);
}

static long sys_openat(const char *path, long flags)
{
    return sc4(SYS_OPENAT, AT_FDCWD, (long)path, flags, 0);
}

static long sys_close(int fd)
{
    return sc4(SYS_CLOSE, fd, 0, 0, 0);
}

static size_t slen(const char *s)
{
    size_t n = 0;

    while (s[n] != '\0') {
        n++;
    }
    return n;
}

static int sncmp(const char *a, const char *b, size_t n)
{
    size_t i;

    for (i = 0; i < n; i++) {
        if (a[i] != b[i]) {
            return 1;
        }
        if (a[i] == '\0') {
            return 0;
        }
    }
    return 0;
}

static int is_digit(char c)
{
    return c >= '0' && c <= '9';
}

static int is_alnum(char c)
{
    return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static int valid_cpu(const char *c)
{
    size_t i;
    size_t n = slen(c);

    if (n < 4 || n > 64 || c[0] != 'c' || c[1] != 'p' || c[2] != 'u') {
        return 0;
    }
    for (i = 3; i < n; i++) {
        if (!is_digit(c[i])) {
            return 0;
        }
    }
    return 1;
}

static int valid_gov(const char *g)
{
    size_t i;
    size_t n = slen(g);

    if (n == 0 || n > 64) {
        return 0;
    }
    for (i = 0; i < n; i++) {
        if (!is_alnum(g[i]) && g[i] != '_' && g[i] != '-') {
            return 0;
        }
    }
    return 1;
}

static int append(char *dst, size_t cap, const char *src)
{
    size_t used = slen(dst);
    size_t n = slen(src);

    if (used + n + 1 > cap) {
        return 0;
    }
    while (n-- > 0) {
        dst[used++] = *src++;
    }
    dst[used] = '\0';
    return 1;
}

static int build_dir(char *dst, size_t cap, const char *root, const char *cpu)
{
    dst[0] = '\0';
    return append(dst, cap, root) &&
           append(dst, cap, "/sys/devices/system/cpu/") &&
           append(dst, cap, cpu) &&
           append(dst, cap, "/cpufreq");
}

static int read_first(int fd, char *buf, size_t cap)
{
    long n;

    if (cap < 2) {
        return 0;
    }
    n = sys_read(fd, buf, cap - 1);
    if (n <= 0) {
        return 0;
    }
    buf[n] = '\0';
    return 1;
}

static int is_available(const char *dir, const char *gov)
{
    char path[512];
    char buf[1024];
    char *p;
    size_t want = slen(gov);
    long fd;

    path[0] = '\0';
    if (!append(path, sizeof(path), dir) ||
        !append(path, sizeof(path), "/scaling_available_governors")) {
        return 0;
    }
    fd = sys_openat(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }
    if (!read_first((int)fd, buf, sizeof(buf))) {
        sys_close((int)fd);
        return 0;
    }
    sys_close((int)fd);

    p = buf;
    while (*p != '\0') {
        char *start;

        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
            p++;
        }
        start = p;
        while (*p != '\0' && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') {
            p++;
        }
        if ((size_t)(p - start) == want && sncmp(start, gov, want) == 0) {
            return 1;
        }
    }
    return 0;
}

static int write_gov(const char *dir, const char *gov)
{
    char path[512];
    char buf[128];
    size_t n = slen(gov);
    size_t i;
    long fd;
    long w;

    if (n == 0 || n + 1 >= sizeof(buf)) {
        return 0;
    }
    path[0] = '\0';
    if (!append(path, sizeof(path), dir) ||
        !append(path, sizeof(path), "/scaling_governor")) {
        return 0;
    }
    for (i = 0; i < n; i++) {
        buf[i] = gov[i];
    }
    buf[n] = '\n';

    fd = sys_openat(path, O_WRONLY | O_TRUNC);
    if (fd < 0) {
        return 0;
    }
    /* sysfs validates every write() call on its own. Sending the newline in a
     * second write would be parsed as an empty governor and fail even though
     * the first write already changed the governor. Write both in one call. */
    w = sys_write((int)fd, buf, n + 1);
    sys_close((int)fd);
    return w == (long)(n + 1);
}

static void put(int fd, const char *s)
{
    sys_write(fd, s, slen(s));
}

#ifdef GOV_HELPER_TEST
static const char *env_root(char **envp)
{
    size_t want = 15; /* strlen("GOV_HELPER_ROOT") */

    for (; *envp != NULL; envp++) {
        if (sncmp(*envp, "GOV_HELPER_ROOT", want) == 0 && (*envp)[want] == '=') {
            return *envp + want + 1;
        }
    }
    return "";
}
#endif

int main(int argc, char **argv, char **envp)
{
    const char *root = "";
    char dir[512];

    (void)envp;
#ifdef GOV_HELPER_TEST
    root = env_root(envp);
#endif

    if (argc != 3) {
        put(2, "usage: gov-helper <cpuN> <governor>\n");
        return 2;
    }
    if (!valid_cpu(argv[1]) || !valid_gov(argv[2])) {
        put(2, "gov-helper: invalid argument\n");
        return 2;
    }
    if (!build_dir(dir, sizeof(dir), root, argv[1])) {
        put(2, "gov-helper: path too long\n");
        return 2;
    }
    if (!is_available(dir, argv[2]) || !write_gov(dir, argv[2])) {
        put(1, "0 1\n");
        return 1;
    }
    put(1, "1 0\n");
    return 0;
}
