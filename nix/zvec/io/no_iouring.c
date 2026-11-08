// no-iouring --errno ENOSYS|EPERM command [argument...]
//
// Runs a command as if the kernel had no io_uring: io_uring_setup, io_uring_enter and
// io_uring_register fail with the given error, in the command and in everything it starts.
// ENOSYS is what a kernel built without io_uring answers, EPERM what the sysctl
// kernel.io_uring_disabled and the seccomp profile of a container (Docker's default since 25.0)
// answer. The kernel's own io_uring code is not touched; a program can only tell the error.
//
// The error has to be named, so that a use says which of the two it means. The wrapper says
// "no-iouring: io_uring_setup fails with <error>" on stderr before it starts the command, so that
// the log of a run shows that it was under the filter. Before that it makes the call itself and
// requires that error: a filter that is not in effect ends in exit status 3 and no command.
// Exit status 2 is a wrong use.
#include <errno.h>
#include <seccomp.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static int usage(const char *self) {
  fprintf(stderr, "usage: %s --errno ENOSYS|EPERM command [argument...]\n", self);
  return 2;
}

int main(int argc, char **argv) {
  if (argc < 4 || strcmp(argv[1], "--errno") != 0) return usage(argv[0]);
  int error;
  if (strcmp(argv[2], "ENOSYS") == 0) {
    error = ENOSYS;
  } else if (strcmp(argv[2], "EPERM") == 0) {
    error = EPERM;
  } else {
    return usage(argv[0]);
  }

  // other calls go on; a call of another ABI than the native one is killed (libseccomp's default)
  scmp_filter_ctx filter = seccomp_init(SCMP_ACT_ALLOW);
  if (filter == NULL) {
    fputs("no-iouring: seccomp_init failed\n", stderr);
    return 1;
  }
  const int calls[] = {SCMP_SYS(io_uring_setup), SCMP_SYS(io_uring_enter),
                       SCMP_SYS(io_uring_register)};
  for (size_t i = 0; i < sizeof calls / sizeof calls[0]; i++) {
    int rc = seccomp_rule_add(filter, SCMP_ACT_ERRNO(error), calls[i], 0);
    if (rc < 0) {
      fprintf(stderr, "no-iouring: seccomp_rule_add: %s\n", strerror(-rc));
      return 1;
    }
  }
  // (loading also sets no_new_privs, so no privilege is needed)
  int rc = seccomp_load(filter);
  if (rc < 0) {
    fprintf(stderr, "no-iouring: seccomp_load: %s\n", strerror(-rc));
    return 1;
  }
  seccomp_release(filter);

  // a null params would be EFAULT if the call went through, and no ring is made in any case
  errno = 0;
  long made = syscall(__NR_io_uring_setup, 1, NULL);
  if (made != -1 || errno != error) {
    fprintf(stderr, "no-iouring: io_uring_setup gave %ld, errno %d (%s), and not %s: the filter is not in effect\n",
            made, errno, strerror(errno), argv[2]);
    return 3;
  }

  // the checks look for this line, to know that a run was under the filter
  fprintf(stderr, "no-iouring: io_uring_setup fails with %s\n", argv[2]);
  execvp(argv[3], argv + 3);
  perror(argv[3]);
  return 127;
}
