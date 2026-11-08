# zvec's unit tests of the libraries that need no Arrow: ailego, core and turbo.
# What skips and why, and the one test that is run again: docs/zvec.md#checks.
{ pkgs, io }:

let
  # skip themselves where a ring cannot be made (iouring_loader_test.cc), where libaio cannot be
  # loaded (diskann_libaio_lifetime_test.cc), and where there is no async backend at all
  # (vector_page_table_test.cc)
  noRing = [
    "IoUringLoaderTest.ReadsBatchAndZeroPadsExpectedShortRead"
    "IoUringLoaderTest.WritesScatteredBatch"
  ];
  noLibaio = [ "DiskAnnLibAioDeathTest.WorkerContextOutlivesStaticDestructors" ];
  noAsyncBackend = [ "BufferPoolTest.AioAdmissionUsesFreeCapacityBeforeEviction" ];
in
import ./suite.nix {
  inherit pkgs io;
  name = "core";
  dirs = [
    "ailego"
    "core"
    "turbo"
  ];
  # on the library path in the default mode, so that the tests of the code that loads it run
  libraries = [ pkgs.libaio ];

  # disabled upstream (GTEST_SKIP first), and the tests of the NEON kernels of turbo
  skipped = [
    "ThreadQueue.MultiThreadWithHighPriority"
    "FlatStreamerTest.TestMaxIndexSize"
    "HnswStreamerTest.TestMaxIndexSize"
    "HnswSparseStreamerTest.TestMaxIndexSize"
    "Fp16Quantizer.AutoDispatchSelectsNeonFp16"
    "Fp16Quantizer.NeonBatchMatchesSingleAcrossBoundaries"
    "Fp16Quantizer.NeonCosineRetainsFp16Arithmetic"
    "Fp16Quantizer.NeonDistanceMatchesScalar"
    "Fp16Quantizer.NeonDistancesPreserveFp32Range"
    "Fp32Quantizer.NeonDistanceMatchesScalar"
    "NeonBatch.AutoDispatchIncludesRawUniformAndSdc"
    "NeonDistance.DispatchProvidesAllKernels"
    "NeonDistance.Fp16AccumulatesInFp32"
    "NeonDistance.Fp16MatchesScalarForRemainders"
    "NeonDistance.Fp32MatchesScalarForRemainders"
    "NeonDistance.RecordIntegerProductsMatchScalarForRemainders"
    "PqFastScanKernel.NeonMatchesScalar"
    "PqInt4SimdConsistency.NeonMatchesScalar"
    "PqInt8SimdConsistency.NeonMatchesScalar"
    "Backends/RawInt8Simd.FullSignedRangeTailsBatchesAndLongVectors/3"
  ];
  skippedIn = {
    libaio = noRing;
    pread = noRing ++ noLibaio ++ noAsyncBackend;
  };

  # upstream's CMake adds this one for WIN32 only
  notRegistered = [ "diskann_file_reader_windows_test" ];
  # fails now and then on its first run: docs/zvec.md#a-test-that-fails-on-its-first-run
  flaky = [ "diskann_mobile_compat_test" ];

  control = {
    file = "tests/ailego/utility/bit_string_helper_test.cc";
    from = "EXPECT_EQ(data_read, m);";
    to = "EXPECT_EQ(data_read, m + 1);";
    target = "bit_string_helper_test";
    dir = "ailego";
  };
}
