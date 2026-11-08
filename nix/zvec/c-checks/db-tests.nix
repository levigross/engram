# zvec's unit tests of the database layer (tests/db), the code that the C API is.
{ pkgs, io }:

import ./suite.nix {
  inherit pkgs io;
  name = "db";
  dirs = [ "db" ];
  extraTargets = [
    "data_generator"
    "collection_optimizer"
  ];
  # kill processes and wait for time to pass
  serial = "recovery";
  # perf_bench_test skips its cases unless this is set; here on 5000 documents and one iteration
  # instead of 100000 and 30 (tests/db/sqlengine/perf_bench_test.cc)
  env = {
    ZVEC_RUN_PERF_BENCH = "1";
    ZVEC_PERF_DOC_COUNT = "5000";
    ZVEC_PERF_ITERATIONS = "1";
  };
  # tests/db/utf8_acp/CMakeLists.txt registers it for Windows with MSVC only
  notRegistered = [ "utf8_acp_test" ];

  control = {
    file = "tests/db/common/cgroup_util_test.cc";
    from = "EXPECT_EQ(1, cpu_cores);";
    to = "EXPECT_EQ(7, cpu_cores);";
    target = "cgroup_util_test";
    dir = "db";
  };
}
