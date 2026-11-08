// What the library says it is, through the functions of its C API, and what the version checks
// of that API make of it. The expected version is the argument, "v0.8.1" for instance.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zvec/c_api.h>

static int failures;

static void expect(int condition, const char *what) {
  if (!condition) {
    fprintf(stderr, "FAIL: %s\n", what);
    failures++;
  }
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s vMAJOR.MINOR.PATCH\n", argv[0]);
    return 2;
  }
  int major = 0, minor = 0, patch = 0;
  if (sscanf(argv[1], "v%d.%d.%d", &major, &minor, &patch) != 3) {
    fprintf(stderr, "%s is not vMAJOR.MINOR.PATCH\n", argv[1]);
    return 2;
  }

  const char *version = zvec_get_version();
  printf("zvec_get_version() = %s\n", version);
  printf("major.minor.patch  = %d.%d.%d\n", zvec_get_version_major(), zvec_get_version_minor(),
         zvec_get_version_patch());

  expect(strcmp(version, argv[1]) == 0, "zvec_get_version() is the version that is expected");
  expect(zvec_get_version_major() == major, "major");
  expect(zvec_get_version_minor() == minor, "minor");
  expect(zvec_get_version_patch() == patch, "patch");

  // "the library is at least this version"
  expect(zvec_check_version(major, minor, patch), "the library is at least its own version");
  expect(zvec_check_version(0, 0, 1), "the library is at least 0.0.1");
  expect(!zvec_check_version(major, minor, patch + 1), "the library is not at least the next patch");
  expect(!zvec_check_version(major, minor + 1, 0), "the library is not at least the next minor");
  expect(!zvec_check_version(major + 1, 0, 0), "the library is not at least the next major");

  if (failures) return 1;
  puts("version check OK");
  return 0;
}
