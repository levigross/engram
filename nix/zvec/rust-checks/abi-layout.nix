# Compare real C header layouts with the patched repr(C) bindings, without
# linking the engine: size, alignment, and every non-union field's offset.
{ pkgs, src }:
pkgs.runCommand "zvec-rust-abi-layout-check"
  {
    nativeBuildInputs = [
      pkgs.stdenv.cc
      pkgs.rustc
    ];
  }
  ''
    $CC -std=c11 -I${pkgs.zvec-c.src}/src/include ${./abi-layout.c} -o c-layout
    rustc --edition=2021 --crate-type rlib --crate-name zvec_rust_sys \
      ${src}/zvec-sys/src/lib.rs -o libzvec_rust_sys.rlib
    rustc --edition=2021 ${./abi-layout.rs} \
      --extern zvec_rust_sys=$PWD/libzvec_rust_sys.rlib -o rust-layout
    ./c-layout > c-layout.txt
    ./rust-layout > rust-layout.txt
    diff -u c-layout.txt rust-layout.txt

    # Widen a real FFI field: the comparison must detect the incompatible layout.
    sed 's/pub num_chunk: c_int/pub num_chunk: i64/' ${src}/zvec-sys/src/lib.rs > wrong-sys.rs
    rustc --edition=2021 --crate-type rlib --crate-name zvec_rust_sys \
      wrong-sys.rs -o libwrong_sys.rlib
    rustc --edition=2021 ${./abi-layout.rs} \
      --extern zvec_rust_sys=$PWD/libwrong_sys.rlib -o wrong-layout
    ./wrong-layout > wrong-layout.txt
    if diff -u c-layout.txt wrong-layout.txt > control.diff; then
      echo "an incompatible Rust field layout was accepted" >&2
      exit 1
    fi
    mkdir $out
    cp c-layout.txt rust-layout.txt control.diff $out/
  ''
