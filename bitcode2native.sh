#!/usr/bin/env bash

# bitcode_to_native
#
# Converts LLVM bitcode static archives (.a) or object files (.o/.bc) to native .o files.
# Archives will be converted back into .a files containing native .o files.
# Bitcode files must be created with clang/LLVM and may optionally contain debug info.
#
# Dependencies:
#   - llvm-ar
#   - opt
#   - llc
#   - file
#   - mktemp
#
# Features:
#   - Supports .a, .o, and .bc input files
#   - Accepts -O[0-3] to control optimization level (default: -O3)
#   - Optionally strips debug info using --strip (via `opt -strip-debug`)
#   - Outputs native .o files or .a archives to a specified directory (default: native/)
#
# Usage:
#   bitcode_to_native libfoo.a
#   bitcode_to_native file1.bc file2.o
#   bitcode_to_native -O2 --strip --output-directory=build libfoo.a extra.bc
#

function bitcode_to_native() {
  local output_dir="native"
  local opt_level="-O3"
  local strip_debug=0
  local inputs=()

  for arg in "$@"; do
    if [[ "$arg" == --output-directory=* ]]; then
      output_dir="${arg#--output-directory=}"
    elif [[ "$arg" == -O[0-9] ]]; then
      opt_level="$arg"
    elif [[ "$arg" == --strip ]]; then
      strip_debug=1
    else
      inputs+=("$arg")
    fi
  done

  echo "▶ Converting bitcode to native objects"
  echo "-> opt=$opt_level debug=$([[ $strip_debug -eq 1 ]] && echo 'stripped' || echo 'preserved')"
  echo "-> Output directory: $output_dir"

  mkdir -p "$output_dir"
  set +m

  for input in "${inputs[@]}"; do
    local base name ext
    base=$(basename "$input")
    name="${base%.*}"
    ext="${base##*.}"

    case "$ext" in
      a)
        llvm_bitcode_process_archive "$input" "$output_dir" "$opt_level" "$strip_debug"
        ;;
      o|bc)
        llvm_bitcode_process_single_file "$input" "$output_dir" "$opt_level" "$strip_debug"
        ;;
      *)
        echo "⚠️  Skipping unsupported file: $input"
        ;;
    esac
  done

  set -m
}

function llvm_bitcode_process_archive() {
  local archive="$1"
  local outdir="$2"
  local opt="$3"
  local strip="$4"
  local base tmpdir
  base=$(basename "$archive")
  tmpdir=$(mktemp -d)

  echo "▶ Processing archive: $archive"
  echo "   → Extracting to temporary directory: $tmpdir"

  if ! ( cd "$(dirname "$archive")" && llvm-ar x "$base" --output="$tmpdir" ); then
    echo "❌ Failed to extract archive: $archive"
    echo "   → Temp dir preserved: $tmpdir"
    return
  fi

  local failed=0
  local jobs=()

  for f in "$tmpdir"/*.o; do
    llvm_bitcode_process_object_file "$f" "$f" "$opt" "$strip" &
    jobs+=($!)
  done

  for j in "${jobs[@]}"; do wait "$j" || failed=1; done

  if [[ $failed -ne 0 ]]; then
    echo "❌ Failure during archive processing: $archive"
    echo "   → Temp dir preserved: $tmpdir"
    return
  fi

  echo "✅ Creating native archive: $outdir/$base"
  llvm-ar rcs "$outdir/$base" "$tmpdir"/*.o
  rm -rf "$tmpdir"
}

function llvm_bitcode_process_single_file() {
  local file="$1"
  local outdir="$2"
  local opt="$3"
  local strip="$4"
  local base name
  base=$(basename "$file")
  name="${base%.*}"

  echo "▶ Processing file: $file"
  llvm_bitcode_process_object_file "$file" "$outdir/$name.o" "$opt" "$strip"
}

function llvm_bitcode_process_object_file() {
  local input="$1"
  local output="$2"
  local opt="$3"
  local strip="$4"
  local base
  base=$(basename "$input")

  if file "$input" | grep -qE "LLVM (IR )?bitcode"; then
    echo "   → [$base] LLVM bitcode – lowering"

    if [[ "$strip" -eq 1 ]]; then
      if ! opt "$opt" -strip-debug "$input" -o "${output}.opt.bc"; then return 1; fi
    else
      if ! opt "$opt" "$input" -o "${output}.opt.bc"; then return 1; fi
    fi

    if ! llc -filetype=obj "${output}.opt.bc" -o "$output"; then return 1; fi
    rm "${output}.opt.bc"
  else
    echo "   → [$base] Native object – using as-is"
    [[ "$input" != "$output" ]] && cp "$input" "$output"
  fi
}
