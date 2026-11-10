# What must work with the C interface of NeuG and the Rust crates made on it, each check with
# something that must fail, so that it cannot pass by accident.
{ pkgs, craneLib }:

let
  inherit (pkgs)
    lib
    neug
    neug-c
    chdb
    ;
  extensions = lib.escapeShellArgs neug.extensions;
  shim = ../../../bindings/neug-c;
  rust = import ../rust.nix { inherit pkgs craneLib; };
in
{
  # chDB and NeuG in one process. Each brings its own protobuf, abseil, glog and allocator, and
  # NeuG loads its extensions with dlopen: do they leave each other alone? The program runs
  # both, interleaved, with the extensions loaded between the queries of chDB and a thread in
  # each, and starts either engine first. The libraries are looked at (what each exports and
  # needs, with nm), and every binding of a symbol that the dynamic linker made is looked at
  # (LD_DEBUG=bindings). A library that interposes a name of chDB is the control: the check of
  # the bindings must fail on it.
  coexist =
    pkgs.runCommandCC "neug-coexist-check"
      {
        nativeBuildInputs = [
          pkgs.binutils
          pkgs.gawk
        ];
      }
      ''
        export HOME=$TMPDIR NEUG_DB_TMP_DIR=$TMPDIR GLOG_minloglevel=2
        cd $TMPDIR

        cc -Wall -pthread ${./coexist.c} -I${chdb}/include -I${neug-c}/include \
          -L${chdb}/lib -L${neug-c}/lib -lchdb -lneug_c -o coexist

        # --- what the libraries export and need
        neug_lib=${neug}/lib/libneug.so
        shim_lib=${neug-c}/lib/libneug_c.so
        chdb_lib=${chdb}/lib/libchdb.so
        for lib in $neug_lib $shim_lib $chdb_lib; do
          name=$(basename $lib)
          nm -D --defined-only $lib | awk '{print $3}' | sed 's/@.*//' | sort -u > defined-$name
          nm -D --undefined-only $lib | awk '{print $2}' | sed 's/@.*//' | sort -u > needed-$name
        done

        # the protobuf and the abseil inside libneug.so are not exported (its version script)
        bundled="$(grep -E '^_ZN(6google8protobuf|4absl)' defined-libneug.so || true)"
        if [ -n "$bundled" ]; then
          echo "libneug.so exports protobuf or abseil: $(echo "$bundled" | head -3)" >&2
          exit 1
        fi
        # the other libraries inside it are, and are only recorded
        echo "libneug.so exports $(wc -l < defined-libneug.so) symbols, of which yaml-cpp/antlr4/brpc/gflags/utf8proc: $(grep -cE 'YAML|antlr4|brpc|bthread|butil|gflags|utf8proc' defined-libneug.so)"
        echo "libchdb.so exports $(wc -l < defined-libchdb.so) symbols"

        # no name is defined by two of the three, and none of what one needs from outside is
        # defined by another
        for pair in "libneug.so libchdb.so" "libneug_c.so libchdb.so" "libneug.so libneug_c.so"; do
          set -- $pair
          both="$(comm -12 defined-$1 defined-$2 | grep -v '^NEUG_C_1$' || true)"
          if [ -n "$both" ]; then
            echo "$1 and $2 both define: $(echo "$both" | head -3)" >&2
            exit 1
          fi
        done
        stolen="$(comm -12 needed-libchdb.so defined-libneug.so; comm -12 needed-libchdb.so defined-libneug_c.so)"
        if [ -n "$stolen" ]; then
          echo "libchdb.so needs what NeuG defines: $(echo "$stolen" | head -3)" >&2
          exit 1
        fi
        stolen="$(comm -12 needed-libneug.so defined-libchdb.so; comm -12 needed-libneug_c.so defined-libchdb.so)"
        if [ -n "$stolen" ]; then
          echo "NeuG needs what libchdb.so defines: $(echo "$stolen" | head -3)" >&2
          exit 1
        fi
        echo "no name is defined twice, and neither engine needs what the other defines"

        # --- the bindings the dynamic linker made while the engines ran
        # every symbol of the API of an engine is bound to the library of that engine, and no
        # library of one engine is bound to the other
        mistakes() {
          log=$1
          { grep -E 'binding file .* to .*: .* symbol .chdb_' $log | grep -vE ' to [^ ]*/libchdb\.so ' || true
            grep -E 'binding file .* to .*: .* symbol .neug_' $log | grep -vE ' to [^ ]*/libneug_c\.so ' || true
            grep -E 'binding file [^ ]*/libchdb\.so .* to [^ ]*/libneug(_c)?\.so ' $log || true
            grep -E 'binding file [^ ]*/libneug(_c)?\.so .* to [^ ]*/libchdb\.so ' $log || true
          } | head -5
        }

        for order in chdb-first neug-first; do
          rm -f coexist.parquet
          LD_DEBUG=bindings LD_DEBUG_OUTPUT=bindings-$order ./coexist $order ${extensions} | tee out-$order
          grep -q 'coexist OK' out-$order
          cat bindings-$order.* > bindings-$order.log
          bad="$(mistakes bindings-$order.log)"
          if [ -n "$bad" ]; then
            echo "bindings across the engines, starting with $order:" >&2
            echo "$bad" >&2
            exit 1
          fi
          # not vacuous: the calls were bound, and where they should be
          grep -q "to [^ ]*/libchdb.so .*symbol .chdb_connect" bindings-$order.log
          grep -q "to [^ ]*/libneug_c.so .*symbol .neug_db_open" bindings-$order.log
          echo "$order: $(wc -l < bindings-$order.log) bindings, none across the engines"
        done

        # the control: a library that defines a name of chDB, preloaded. The program then calls
        # that, and the check of the bindings must say so.
        echo 'const char* chdb_version(void) { return "clash"; }' > clash.c
        cc -shared -fPIC clash.c -o libclash.so
        rm -f coexist.parquet
        LD_PRELOAD=$PWD/libclash.so LD_DEBUG=bindings LD_DEBUG_OUTPUT=bindings-clash ./coexist chdb-first > out-clash
        cat bindings-clash.* > bindings-clash.log
        grep -q 'chDB clash' out-clash
        if [ -z "$(mistakes bindings-clash.log)" ]; then
          echo "the check of the bindings did not see an interposed name of chDB" >&2
          exit 1
        fi
        echo "control: an interposed chdb_version is seen"

        touch $out
      '';

  # A Rust program, with the engine in its own process through the crates: the graph, every
  # kind of cell, transactions, the six extensions and the paths that fail. The same binary with
  # its path to the library taken out must not start.
  rust-consumer =
    let
      program = rust.program { };
    in
    pkgs.runCommand "neug-rust-consumer-check" { nativeBuildInputs = [ pkgs.patchelf ]; } ''
      export HOME=$TMPDIR NEUG_DB_TMP_DIR=$TMPDIR GLOG_minloglevel=2
      cd $TMPDIR

      ${program}/bin/neug-rust-consumer ${extensions}

      cp ${program}/bin/neug-rust-consumer stripped
      chmod u+w stripped
      patchelf --remove-rpath stripped
      if ./stripped >/dev/null 2>&1; then
        echo "the program ran without a path to libneug_c.so" >&2
        exit 1
      fi

      touch $out
    '';

  # A C program that includes only neug_c.h (none of the C++ headers of NeuG) uses the whole
  # interface: a graph and a two-hop question, every type, a NULL, parameters, a transaction
  # that is rolled back, the six extensions, and the paths that fail.
  c-smoke =
    pkgs.runCommandCC "neug-c-smoke-check"
      {
        nativeBuildInputs = [
          pkgs.patchelf
          pkgs.binutils
        ];
      }
      ''
        export HOME=$TMPDIR NEUG_DB_TMP_DIR=$TMPDIR GLOG_minloglevel=2
        cd $TMPDIR

        cc -Wall -Wextra -Werror ${shim}/smoke.c -I${neug-c}/include -L${neug-c}/lib -lneug_c -o smoke
        ./smoke ${extensions}

        # the library exports its interface and nothing else, and needs no protobuf or abseil
        lib=${neug-c}/lib/libneug_c.so
        nm -D --defined-only $lib | awk '{print $3}' | sed 's/@.*//' | sort -u > defined
        stray="$(grep -vE '^(neug_|NEUG_C_)' defined || true)"
        if [ -n "$stray" ]; then
          echo "exported, and not of the interface: $stray" >&2
          exit 1
        fi
        foreign="$(nm -D --undefined-only -C $lib | grep -E 'protobuf|absl|glog|google::' || true)"
        if [ -n "$foreign" ]; then
          echo "needs from outside: $foreign" >&2
          exit 1
        fi
        echo "exports $(grep -c '^neug_' defined) functions and nothing else"

        # without its path to the library the program does not start
        cp smoke stripped
        patchelf --remove-rpath stripped
        if ./stripped >/dev/null 2>&1; then
          echo "the program ran without a path to libneug_c.so" >&2
          exit 1
        fi

        # a program built with a header of another version of the interface says so
        # (the program is copied next to the header: an include with quotes looks there first)
        mkdir other
        sed 's/#define NEUG_C_ABI_VERSION 1/#define NEUG_C_ABI_VERSION 2/' ${neug-c}/include/neug_c.h > other/neug_c.h
        grep -q 'NEUG_C_ABI_VERSION 2' other/neug_c.h
        cp ${shim}/smoke.c other/smoke.c
        cc -L${neug-c}/lib other/smoke.c -lneug_c -o other-abi
        if ./other-abi >/dev/null 2>&1; then
          echo "a program of another version of the interface ran" >&2
          exit 1
        fi

        touch $out
      '';
}
// rust.checks
