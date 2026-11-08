// What the I/O of this process can use, as the kernel and zvec's library say it:
//   io_uring_setup: ok | ENOSYS | EPERM | errno N    a ring made by a call of our own
//   backend: io_uring | libaio | pread               what the C API selected
//   description: ...
// The library selects the backend the first time it is asked, so it is asked after our call.
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <zvec/c_api.h>

int main(void) {
  unsigned char params[120]; // struct io_uring_params, which the kernel fills in
  memset(params, 0, sizeof params);
  long fd = syscall(__NR_io_uring_setup, 1, params);
  if (fd >= 0) {
    puts("io_uring_setup: ok");
    close((int)fd);
  } else if (errno == ENOSYS) {
    puts("io_uring_setup: ENOSYS");
  } else if (errno == EPERM) {
    puts("io_uring_setup: EPERM");
  } else {
    printf("io_uring_setup: errno %d\n", errno);
  }

  zvec_io_backend_type_t type = zvec_get_io_backend_type();
  printf("backend: %s\n", zvec_get_io_backend_type_name(type));
  printf("description: %s\n", zvec_get_io_backend_description());
  return 0;
}
