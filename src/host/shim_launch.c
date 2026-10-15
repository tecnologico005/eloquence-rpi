#define _GNU_SOURCE
#include "shim_launch.h"
#include "eci_proto.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <dlfcn.h>
#include <time.h>
#include <errno.h>

static char g_socket_path[256];
static char g_bridge_dir[256];  /* directory containing eci-bridge + sysroot */

const char *shim_get_socket_path(void)
{
    if (g_socket_path[0]) return g_socket_path;

    const char *env = getenv(SOCKET_PATH_ENV);
    if (env) {
        snprintf(g_socket_path, sizeof(g_socket_path), "%s", env);
        return g_socket_path;
    }
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (runtime)
        snprintf(g_socket_path, sizeof(g_socket_path), "%s/%s", runtime, DEFAULT_SOCKET_NAME);
    else
        snprintf(g_socket_path, sizeof(g_socket_path), "/tmp/%s", DEFAULT_SOCKET_NAME);
    return g_socket_path;
}

/* Find the bridge directory: where eci-bridge + sysroot live.
 * 3-tier resolution:
 *   1. ECI_BRIDGE_DIR env var (explicit override)
 *   2. dladdr — directory of this .so (works for dev/build dir)
 *   3. /usr/share/eloquence (system install fallback)
 */
static const char *get_bridge_dir(void)
{
    if (g_bridge_dir[0]) return g_bridge_dir;

    /* Tier 1: explicit env override */
    const char *env = getenv("ECI_BRIDGE_DIR");
    if (env && env[0]) {
        snprintf(g_bridge_dir, sizeof(g_bridge_dir), "%s", env);
        return g_bridge_dir;
    }

    /* Tier 2: dladdr — look for eci-bridge next to the .so */
    Dl_info info;
    if (dladdr((void *)shim_get_socket_path, &info) && info.dli_fname) {
        char dldir[256];
        snprintf(dldir, sizeof(dldir), "%s", info.dli_fname);
        char *slash = strrchr(dldir, '/');
        if (slash) *slash = '\0';
        else strcpy(dldir, ".");

        char probe[512];
        snprintf(probe, sizeof(probe), "%s/eci-bridge", dldir);
        if (access(probe, X_OK) == 0) {
            snprintf(g_bridge_dir, sizeof(g_bridge_dir), "%s", dldir);
            return g_bridge_dir;
        }
    }

    /* Tier 3: system install path */
    strcpy(g_bridge_dir, "/usr/share/eloquence");
    return g_bridge_dir;
}

static int check_socket_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && (st.st_mode & S_IFSOCK);
}

static int check_bridge_running(void)
{
    const char *sock = shim_get_socket_path();
    if (!check_socket_exists(sock)) return 0;

    /* Try connecting */
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock, sizeof(addr.sun_path) - 1);
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    close(fd);
    return rc == 0;
}

/* ---- Launch modes -------------------------------------------------------
 *
 * qemu   : run the 32-bit ARM bridge under qemu-arm with a private Debian
 *          armhf sysroot (the only option on x86_64 hosts).
 * native : run the 32-bit ARM bridge directly. Used on ARM hosts such as the
 *          Raspberry Pi (32-bit Raspberry Pi OS, or 64-bit Raspberry Pi OS
 *          with the armhf multiarch libraries installed). The patched
 *          Eloquence libraries live in <bridge dir>/native/.
 *
 * ECI_BRIDGE_MODE=qemu|native forces one; the default is "auto".
 */
enum launch_mode { MODE_AUTO, MODE_QEMU, MODE_NATIVE };

static enum launch_mode requested_mode(void)
{
    const char *m = getenv("ECI_BRIDGE_MODE");
    if (m && !strcmp(m, "qemu"))   return MODE_QEMU;
    if (m && !strcmp(m, "native")) return MODE_NATIVE;
    return MODE_AUTO;
}

static int host_is_arm(void)
{
#if defined(__arm__) || defined(__aarch64__)
    return 1;
#else
    return 0;
#endif
}

/* Can this machine start a 32-bit ARM hard-float ELF without an emulator? */
static int armhf_loader_present(void)
{
    static const char *const loaders[] = {
        "/lib/ld-linux-armhf.so.3",
        "/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3",
        "/usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3",
    };
    for (size_t i = 0; i < sizeof(loaders) / sizeof(loaders[0]); i++)
        if (access(loaders[i], X_OK) == 0) return 1;
    return 0;
}

static int find_qemu(char *out, size_t n)
{
    if (access("/usr/bin/qemu-arm", X_OK) == 0)        snprintf(out, n, "/usr/bin/qemu-arm");
    else if (access("/usr/local/bin/qemu-arm", X_OK) == 0) snprintf(out, n, "/usr/local/bin/qemu-arm");
    else snprintf(out, n, "qemu-arm"); /* hope it's in PATH */
    return 0;
}

static void redirect_child_stdio(const char *dir)
{
    /* Log next to the bridge if writable, else XDG_RUNTIME_DIR or /tmp */
    char logpath[512];
    snprintf(logpath, sizeof(logpath), "%s/eci-bridge.log", dir);
    if (access(dir, W_OK) != 0) {
        const char *rtdir = getenv("XDG_RUNTIME_DIR");
        if (rtdir)
            snprintf(logpath, sizeof(logpath), "%s/eci-bridge.log", rtdir);
        else
            snprintf(logpath, sizeof(logpath), "/tmp/eci-bridge.log");
    }
    freopen(logpath, "a", stderr);
    freopen("/dev/null", "r", stdin);
    freopen("/dev/null", "w", stdout);
}

int shim_launch_bridge(void)
{
    if (check_bridge_running()) return 0;

    const char *dir = get_bridge_dir();
    char bridge_path[512], sysroot_path[512];
    char nat_lib[512], nat_libdir[512], nat_sjlj[512], nat_ini[512];
    snprintf(bridge_path, sizeof(bridge_path), "%s/eci-bridge", dir);
    snprintf(sysroot_path, sizeof(sysroot_path), "%s/sysroot/armhf", dir);
    snprintf(nat_libdir, sizeof(nat_libdir), "%s/native/lib", dir);
    snprintf(nat_lib,  sizeof(nat_lib),  "%s/native/lib/libeci.so", dir);
    snprintf(nat_sjlj, sizeof(nat_sjlj), "%s/native/lib/libsjlj_compat.so", dir);
    snprintf(nat_ini,  sizeof(nat_ini),  "%s/native/eci.ini", dir);

    /* Check bridge binary exists */
    if (access(bridge_path, X_OK) < 0) {
        fprintf(stderr, "shim: bridge not found at %s\n", bridge_path);
        return -1;
    }

    char qemu_path[256];
    find_qemu(qemu_path, sizeof(qemu_path));

    int have_native_files = access(nat_lib, R_OK) == 0 &&
                            access(nat_sjlj, R_OK) == 0 &&
                            access(nat_ini, R_OK) == 0;
    int have_sysroot = access(sysroot_path, X_OK) == 0;

    enum launch_mode mode = requested_mode();
    if (mode == MODE_AUTO) {
        if (host_is_arm() && have_native_files && armhf_loader_present())
            mode = MODE_NATIVE;
        else if (host_is_arm() && !have_sysroot) {
            /* Nothing usable: say exactly what is missing. */
            if (!have_native_files)
                fprintf(stderr, "shim: no Eloquence data found in %s/native -- run 'sudo eloquence-setup'\n", dir);
            else
                fprintf(stderr, "shim: this system cannot run 32-bit ARM programs. On 64-bit "
                                "Raspberry Pi OS run:\n"
                                "  sudo dpkg --add-architecture armhf && sudo apt update && "
                                "sudo apt install libc6:armhf libstdc++6:armhf\n");
            return -1;
        } else
            mode = MODE_QEMU;
    }

    if (mode == MODE_NATIVE) {
        if (!have_native_files) {
            fprintf(stderr, "shim: native mode needs %s, %s and %s -- run 'sudo eloquence-setup'\n",
                    nat_lib, nat_sjlj, nat_ini);
            return -1;
        }
        if (!armhf_loader_present()) {
            fprintf(stderr, "shim: no armhf dynamic loader found. On 64-bit Raspberry Pi OS run:\n"
                            "  sudo dpkg --add-architecture armhf && sudo apt update && "
                            "sudo apt install libc6:armhf libstdc++6:armhf\n");
            return -1;
        }
    }

    /* Set socket path in environment so bridge uses it */
    const char *sock = shim_get_socket_path();
    setenv(SOCKET_PATH_ENV, sock, 1);

    if (mode == MODE_NATIVE)
        fprintf(stderr, "shim: launching bridge natively: %s %s\n", bridge_path, nat_lib);
    else
        fprintf(stderr, "shim: launching bridge: %s -L %s %s\n",
                qemu_path, sysroot_path, bridge_path);

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return -1;
    }
    if (pid == 0) {
        /* Child: daemonize */
        setsid();
        redirect_child_stdio(dir);

        /* The old Eloquence libraries use setjmp-based C++ exception
         * handling, which modern libstdc++/libgcc do not provide; a stub
         * library supplies the missing symbols (LD_PRELOAD).
         * ECIINI tells the ECI library where its config file is. */
        if (mode == MODE_NATIVE) {
            setenv("LD_PRELOAD", nat_sjlj, 1);
            setenv("LD_LIBRARY_PATH", nat_libdir, 1);
            setenv("ECIINI", nat_ini, 1);
            execl(bridge_path, bridge_path, nat_lib, (char *)NULL);
            perror("exec eci-bridge");
        } else {
            execlp(qemu_path, qemu_path,
                   "-L", sysroot_path,
                   "-E", "LD_PRELOAD=/usr/lib/libsjlj_compat.so",
                   "-E", "ECIINI=/etc/eci.ini",
                   bridge_path, (char *)NULL);
            perror("exec qemu-arm");
        }
        _exit(1);
    }

    /* Parent: wait for socket to appear */
    for (int i = 0; i < 40; i++) { /* up to 4 seconds */
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 100000000 }; /* 100ms */
        nanosleep(&ts, NULL);
        if (check_bridge_running()) {
            fprintf(stderr, "shim: bridge started (pid %d)\n", pid);
            return 0;
        }
    }

    fprintf(stderr, "shim: bridge failed to start within 4 seconds (see eci-bridge.log)\n");
    kill(pid, SIGTERM);
    return -1;
}
