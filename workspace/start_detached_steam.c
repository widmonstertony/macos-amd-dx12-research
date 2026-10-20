/* A scoped POSIX app launcher: only our guarded Steam login session.
 * Double-fork/setsid plus redirected descriptors separate GUI lifetime from
 * a terminal/tool turn. No shell interpolation, other apps, or restart loop. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 3 || argv[1][0] != '/' || argv[2][0] != '/') return 2;
    int pipefd[2];
    if (pipe(pipefd)) return 3;
    if (fcntl(pipefd[1], F_SETFD, FD_CLOEXEC)) return 3;
    pid_t child = fork();
    if (child < 0) return 4;
    if (!child) {
        close(pipefd[0]);
        if (setsid() < 0) goto failed;
        pid_t app = fork();
        if (app < 0) goto failed;
        if (app) _exit(0);
        signal(SIGHUP, SIG_IGN);
        int input = open("/dev/null", O_RDONLY);
        int output = open(argv[2], O_WRONLY|O_CREAT|O_APPEND, 0600);
        if (input < 0 || output < 0) goto failed;
        if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0 ||
            dup2(output, STDERR_FILENO) < 0) goto failed;
        if (input > 2) close(input);
        if (output > 2) close(output);
        execl("/bin/bash", "/bin/bash", argv[1], "steam-session", (char *)0);
failed: {
        int error = errno;
        (void)write(pipefd[1], &error, sizeof(error));
        _exit(127);
    }
    }
    close(pipefd[1]);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    int error = 0;
    ssize_t bytes;
    do { bytes = read(pipefd[0], &error, sizeof(error)); } while (bytes < 0 && errno == EINTR);
    close(pipefd[0]);
    if (!WIFEXITED(status) || WEXITSTATUS(status) || bytes != 0) {
        fprintf(stderr, "Detached app exec failed: %s\n", strerror(error ? error : EIO));
        return 5;
    }
    puts("Guarded interactive Steam launcher started; no timeout supervisor.");
    return 0;
}
