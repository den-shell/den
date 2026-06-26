#!/bin/bash
# Run benchmarks for the Den shell project
#
# Usage:
#   ./scripts/bench.sh              # Run all benchmarks
#   ./scripts/bench.sh startup      # Run startup benchmark only
#   ./scripts/bench.sh comparison   # Compare with other shells

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Ensure we have a release build
echo "Building release version..."
zig build -Doptimize=ReleaseFast 2>/dev/null

DEN="./zig-out/bin/den"

if [ ! -x "$DEN" ]; then
    echo "Error: den binary not found at $DEN"
    exit 1
fi

echo ""
echo "=== Den Shell Benchmarks ==="
echo ""

# Helper function to run a benchmark
run_bench() {
    local name="$1"
    local iterations="${2:-100}"
    local cmd="$3"

    echo "Benchmark: $name ($iterations iterations)"

    local start=$(date +%s.%N)

    for ((i=0; i<iterations; i++)); do
        eval "$cmd" > /dev/null 2>&1
    done

    local end=$(date +%s.%N)
    local total=$(echo "$end - $start" | bc)
    local avg=$(echo "scale=3; $total / $iterations * 1000" | bc)

    echo "  Total: ${total}s"
    echo "  Average: ${avg}ms per iteration"
    echo ""
}

# Benchmark: Startup time
benchmark_startup() {
    echo "--- Startup Time ---"

    # Measure startup time (exit immediately)
    run_bench "Startup (exit 0)" 100 "echo 'exit 0' | $DEN"

    # Measure startup with simple command
    run_bench "Simple echo" 100 "echo 'echo hello' | $DEN"
}

# Benchmark: Command execution
benchmark_execution() {
    echo "--- Command Execution ---"

    # Simple builtin
    run_bench "Builtin (cd)" 100 "echo 'cd .' | $DEN"

    # Variable assignment
    run_bench "Variable assignment" 100 "echo 'FOO=bar' | $DEN"

    # Variable expansion
    run_bench "Variable expansion" 100 "echo 'FOO=bar; echo \$FOO' | $DEN"
}

# Benchmark: Pipelines
benchmark_pipelines() {
    echo "--- Pipelines ---"

    # Simple pipeline
    run_bench "2-stage pipeline" 50 "echo 'echo hello | cat' | $DEN"

    # Longer pipeline
    run_bench "4-stage pipeline" 50 "echo 'echo hello | cat | cat | cat' | $DEN"
}

# Benchmark: Scripting
benchmark_scripting() {
    echo "--- Scripting ---"

    # For loop
    run_bench "For loop (10 iterations)" 50 "echo 'for i in 1 2 3 4 5 6 7 8 9 10; do true; done' | $DEN"

    # Conditionals
    run_bench "If statement" 100 "echo 'if true; then echo yes; fi' | $DEN"

    # Function definition and call
    run_bench "Function call" 50 "echo 'f() { echo hi; }; f' | $DEN"
}

# Benchmark: Comparison with other shells.
# Every number printed here is measured on THIS machine — nothing is hardcoded.
benchmark_comparison() {
    echo "--- Shell Comparison (measured on $(uname -srm)) ---"
    echo ""

    # Build the list of shells actually present.
    local shells=("$DEN")
    for s in bash zsh fish; do command -v "$s" >/dev/null 2>&1 && shells+=("$(command -v "$s")"); done

    # Portable helpers.
    fsize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }
    deps_count() {
        if command -v otool >/dev/null 2>&1; then otool -L "$1" 2>/dev/null | tail -n +2 | grep -c .
        elif command -v ldd >/dev/null 2>&1; then ldd "$1" 2>/dev/null | grep -c '=>'
        else echo "?"; fi
    }
    # Idle RSS (clean config) of a shell kept alive via a held-open FIFO.
    idle_rss_mb() {
        local sh="$1" fifo; fifo="$(mktemp -u)"; mkfifo "$fifo"
        exec 9<>"$fifo"
        case "$(basename "$sh")" in
            den)  "$sh" --norc <"$fifo" >/dev/null 2>&1 & ;;
            bash) "$sh" --norc --noprofile -i <"$fifo" >/dev/null 2>&1 & ;;
            zsh)  "$sh" -f -i <"$fifo" >/dev/null 2>&1 & ;;
            *)    "$sh" <"$fifo" >/dev/null 2>&1 & ;;
        esac
        local pid=$! kb=""; sleep 1
        kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        echo "exit" >&9; kill "$pid" 2>/dev/null; exec 9>&-; rm -f "$fifo"
        [ -n "$kb" ] && awk "BEGIN{printf \"%.1f\", $kb/1024}" || echo "n/a"
    }
    # Mean startup ms for `<shell> -c true` (hyperfine if available, else a loop).
    startup_ms() {
        local sh="$1"
        if command -v hyperfine >/dev/null 2>&1; then
            hyperfine -N --warmup 20 -r 200 --time-unit millisecond "$sh -c true" 2>/dev/null \
                | awk '/Time \(mean/ {print $5; exit}'
        else
            local n=200 start end
            start=$(date +%s.%N); for ((i=0;i<n;i++)); do "$sh" -c true >/dev/null 2>&1; done; end=$(date +%s.%N)
            awk "BEGIN{printf \"%.2f\", ($end-$start)/$n*1000}"
        fi
    }

    printf "  %-8s %-12s %-12s %-12s %-6s\n" "shell" "startup(ms)" "idle(MB)" "size(MB)" "deps"
    printf "  %-8s %-12s %-12s %-12s %-6s\n" "-----" "-----------" "--------" "--------" "----"
    for sh in "${shells[@]}"; do
        local name; name=$(basename "$sh")
        local su; su=$(startup_ms "$sh")
        local mem; mem=$(idle_rss_mb "$sh")
        local sz; sz=$(awk "BEGIN{printf \"%.2f\", $(fsize "$sh")/1000000}")
        local dep; dep=$(deps_count "$sh")
        printf "  %-8s %-12s %-12s %-12s %-6s\n" "$name" "$su" "$mem" "$sz" "$dep"
    done
    echo ""
    echo "  Note: numbers are machine/OS/version specific; startup is the bare"
    echo "  interpreter cost (no rc files). See docs/BENCHMARKS.md for methodology."
    echo ""
}

# Parse arguments
case "${1:-all}" in
    startup)
        benchmark_startup
        ;;
    execution)
        benchmark_execution
        ;;
    pipelines)
        benchmark_pipelines
        ;;
    scripting)
        benchmark_scripting
        ;;
    comparison)
        benchmark_comparison
        ;;
    all)
        benchmark_startup
        benchmark_execution
        benchmark_pipelines
        benchmark_scripting
        ;;
    *)
        echo "Usage: $0 [startup|execution|pipelines|scripting|comparison|all]"
        exit 1
        ;;
esac

echo "=== Benchmark Complete ==="
