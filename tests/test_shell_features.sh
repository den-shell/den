#!/bin/bash
# Den Shell Integration Tests
# Tests den shell features using `den -c` against expected outputs.
#
# Usage:
#   ./tests/test_shell_features.sh              # Run all tests
#   DEN=/path/to/den ./tests/test_shell_features.sh  # Custom binary path

DEN="${DEN:-./zig-out/bin/den}"

# Verify den binary exists
if [ ! -x "$DEN" ]; then
    echo "Error: den binary not found at '$DEN'"
    echo "Build first: zig build -Doptimize=ReleaseSafe"
    exit 1
fi

PASS=0
FAIL=0
SKIP=0
FAILURES=""

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        FAILURES="${FAILURES}FAIL: ${desc}\n  expected: '${expected}'\n  actual:   '${actual}'\n"
    fi
}

skip() {
    local desc="$1" reason="$2"
    SKIP=$((SKIP+1))
}

# ===========================================================================
# 1. Core features (echo, variables, substitution, arithmetic)
# ===========================================================================
check "echo" "hello" "$(timeout 3 $DEN -c 'echo hello')"
check "variable" "world" "$(timeout 3 $DEN -c 'x=world; echo $x')"
check "cmd subst" "inner" "$(timeout 3 $DEN -c 'echo $(echo inner)')"
check "assign subst" "val" "$(timeout 3 $DEN -c 'x=$(echo val); echo $x')"
check "arithmetic add" "8" "$(timeout 3 $DEN -c 'echo $((3+5))')"
check "arithmetic mult" "12" "$(timeout 3 $DEN -c 'echo $((3*4))')"
check "arithmetic mod" "1" "$(timeout 3 $DEN -c 'echo $((7%3))')"
check "arithmetic parens" "14" "$(timeout 3 $DEN -c 'echo $(( (2 + 5) * 2 ))')"
check "arithmetic vars" "15" "$(timeout 3 $DEN -c 'x=10; y=5; echo $((x+y))')"
check "arithmetic negate" "-5" "$(timeout 3 $DEN -c 'echo $(( -5 ))')"
check "arithmetic shift" "8" "$(timeout 3 $DEN -c 'echo $(( 1 << 3 ))')"
check "arithmetic ternary" "1" "$(timeout 3 $DEN -c 'echo $(( 5 > 3 ? 1 : 0 ))')"
check "exit code" "1" "$(timeout 3 $DEN -c 'false; echo $?')"
check "env var" "bar" "$(FOO=bar timeout 3 $DEN -c 'echo $FOO')"
check "quoted assign" "hello world" "$(timeout 3 $DEN -c 'x="hello world"; echo $x')"
check "backtick" "backtick" "$(timeout 3 $DEN -c 'echo `echo backtick`')"
check "nested subst" "INNER" "$(timeout 3 $DEN -c 'echo $(echo $(echo INNER))')"

# ===========================================================================
# 2. Pipes and redirects
# ===========================================================================
check "pipe" "3" "$(timeout 3 $DEN -c 'echo -e "a\nb\nc" | wc -l | tr -d " "')"
check "redirect output" "redir_ok" "$(timeout 3 $DEN -c 'echo redir_ok > /tmp/den_redir.txt; cat /tmp/den_redir.txt'; rm -f /tmp/den_redir.txt)"
check "redirect append" "line2" "$(timeout 3 $DEN -c 'echo line1 > /tmp/den_app.txt; echo line2 >> /tmp/den_app.txt; tail -1 /tmp/den_app.txt'; rm -f /tmp/den_app.txt)"
check "redirect input" "hello" "$(echo hello > /tmp/den_in.txt; timeout 3 $DEN -c 'cat < /tmp/den_in.txt'; rm -f /tmp/den_in.txt)"
check "stderr redirect" "" "$(timeout 3 $DEN -c 'echo error >&2' 2>/dev/null)"
check "cmd -v redirect" "found" "$(timeout 3 $DEN -c 'if command -v echo > /dev/null 2>&1; then echo found; fi')"
check "pipe in cmd subst" "3" "$(timeout 3 $DEN -c 'echo $(echo "a b c" | wc -w | tr -d " ")')"
check "tr -d space in subst" "abc" "$(timeout 3 $DEN -c 'echo $(echo " abc " | tr -d " ")')"
check "here string" "hello" "$(timeout 3 $DEN -c 'cat <<< hello')"

# ===========================================================================
# 3. Conditional operators
# ===========================================================================
check "conditional &&" "yes" "$(timeout 3 $DEN -c 'true && echo yes')"
check "conditional ||" "fallback" "$(timeout 3 $DEN -c 'false || echo fallback')"
check "chain && ||" "recovered" "$(timeout 3 $DEN -c 'true && false || echo recovered')"
check "true exit" "0" "$(timeout 3 $DEN -c 'true; echo $?')"
check "false exit" "1" "$(timeout 3 $DEN -c 'false; echo $?')"

# ===========================================================================
# 4. Control flow: if/elif/else/fi
# ===========================================================================
check "if/else" "else_branch" "$(timeout 3 $DEN -c 'if false; then echo then_branch; else echo else_branch; fi')"
check "elif" "two" "$(timeout 5 $DEN -c 'x=2; if [ "$x" = "1" ]; then echo one; elif [ "$x" = "2" ]; then echo two; fi')"
check "nested if" "RIGHT" "$(timeout 3 $DEN -c 'if true; then if false; then echo WRONG; else echo RIGHT; fi; fi')"
check "complex elif" "medium" "$(timeout 5 $DEN -c 'x=5; if [ $x -gt 10 ]; then echo big; elif [ $x -gt 3 ]; then echo medium; else echo small; fi')"

# ===========================================================================
# 5. Loops: for, while, until
# ===========================================================================
check "for loop" "1 2 3" "$(timeout 3 $DEN -c 'for i in 1 2 3; do echo $i; done' | tr '\n' ' ' | sed 's/ $//')"
check "while loop" "3" "$(timeout 3 $DEN -c 'i=0; while [ $i -lt 3 ]; do i=$((i+1)); done; echo $i')"
check "for break" "1 2" "$(timeout 3 $DEN -c 'for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then break; fi; echo $i; done' | tr '\n' ' ' | sed 's/ $//')"
check "for continue" "1 2 4 5" "$(timeout 3 $DEN -c 'for i in 1 2 3 4 5; do if [ $i -eq 3 ]; then continue; fi; echo $i; done' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 6. Case statements
# ===========================================================================
check "case match" "matched_b" "$(timeout 3 $DEN -c 'case b in a) echo matched_a;; b) echo matched_b;; esac')"
check "case wildcard" "other" "$(timeout 3 $DEN -c 'x=hello; case $x in foo) echo foo;; *) echo other;; esac')"

# ===========================================================================
# 7. Test builtins: [ ], [[ ]], test
# ===========================================================================
check "test -f" "exists" "$(timeout 3 $DEN -c 'test -f /etc/hosts && echo exists')"
check "test -z" "empty" "$(timeout 3 $DEN -c 'x=""; if [ -z "$x" ]; then echo empty; fi')"
check "test -n" "notempty" "$(timeout 3 $DEN -c 'x=hi; if [ -n "$x" ]; then echo notempty; fi')"
check "string eq" "equal" "$(timeout 3 $DEN -c 'if [ "abc" = "abc" ]; then echo equal; fi')"
check "numeric gt" "yes" "$(timeout 3 $DEN -c 'if [ 5 -gt 3 ]; then echo yes; fi')"
check "[[ glob ]]" "yes" "$(timeout 3 $DEN -c '[[ "abc" == a* ]] && echo yes')"
check "[[ regex ]]" "yes" "$(timeout 3 $DEN -c '[[ "hello123" =~ [0-9]+ ]] && echo yes')"
check "[[ != ]]" "yes" "$(timeout 3 $DEN -c '[[ "abc" != x* ]] && echo yes')"
check "[[ anchored ]]" "yes" "$(timeout 3 $DEN -c '[[ "abc" =~ ^[a-z]+$ ]] && echo yes')"

# ===========================================================================
# 8. Functions
# ===========================================================================
check "func basic" "hello world" "$(timeout 3 $DEN -c 'greet() { echo "$1 $2"; }; greet hello world')"
check "func for" "a b" "$(timeout 5 $DEN -c 'myfn() { for x in a b; do echo $x; done; }; myfn' | tr '\n' ' ' | sed 's/ $//')"
check "func args \$@" "a b c" "$(timeout 5 $DEN -c 'showargs() { for arg in "$@"; do echo $arg; done; }; showargs a b c' | tr '\n' ' ' | sed 's/ $//')"
check "return value" "42" "$(timeout 3 $DEN -c 'retfn() { return 42; }; retfn; echo $?')"
check "func if" "yes" "$(timeout 3 $DEN -c 'checkfn() { if true; then echo yes; else echo no; fi; }; checkfn')"
check "func while local" "3" "$(timeout 5 $DEN -c 'countfn() { local i=0; while [ $i -lt 3 ]; do i=$((i+1)); done; echo $i; }; countfn')"
check "nested func" "inner" "$(timeout 3 $DEN -c 'outer() { inner() { echo inner; }; inner; }; outer')"

# ===========================================================================
# 9. Local variables
# ===========================================================================
check "local update" "1" "$(timeout 3 $DEN -c 'f() { local x=0; x=1; echo $x; }; f')"
check "local scope" "global" "$(timeout 3 $DEN -c 'x=global; f() { local x=local; x=changed; }; f; echo $x')"
check "local arith" "2" "$(timeout 3 $DEN -c 'f() { local i=0; i=1; echo $((i+1)); }; f')"

# ===========================================================================
# 10. Parameter expansion
# ===========================================================================
check "param default" "default" "$(timeout 3 $DEN -c 'echo ${UNSET_VAR:-default}')"
check "param assign" "default" "$(timeout 3 $DEN -c 'echo ${UNSET_VAR:=default}')"
check "param length" "5" "$(timeout 3 $DEN -c 'x=hello; echo ${#x}')"
check "## strip" "file.txt" "$(timeout 3 $DEN -c 'x=/path/to/file.txt; echo ${x##*/}')"
check "% strip" "/path/to" "$(timeout 3 $DEN -c 'x=/path/to/file.txt; echo ${x%/*}')"
check "/ replace" "hello_world" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x/ /_}')"
check "// replace all" "hell- w-rld" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x//o/-}')"
check "substring" "llo" "$(timeout 3 $DEN -c 'x=hello; echo ${x:2}')"
check "substring len" "el" "$(timeout 3 $DEN -c 'x=hello; echo ${x:1:2}')"

# ===========================================================================
# 11. Subshells and misc
# ===========================================================================
check "subshell" "sub" "$(timeout 3 $DEN -c '(echo sub)')"
check "subshell semi" "a b" "$(timeout 3 $DEN -c '(echo a; echo b)' | tr '\n' ' ' | sed 's/ $//')"
check "command -v" "echo" "$(timeout 3 $DEN -c 'command -v echo')"
check "cd+pwd" "/private/tmp" "$(timeout 3 $DEN -c 'cd /tmp; pwd')"
check "tilde expand" "$HOME" "$(timeout 3 $DEN -c 'echo ~')"

# ===========================================================================
# 12. Variable operations
# ===========================================================================
check "export var" "exported" "$(timeout 3 $DEN -c 'export MY_VAR=exported; echo $MY_VAR')"
check "unset var" "" "$(timeout 3 $DEN -c 'x=hello; unset x; echo -n $x')"
check "+= append" "helloworld" "$(timeout 3 $DEN -c 'x=hello; x+=world; echo $x')"

# ===========================================================================
# 13. Quoting and escaping
# ===========================================================================
check "backslash dollar" '$HOME' "$(timeout 3 $DEN -c 'echo \$HOME')"

# ===========================================================================
# 14. Trap and set
# ===========================================================================
check "trap EXIT" "main cleanup" "$(timeout 3 $DEN -c 'trap "echo cleanup" EXIT; echo main' | tr '\n' ' ' | sed 's/ $//')"
check "set -e" "before" "$(timeout 3 $DEN -c 'set -e; echo before; false; echo after')"

# ===========================================================================
# 15. Exit code propagation
# ===========================================================================
$DEN -c 'exit 1' 2>/dev/null; check "exit 1" "1" "$?"
$DEN -c 'exit 42' 2>/dev/null; check "exit 42" "42" "$?"

# ===========================================================================
# 16. Negation
# ===========================================================================
check "negation standalone" "1" "$(timeout 3 $DEN -c '! true; echo $?' 2>/dev/null)"

# ===========================================================================
# 17. Trailing semicolons
# ===========================================================================
check "trailing semicolon" "ok" "$(timeout 3 $DEN -c 'echo ok;')"

# ===========================================================================
# 18. Printf
# ===========================================================================
check "printf fmt" "num: 42" "$(timeout 3 $DEN -c 'printf "num: %d\n" 42')"

# ===========================================================================
# 19. Read builtin
# ===========================================================================
check "read single" "hello world" "$(echo "hello world" | timeout 3 $DEN -c 'read x; echo $x')"
check "read multi" "hello world" "$(echo "hello world" | timeout 3 $DEN -c 'read x y; echo "$x $y"')"

# ===========================================================================
# 19b. mapfile / readarray (bash 4+ semantics)
# ===========================================================================
check "mapfile count" "3" "$(printf 'a\nb\nc\n' | timeout 3 $DEN -c 'mapfile -t arr; echo ${#arr[@]}')"
check "mapfile -t strips newline" "a" "$(printf 'a\nb\n' | timeout 3 $DEN -c 'mapfile -t arr; echo "${arr[0]}"')"
# Default (no -t) KEEPS the trailing delimiter: arr[0] is "a\n", so +"x" spans two lines.
check "mapfile default keeps delim" "a
x" "$(printf 'a\nb\n' | timeout 3 $DEN -c 'mapfile arr; printf "%sx" "${arr[0]}"')"
check "mapfile -n 0 unlimited" "3" "$(printf 'a\nb\nc\n' | timeout 3 $DEN -c 'mapfile -t -n 0 arr; echo ${#arr[@]}')"
check "mapfile -n limit" "2" "$(printf 'a\nb\nc\n' | timeout 3 $DEN -c 'mapfile -t -n 2 arr; echo ${#arr[@]}')"
check "mapfile -s skip" "b" "$(printf 'a\nb\nc\n' | timeout 3 $DEN -c 'mapfile -t -s 1 arr; echo "${arr[0]}"')"
check "mapfile -d custom delim" "x|y|z" "$(printf 'x:y:z:' | timeout 3 $DEN -c 'mapfile -t -d : arr; echo "${arr[0]}|${arr[1]}|${arr[2]}"')"
check "readarray alias" "2" "$(printf 'a\nb\n' | timeout 3 $DEN -c 'readarray -t arr; echo ${#arr[@]}')"

# ===========================================================================
# 20. Multiple pipes
# ===========================================================================
check "multiple pipes" "3" "$(timeout 3 $DEN -c 'echo -e "aa\nbb\ncc" | /usr/bin/wc -l | tr -d " "')"

# ===========================================================================
# 21. Misc: source, let, heredoc, multi-assign
# ===========================================================================
check "let builtin" "10" "$(timeout 3 $DEN -c 'let x=5+5; echo $x')"
check "multi assign" "2" "$(timeout 3 $DEN -c 'a=1; b=2; echo $b')"
check "multi cmd subst" "hello world" "$(timeout 3 $DEN -c 'a=$(echo hello); b=$(echo world); echo "$a $b"')"
check "empty if body" "" "$(timeout 3 $DEN -c 'if false; then echo wrong; fi' 2>/dev/null)"
check "heredoc basic" "hello" "$(timeout 3 $DEN -c 'cat << EOF
hello
EOF')"
check "source" "sourced" "$(echo 'echo sourced' > /tmp/den_source_test.sh; timeout 3 $DEN -c 'source /tmp/den_source_test.sh'; rm -f /tmp/den_source_test.sh)"
check "dot source" "dotted" "$(echo 'echo dotted' > /tmp/den_dot_test.sh; timeout 3 $DEN -c '. /tmp/den_dot_test.sh'; rm -f /tmp/den_dot_test.sh)"

# ===========================================================================
# 22. Real-world patterns (Claude Code, scripts)
# ===========================================================================
check "tool check pattern" "found" "$(timeout 3 $DEN -c 'if command -v echo > /dev/null 2>&1; then echo found; else echo missing; fi')"
check "var as cmd" "hello" "$(timeout 3 $DEN -c 'cmd=echo; $cmd hello')"
check "stderr suppression" "ok" "$(timeout 3 $DEN -c 'ls /nonexistent 2>/dev/null; echo ok')"
check "set +e" "after" "$(timeout 3 $DEN -c 'set -e; set +e; false; echo after')"
check "exported to subprocess" "hello" "$(timeout 3 $DEN -c 'export X=hello; echo $X')"
check "func return check" "success" "$(timeout 3 $DEN -c 'check() { return 0; }; if check; then echo success; fi')"
check "assign from pipe" "hello" "$(timeout 3 $DEN -c 'x=$(echo hello | cat); echo $x')"
check "string concat" "ab" "$(timeout 3 $DEN -c 'a=a; b=b; echo "$a$b"')"
check "env passthrough" "test_val" "$(TEST_ENV=test_val timeout 3 $DEN -c 'echo $TEST_ENV')"
check "three pipes" "1" "$(timeout 3 $DEN -c 'echo "hello" | wc -l | tr -d " "')"

# ===========================================================================
# 23. Arrays
# ===========================================================================
check "array assign" "b" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[1]}')"
check "array all" "a b c" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[@]}')"
check "array length" "3" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${#arr[@]}')"
check "array append" "a b c d" "$(timeout 3 $DEN -c 'arr=(a b c); arr+=(d); echo ${arr[@]}')"

# ===========================================================================
# 24. Case conversion
# ===========================================================================
check "uppercase all" "HELLO" "$(timeout 3 $DEN -c 'x=hello; echo ${x^^}')"
check "lowercase all" "hello" "$(timeout 3 $DEN -c 'x=HELLO; echo ${x,,}')"
check "uppercase first" "Hello" "$(timeout 3 $DEN -c 'x=hello; echo ${x^}')"

# ===========================================================================
# 25. Arithmetic command (( ))
# ===========================================================================
check "(( assignment ))" "10" "$(timeout 3 $DEN -c 'x=5; (( x = x * 2 )); echo $x')"
check "(( condition ))" "0" "$(timeout 3 $DEN -c '(( 5 > 3 )); echo $?')"

# ===========================================================================
# 26. Backslash continuation
# ===========================================================================
check "backslash cont" "hello world" "$(timeout 3 $DEN -c $'echo hello \\\nworld')"

# ===========================================================================
# 27. Test builtin negation
# ===========================================================================
check "[ ! -f ] neg" "yes" "$(timeout 3 $DEN -c '[ ! -f /nonexistent ] && echo yes || echo no')"
check "[ ! -d ] neg" "no" "$(timeout 3 $DEN -c '[ ! -d /tmp ] && echo yes || echo no')"
check "[ ! = ] neg" "yes" "$(timeout 3 $DEN -c '[ ! "a" = "b" ] && echo yes || echo no')"

# ===========================================================================
# 28. Arithmetic post-increment/decrement
# ===========================================================================
check "(( x++ ))" "6" "$(timeout 3 $DEN -c 'x=5; (( x++ )); echo $x')"
check "(( x-- ))" "4" "$(timeout 3 $DEN -c 'x=5; (( x-- )); echo $x')"
check "(( ++x ))" "6" "$(timeout 3 $DEN -c 'x=5; (( ++x )); echo $x')"
check "(( --x ))" "4" "$(timeout 3 $DEN -c 'x=5; (( --x )); echo $x')"

# ===========================================================================
# 29. Readonly error code
# ===========================================================================
check "readonly err" "1" "$(timeout 3 $DEN -c 'readonly x=5; x=10; echo $?' 2>/dev/null)"

# ===========================================================================
# 30. Getopts
# ===========================================================================
check "getopts basic" "0" "$(timeout 3 $DEN -c 'getopts "ab:" opt -a; echo $?' 2>/dev/null)"

# ===========================================================================
# 31. Compound command groups
# ===========================================================================
check "{ compound }" "hello" "$(timeout 3 $DEN -c '{ echo hello; }')"
check "{ multi cmds }" "a
b" "$(timeout 3 $DEN -c '{ echo a; echo b; }')"

# ===========================================================================
# 32. Special variables
# ===========================================================================
R=$(timeout 3 $DEN -c 'echo $RANDOM' 2>/dev/null)
if [ -n "$R" ]; then check "RANDOM" "nonempty" "nonempty"; else check "RANDOM" "nonempty" ""; fi
check "LINENO" "1" "$(timeout 3 $DEN -c 'echo $LINENO' 2>/dev/null)"

# ===========================================================================
# 33. Test -s operator
# ===========================================================================
check "[ -s file ]" "yes" "$(timeout 3 $DEN -c '[ -s /etc/hosts ] && echo yes || echo no')"
check "[ -s empty ]" "no" "$(timeout 3 $DEN -c '[ -s /dev/null ] && echo yes || echo no')"

# ===========================================================================
# 34. Pipe to control flow (while read)
# ===========================================================================
check "pipe | while read" "a
b
c" "$(timeout 5 $DEN -c 'printf "a\nb\nc\n" | while read line; do echo $line; done')"
check "read EOF exit" "1" "$(printf "" | timeout 3 $DEN -c 'read x; echo $?')"

# ===========================================================================
# 35. Printf repeat pattern
# ===========================================================================
check "printf repeat" "a
b
c" "$(timeout 3 $DEN -c 'printf "%s\n" a b c')"
check "printf repeat int" "1 2 3" "$(timeout 3 $DEN -c 'printf "%d " 1 2 3' | sed 's/ $//')"

# ===========================================================================
# 36. Shift in functions
# ===========================================================================
check "shift in func" "x y" "$(timeout 3 $DEN -c 'f() { echo $1; shift; echo $1; }; f x y' | tr '\n' ' ' | sed 's/ $//')"
check "shift 2 in func" "c" "$(timeout 3 $DEN -c 'f() { shift 2; echo $1; }; f a b c')"

# ===========================================================================
# 37. Negative substring extraction
# ===========================================================================
check "substr negative" "lo" "$(timeout 3 $DEN -c 'x=hello; echo ${x:(-2)}')"
check "substr neg:len" "l" "$(timeout 3 $DEN -c 'x=hello; echo ${x:(-2):1}')"

# ===========================================================================
# 38. Array element assignment
# ===========================================================================
check "arr elem assign" "world" "$(timeout 3 $DEN -c 'arr=(a b c); arr[1]=world; echo ${arr[1]}')"
check "arr elem extend" "d" "$(timeout 3 $DEN -c 'arr=(a b c); arr[3]=d; echo ${arr[3]}')"

# ===========================================================================
# 39. Test string comparison
# ===========================================================================
check "test str <" "yes" "$(timeout 3 $DEN -c '[ "abc" \< "def" ] && echo yes || echo no')"
check "test str >" "yes" "$(timeout 3 $DEN -c '[ "def" \> "abc" ] && echo yes || echo no')"

# ===========================================================================
# 40. set -- positional parameters
# ===========================================================================
check "set --" "b" "$(timeout 3 $DEN -c 'set -- a b c; echo $2')"
check "set -- count" "3" "$(timeout 3 $DEN -c 'set -- x y z; echo $#')"

# ===========================================================================
# 41. set -u (nounset)
# ===========================================================================
check "set -u unbound" "den: UNDEFINED_VAR_12345: unbound variable" "$(timeout 3 $DEN -c 'set -u; echo $UNDEFINED_VAR_12345' 2>&1)"

# ===========================================================================
# 42. trap ERR
# ===========================================================================
check "trap ERR" "TRAPPED
after" "$(timeout 3 $DEN -c 'trap "echo TRAPPED" ERR; false; echo after' 2>&1)"

# ===========================================================================
# 43. declare -a inline array
# ===========================================================================
check "declare -a" "y" "$(timeout 3 $DEN -c 'declare -a arr=(x y z); echo ${arr[1]}')"
check "declare -a all" "hello world" "$(timeout 3 $DEN -c 'declare -a arr=(hello world); echo ${arr[@]}')"

# ===========================================================================
# 44. declare -i integer attribute
# ===========================================================================
check "declare -i +=" "8" "$(timeout 3 $DEN -c 'declare -i x=5; x+=3; echo $x')"
check "declare -i expr" "10" "$(timeout 3 $DEN -c 'declare -i x=5+5; echo $x')"

# ===========================================================================
# 45. declare -A associative arrays
# ===========================================================================
check "declare -A inline" "val1" "$(timeout 3 $DEN -c 'declare -A m=([key1]=val1 [key2]=val2); echo ${m[key1]}')"
check "declare -A subscript" "bar" "$(timeout 3 $DEN -c 'declare -A m; m[foo]=bar; echo ${m[foo]}')"

# ===========================================================================
# 46. printf -v
# ===========================================================================
check "printf -v" "num: 42" "$(timeout 3 $DEN -c 'printf -v result "num: %d" 42; echo $result')"

# ===========================================================================
# 47. Array slicing
# ===========================================================================
check "arr slice" "b c" "$(timeout 3 $DEN -c 'arr=(a b c d); echo ${arr[@]:1:2}')"

# ===========================================================================
# 48. Command substitution in for loop
# ===========================================================================
check "for cmd subst" "a b c" "$(timeout 3 $DEN -c 'for i in $(echo a b c); do echo $i; done' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 49. IFS in read
# ===========================================================================
check "IFS read" "a b c" "$(echo "a:b:c" | timeout 3 $DEN -c 'IFS=:; read x y z; echo "$x $y $z"')"
check "read -r" "hello" "$(echo "hello" | timeout 3 $DEN -c 'read -r x; echo $x')"

# ===========================================================================
# 50. Heredoc tab strip
# ===========================================================================
check "heredoc <<-" "hello" "$(timeout 3 $DEN -c $'cat <<-EOF\n\thello\nEOF')"

# ===========================================================================
# 51. PIPESTATUS
# ===========================================================================
check "PIPESTATUS" "0 1 0" "$(timeout 3 $DEN -c 'true | false | true; echo ${PIPESTATUS[@]}')"
check "PIPESTATUS idx" "1" "$(timeout 3 $DEN -c 'true | false | true; echo ${PIPESTATUS[1]}')"

# ===========================================================================
# 52. Herestring with read
# ===========================================================================
check "read herestring" "hello" "$(timeout 3 $DEN -c 'read x <<< "hello"; echo $x')"
check "read -a herestring" "y" "$(timeout 3 $DEN -c 'read -a arr <<< "x y z"; echo ${arr[1]}')"

# ===========================================================================
# 53. Array indices
# ===========================================================================
check "arr indices" "0 1 2" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${!arr[@]}')"

# ===========================================================================
# 54. Arithmetic comma operator
# ===========================================================================
check "arith comma" "7" "$(timeout 3 $DEN -c 'echo $(( 1+2, 3+4 ))')"

# ===========================================================================
# 55. Multi-line -c (control flow)
# ===========================================================================
check "multiline if" "yes" "$(timeout 3 $DEN -c $'if true\nthen\necho yes\nfi')"
check "multiline for" "a b c" "$(timeout 3 $DEN -c $'for i in a b c\ndo\necho $i\ndone' | tr '\n' ' ' | sed 's/ $//')"
check "multiline while" "3" "$(timeout 3 $DEN -c $'i=0\nwhile [ $i -lt 3 ]\ndo\ni=$((i+1))\ndone\necho $i')"

# ===========================================================================
# 56. FUNCNAME variable
# ===========================================================================
check "FUNCNAME" "myfunc" "$(timeout 3 $DEN -c 'myfunc() { echo $FUNCNAME; }; myfunc')"

# ===========================================================================
# 57. Arithmetic compound assignment operators
# ===========================================================================
check "(( x += ))" "15" "$(timeout 3 $DEN -c 'x=10; (( x += 5 )); echo $x')"
check "(( x -= ))" "7" "$(timeout 3 $DEN -c 'x=10; (( x -= 3 )); echo $x')"
check "(( x *= ))" "20" "$(timeout 3 $DEN -c 'x=10; (( x *= 2 )); echo $x')"
check "(( x /= ))" "3" "$(timeout 3 $DEN -c 'x=10; (( x /= 3 )); echo $x')"

# ===========================================================================
# 58. Local array in function
# ===========================================================================
check "local arr in func" "1 2 3" "$(timeout 3 $DEN -c 'f() { local arr=(1 2 3); echo ${arr[@]}; }; f')"
check "func body with \${}" "a b c" "$(timeout 3 $DEN -c 'f() { x=(a b c); echo ${x[@]}; }; f')"

# ===========================================================================
# 59. Multiline function definition via -c
# ===========================================================================
check "multiline func" "hi world" "$(timeout 3 $DEN -c $'greet() {\necho "hi $1"\n}\ngreet world')"

# ===========================================================================
# 60. Assoc array keys
# ===========================================================================
# Assoc array key count (order may vary, just check count)
ASSOC_KEYS=$(timeout 3 $DEN -c 'declare -A m=([a]=1 [b]=2); echo ${!m[@]}' | wc -w | tr -d " ")
check "assoc keys count" "2" "$ASSOC_KEYS"

# ===========================================================================
# 61. Arithmetic with parameter expansion
# ===========================================================================
check "arith \${#x}" "4" "$(timeout 3 $DEN -c 'x=abc; echo $(( ${#x} + 1 ))')"
check "arith \${x}" "15" "$(timeout 3 $DEN -c 'x=10; echo $(( ${x} + 5 ))')"

# ===========================================================================
# 62. Case with pipe pattern
# ===========================================================================
check "case pipe pattern" "matched" "$(timeout 3 $DEN -c 'x=b; case $x in a|b|c) echo matched;; esac')"

# ===========================================================================
# 63. Indirect variable expansion
# ===========================================================================
check "indirect var" "hello" "$(timeout 3 $DEN -c 'x=hello; ref=x; echo ${!ref}')"

# ===========================================================================
# 64. Nested func calls
# ===========================================================================
check "nested func call" "a
b" "$(timeout 3 $DEN -c 'a() { echo a; }; b() { a; echo b; }; b')"

# ===========================================================================
# 65. Subshell variable isolation
# ===========================================================================
check "subshell var" "inner outer" "$(timeout 3 $DEN -c 'x=outer; (x=inner; echo $x); echo $x' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 66. Heredoc with quoted delimiter (no expansion)
# ===========================================================================
check "heredoc quoted" 'hello $x' "$(timeout 3 $DEN -c 'x=world; cat << "EOF"
hello $x
EOF')"

# ===========================================================================
# 67. Parameter error ${:?}
# ===========================================================================
check "param error" "den: x: not set" "$(timeout 3 $DEN -c 'echo ${x:?not set}' 2>&1 | head -1)"

# ===========================================================================
# 68. Until loop
# ===========================================================================
check "until loop" "3" "$(timeout 3 $DEN -c 'i=0; until [ $i -ge 3 ]; do i=$((i+1)); done; echo $i')"

# ===========================================================================
# 69. Multi-line case via -c
# ===========================================================================
check "multiline case" "matched" "$(timeout 3 $DEN -c $'x=hello\ncase $x in\nhello) echo matched;;\n*) echo nope;;\nesac')"

# ===========================================================================
# 70. String repeat with printf
# ===========================================================================
check "printf repeat str" "-----" "$(timeout 3 $DEN -c 'printf "%.0s-" 1 2 3 4 5')"

# ===========================================================================
# 71. Parameter substitution remove
# ===========================================================================
check "param remove" "hello" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x/world}')"

# ===========================================================================
# 72. Conditional arithmetic
# ===========================================================================
check "if (( ))" "big" "$(timeout 3 $DEN -c 'x=5; if (( x > 3 )); then echo big; fi')"
check "while (( ))" "3" "$(timeout 3 $DEN -c 'i=0; while (( i < 3 )); do (( i++ )); done; echo $i')"

# ===========================================================================
# 73. Herestring with variable expansion
# ===========================================================================
check "herestring var" "hello world" "$(timeout 3 $DEN -c 'x=hello; read y <<< "$x world"; echo $y')"

# ===========================================================================
# 74. Export from function
# ===========================================================================
check "export in func" "123" "$(timeout 3 $DEN -c 'f() { export X=123; }; f; echo $X')"

# ===========================================================================
# 75. Read multiple lines from pipe
# ===========================================================================
check "read multi line" "line1 line2" "$(printf "line1\nline2\n" | timeout 3 $DEN -c 'read a; read b; echo "$a $b"')"

# ===========================================================================
# 76. Multiple assignment on one line
# ===========================================================================
check "multi assign" "1 2 3" "$(timeout 3 $DEN -c 'a=1 b=2 c=3; echo "$a $b $c"')"

# ===========================================================================
# 77. declare -l/-u on reassignment
# ===========================================================================
check "declare -l reassign" "hello" "$(timeout 3 $DEN -c 'declare -l x; x=HELLO; echo $x')"
check "declare -u reassign" "HELLO" "$(timeout 3 $DEN -c 'declare -u x; x=hello; echo $x')"

# ===========================================================================
# 78. unset array element
# ===========================================================================
check "unset arr elem" "a c" "$(timeout 3 $DEN -c 'arr=(a b c); unset arr[1]; echo ${arr[@]}')"
check "unset arr elem len" "2" "$(timeout 3 $DEN -c 'arr=(a b c); unset arr[1]; echo ${#arr[@]}')"

# ===========================================================================
# 79. For loop with brace expansion
# ===========================================================================
check "for brace sum" "15" "$(timeout 3 $DEN -c 'sum=0; for i in {1..5}; do sum=$((sum + i)); done; echo $sum')"
check "for brace persist" "END" "$(timeout 3 $DEN -c 'for i in {1..3}; do x=$i; done; echo END')"

# ===========================================================================
# 80. Array access in arithmetic
# ===========================================================================
check "arith arr access" "50" "$(timeout 3 $DEN -c 'arr=(10 20 30); echo $(( arr[1] + arr[2] ))')"
check "arith arr single" "20" "$(timeout 3 $DEN -c 'arr=(10 20 30); echo $(( arr[1] ))')"

# ===========================================================================
# 81. Variable array index
# ===========================================================================
check "var arr index" "20" "$(timeout 3 $DEN -c 'arr=(10 20 30); i=1; echo ${arr[$i]}')"

# ===========================================================================
# 82. declare -p
# ===========================================================================
check "declare -p" 'declare -- x="hello"' "$(timeout 3 $DEN -c 'x=hello; declare -p x')"
check "declare -p int" 'declare -i x="5"' "$(timeout 3 $DEN -c 'declare -i x=5; declare -p x')"

# ===========================================================================
# 83. SECONDS variable
# ===========================================================================
S=$(timeout 3 $DEN -c 'echo $SECONDS' 2>/dev/null)
if [ -n "$S" ]; then check "SECONDS" "nonempty" "nonempty"; else check "SECONDS" "nonempty" ""; fi

# ===========================================================================
# 84. read -n (nchars)
# ===========================================================================
check "read -n" "hel" "$(echo hello | timeout 3 $DEN -c 'read -n 3 x; echo $x')"

# ===========================================================================
# 85. read -d (delimiter)
# ===========================================================================
check "read -d" "hello" "$(echo 'hello|world' | timeout 3 $DEN -c 'read -d "|" x; echo $x')"

# ===========================================================================
# 86. ${var-default} without colon
# ===========================================================================
check "param default nocolon unset" "default" "$(timeout 3 $DEN -c 'echo ${undefined_var_test-default}')"
check "param default nocolon empty" "" "$(timeout 3 $DEN -c 'x=""; echo ${x-default}')"
check "param default nocolon set" "hello" "$(timeout 3 $DEN -c 'x=hello; echo ${x-default}')"

# ===========================================================================
# 87. ${var+word} without colon
# ===========================================================================
check "param plus set" "yes" "$(timeout 3 $DEN -c 'x=hello; echo ${x+yes}')"
check "param plus empty" "yes" "$(timeout 3 $DEN -c 'x=""; echo "${x+yes}"')"
check "param plus unset" "" "$(timeout 3 $DEN -c 'echo ${undefined_var_test2+yes}')"

# ===========================================================================
# 88. For C-style loop
# ===========================================================================
check "c-style for" "0 1 2" "$(timeout 3 $DEN -c 'for ((i=0; i<3; i++)); do echo $i; done' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 89. Arithmetic power operator
# ===========================================================================
check "arith power" "256" "$(timeout 3 $DEN -c 'echo $(( 2 ** 8 ))')"

# ===========================================================================
# 90. printf formatting
# ===========================================================================
check "printf %02d" "05" "$(timeout 3 $DEN -c 'printf "%02d\n" 5')"
check "printf %s" "hello" "$(timeout 3 $DEN -c 'printf "%s\n" hello')"

# ===========================================================================
# 91. test -e operator
# ===========================================================================
check "test -e" "yes" "$(timeout 3 $DEN -c '[ -e /tmp ] && echo yes')"

# ===========================================================================
# 92. Process substitution
# ===========================================================================
check "proc subst" "0" "$(timeout 3 $DEN -c 'diff <(echo a) <(echo a); echo $?')"

# ===========================================================================
# 93. Declare -x export
# ===========================================================================
check "declare -x" "exported" "$(timeout 3 $DEN -c 'declare -x MY_VAR=exported; echo $MY_VAR')"

# ===========================================================================
# 94. ${!prefix*} variable name expansion
# ===========================================================================
PCOUNT=$(timeout 3 $DEN -c 'FOO_A=1; FOO_B=2; echo ${!FOO*}' | wc -w | tr -d " ")
check "prefix match count" "2" "$PCOUNT"

# ===========================================================================
# 95. [[ -v variable ]] test
# ===========================================================================
check "[[ -v ]] set" "set" "$(timeout 3 $DEN -c 'x=hello; [[ -v x ]] && echo set || echo unset')"
check "[[ -v ]] unset" "unset" "$(timeout 3 $DEN -c '[[ -v nonexistent_var ]] && echo set || echo unset')"
check "[[ -v ]] HOME" "set" "$(timeout 3 $DEN -c '[[ -v HOME ]] && echo set || echo unset')"

# ===========================================================================
# 96. getopts
# ===========================================================================
check "getopts basic" "a foo" "$(timeout 3 $DEN -c 'getopts "a:b" opt -a foo; echo "$opt $OPTARG"')"

# ===========================================================================
# 97. Associative array keys
# ===========================================================================
check "assoc keys step" "key1 key2" "$(timeout 3 $DEN -c 'declare -A m; m[key1]=v1; m[key2]=v2; echo "${!m[@]}"')"
check "assoc keys inline" "2" "$(timeout 3 $DEN -c 'declare -A m=([a]=1 [b]=2); echo ${#m[@]}')"

# ===========================================================================
# 98. local -i (integer attribute)
# ===========================================================================
check "local -i" "8" "$(timeout 3 $DEN -c 'f() { local -i x=5+3; echo $x; }; f')"

# ===========================================================================
# 99. read -ra (combined flags)
# ===========================================================================
check "read -ra" "3" "$(echo "a b c" | timeout 3 $DEN -c 'read -ra arr; echo ${#arr[@]}')"

# ===========================================================================
# 100. Arithmetic base conversion
# ===========================================================================
check "arith base16" "255" "$(timeout 3 $DEN -c 'echo $((16#ff))')"
check "arith base2" "10" "$(timeout 3 $DEN -c 'echo $((2#1010))')"
check "arith base8" "63" "$(timeout 3 $DEN -c 'echo $((8#77))')"

# ===========================================================================
# 101. ${var@op} transform operators
# ===========================================================================
check "transform @U" "HELLO WORLD" "$(timeout 3 $DEN -c 'x="Hello World"; echo ${x@U}')"
check "transform @L" "hello world" "$(timeout 3 $DEN -c 'x="Hello World"; echo ${x@L}')"
check "transform @u" "Hello world" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x@u}')"

# ===========================================================================
# 102. Negative array slice
# ===========================================================================
check "arr neg slice" "3 4 5" "$(timeout 3 $DEN -c 'arr=(1 2 3 4 5); echo ${arr[@]: -3}')"
check "arr neg slice 2" "d e" "$(timeout 3 $DEN -c 'arr=(a b c d e); echo ${arr[@]: -2}')"

# ===========================================================================
# 103. Associative array step-by-step assignment
# ===========================================================================
check "assoc step assign" "val1" "$(timeout 3 $DEN -c 'declare -A m; m[key1]=val1; echo ${m[key1]}')"
AKCOUNT=$(timeout 3 $DEN -c 'declare -A m; m[a]=1; m[b]=2; echo ${!m[@]}' | wc -w | tr -d ' ')
check "assoc keys count" "2" "$AKCOUNT"

# ===========================================================================
# 104. Brace expansion with step
# ===========================================================================
check "brace step" "1 3 5 7 9" "$(timeout 3 $DEN -c 'echo {1..10..2}')"
check "brace step 3" "1 4 7 10" "$(timeout 3 $DEN -c 'echo {1..10..3}')"
check "brace step rev" "10 8 6 4 2" "$(timeout 3 $DEN -c 'echo {10..1..2}')"

# ===========================================================================
# 105. ${var/#pat/rep} prefix and ${var/%pat/rep} suffix substitution
# ===========================================================================
check "subst prefix" "HEllo" "$(timeout 3 $DEN -c 'x="hello"; echo "${x/#he/HE}"')"
check "subst suffix" "helLO" "$(timeout 3 $DEN -c 'x="hello"; echo "${x/%lo/LO}"')"
check "subst prefix nomatch" "hello" "$(timeout 3 $DEN -c 'x="hello"; echo "${x/#xx/YY}"')"

# ===========================================================================
# 106. ${var@op} transform operators
# ===========================================================================
check "transform @Q" "'hello'" "$(timeout 3 $DEN -c "x=hello; echo \${x@Q}")"

# ===========================================================================
# 107. Special variables: PPID, BASHPID, EUID, UID
# ===========================================================================
check "PPID is numeric" "yes" "$(timeout 3 $DEN -c '[[ $PPID =~ ^[0-9]+$ ]] && echo yes || echo no')"
check "BASHPID is numeric" "yes" "$(timeout 3 $DEN -c '[[ $BASHPID =~ ^[0-9]+$ ]] && echo yes || echo no')"
check "EUID is numeric" "yes" "$(timeout 3 $DEN -c '[[ $EUID =~ ^[0-9]+$ ]] && echo yes || echo no')"
check "UID is numeric" "yes" "$(timeout 3 $DEN -c '[[ $UID =~ ^[0-9]+$ ]] && echo yes || echo no')"
check "PPID braced" "yes" "$(timeout 3 $DEN -c '[[ ${PPID} =~ ^[0-9]+$ ]] && echo yes || echo no')"

# ===========================================================================
# 108. String comparison in [[ ]]
# ===========================================================================
check "[[ a < b ]]" "yes" "$(timeout 3 $DEN -c '[[ a < b ]] && echo yes || echo no')"
check "[[ z < a ]]" "no" "$(timeout 3 $DEN -c '[[ z < a ]] && echo yes || echo no')"
check "[[ abc < def ]]" "yes" "$(timeout 3 $DEN -c '[[ abc < def ]] && echo yes || echo no')"
check "[[ z > a ]]" "yes" "$(timeout 3 $DEN -c '[[ z > a ]] && echo yes || echo no')"

# ===========================================================================
# 109. source builtin
# ===========================================================================
echo 'x=42' > /tmp/den_source_test.sh
check "source variable" "42" "$(timeout 3 $DEN -c 'source /tmp/den_source_test.sh; echo $x')"
check "dot source" "42" "$(timeout 3 $DEN -c '. /tmp/den_source_test.sh; echo $x')"
echo 'greet() { echo hi; }' > /tmp/den_source_func.sh
check "source function" "hi" "$(timeout 3 $DEN -c 'source /tmp/den_source_func.sh; greet')"
rm -f /tmp/den_source_test.sh /tmp/den_source_func.sh

# ===========================================================================
# 110. Arithmetic assignment
# ===========================================================================
check "arith assign x=5+3" "8" "$(timeout 3 $DEN -c 'echo $((x=5+3))')"
check "arith assign persist" "8 8" "$(timeout 3 $DEN -c 'echo $((x=5+3)); echo $x' | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 111. Arithmetic increment/decrement
# ===========================================================================
check "pre-increment" "6" "$(timeout 3 $DEN -c 'x=5; echo $((++x))')"
check "post-increment" "5" "$(timeout 3 $DEN -c 'x=5; echo $((x++))')"
check "pre-decrement" "4" "$(timeout 3 $DEN -c 'x=5; echo $((--x))')"
check "post-decrement" "5" "$(timeout 3 $DEN -c 'x=5; echo $((x--))')"

# ===========================================================================
# 112. Compound assignment operators
# ===========================================================================
check "arith +=" "8" "$(timeout 3 $DEN -c 'x=5; echo $((x+=3))')"
check "arith -=" "7" "$(timeout 3 $DEN -c 'x=10; echo $((x-=3))')"
check "arith *=" "15" "$(timeout 3 $DEN -c 'x=5; echo $((x*=3))')"
check "arith /=" "5" "$(timeout 3 $DEN -c 'x=15; echo $((x/=3))')"
check "arith %=" "2" "$(timeout 3 $DEN -c 'x=17; echo $((x%=5))')"

# ===========================================================================
# 113. [[ && ]] and [[ || ]] inside double brackets
# ===========================================================================
check "[[ && ]]" "yes" "$(timeout 3 $DEN -c '[[ 1 -eq 1 && 2 -eq 2 ]] && echo yes || echo no')"
check "[[ || ]]" "yes" "$(timeout 3 $DEN -c '[[ 1 -eq 2 || 2 -eq 2 ]] && echo yes || echo no')"
check "[[ && false ]]" "no" "$(timeout 3 $DEN -c '[[ 1 -eq 1 && 2 -eq 3 ]] && echo yes || echo no')"

# ===========================================================================
# 114. File tests (stat-based, not requiring open)
# ===========================================================================
check "[[ -f /etc/hosts ]]" "yes" "$(timeout 3 $DEN -c '[[ -f /etc/hosts ]] && echo yes || echo no')"
check "[[ -d /tmp ]]" "yes" "$(timeout 3 $DEN -c '[[ -d /tmp ]] && echo yes || echo no')"
check "[[ -e /etc/hosts ]]" "yes" "$(timeout 3 $DEN -c '[[ -e /etc/hosts ]] && echo yes || echo no')"

# ===========================================================================
# 115. FD duplication shorthand >&N / <&N
# ===========================================================================
check ">&2 redirect" "hello" "$(timeout 3 $DEN -c 'echo hello >&2' 2>&1)"
check "[[ paren group ]]" "yes" "$(timeout 3 $DEN -c '[[ ( 1 -eq 1 ) && ( 2 -eq 2 ) ]] && echo yes || echo no')"

# ===========================================================================
# 116. Case glob patterns
# ===========================================================================
check "case h*o glob" "matched" "$(timeout 3 $DEN -c 'x=hello; case $x in h*o) echo matched;; *) echo no;; esac')"
check "case h?llo glob" "matched" "$(timeout 3 $DEN -c 'x=hello; case $x in h?llo) echo matched;; *) echo no;; esac')"
check "case [a-z]* glob" "matched" "$(timeout 3 $DEN -c 'x=hello; case $x in [a-z]*) echo matched;; *) echo no;; esac')"
check "case or pattern" "matched" "$(timeout 3 $DEN -c 'x=b; case $x in a|b) echo matched;; *) echo no;; esac')"

# ===========================================================================
# 117. (( )) arithmetic command with && / ||
# ===========================================================================
check "(( )) && true" "yes" "$(timeout 3 $DEN -c '(( 5 > 3 )) && echo yes || echo no')"
check "(( )) && false" "no" "$(timeout 3 $DEN -c '(( 3 > 5 )) && echo yes || echo no')"
check "(( )) exit code" "0" "$(timeout 3 $DEN -c '(( 5 > 3 )); echo $?')"

# ===========================================================================
# 118. HOSTNAME variable
# ===========================================================================
check "HOSTNAME not empty" "yes" "$(timeout 3 $DEN -c '[[ -n $HOSTNAME ]] && echo yes || echo no')"

# ===========================================================================
# 119. Control flow piping (for/while/if/case ... | cmd)
# ===========================================================================
check "for pipe" "A
B
C" "$(timeout 3 $DEN -c 'for f in a b c; do echo "$f"; done | tr a-z A-Z')"
check "for pipe wc" "3" "$(timeout 3 $DEN -c 'for i in 1 2 3; do echo "$i"; done | wc -l | tr -d " "')"
check "for pipe sort" "a
b
c" "$(timeout 3 $DEN -c 'for f in c a b; do echo "$f"; done | sort')"
check "for pipe chain" "A
B
C" "$(timeout 3 $DEN -c 'for f in c a b; do echo "$f"; done | sort | tr a-z A-Z')"
check "if pipe" "HELLO" "$(timeout 3 $DEN -c 'if true; then echo hello; fi | tr a-z A-Z')"
check "if else pipe" "YES" "$(timeout 3 $DEN -c 'if false; then echo no; else echo yes; fi | tr a-z A-Z')"
check "if multi pipe" "3" "$(timeout 3 $DEN -c 'if true; then echo a; echo b; echo c; fi | wc -l | tr -d " "')"
check "case pipe" "MATCHED" "$(timeout 3 $DEN -c 'x=hello; case $x in hello) echo "matched";; esac | tr a-z A-Z')"
check "for pipe grep" "b" "$(timeout 3 $DEN -c 'for f in a b c; do echo "$f"; done | grep b')"

# ===========================================================================
# 120. Subshell piping ((cmd1; cmd2) | cmd)
# ===========================================================================
check "subshell pipe wc" "2" "$(timeout 3 $DEN -c '(echo hello; echo world) | wc -l | tr -d " "')"
check "subshell pipe tr" "HELLO
WORLD" "$(timeout 3 $DEN -c '(echo hello; echo world) | tr a-z A-Z')"
check "subshell pipe sort" "a
b
c" "$(timeout 3 $DEN -c '(echo c; echo a; echo b) | sort')"
check "subshell pipe chain" "A
B
C" "$(timeout 3 $DEN -c '(echo c; echo a; echo b) | sort | tr a-z A-Z')"
check "simple subshell" "hello
world" "$(timeout 3 $DEN -c '(echo hello; echo world)')"
check "subshell var isolation" "outer" "$(timeout 3 $DEN -c 'x=outer; (x=inner); echo "$x"')"
check "nested subshell pipe" "2" "$(timeout 3 $DEN -c '(echo a; (echo b)) | wc -l | tr -d " "')"

# ===========================================================================
# 121. Let arithmetic evaluation
# ===========================================================================
check "let add" "10" "$(timeout 3 $DEN -c 'let x=5+5; echo $x')"
check "let mult" "20" "$(timeout 3 $DEN -c 'let x=4*5; echo $x')"
check "let sub" "3" "$(timeout 3 $DEN -c 'let x=8-5; echo $x')"
check "let div" "4" "$(timeout 3 $DEN -c 'let x=20/5; echo $x')"
check "let literal" "42" "$(timeout 3 $DEN -c 'let x=42; echo $x')"

# ===========================================================================
# 122. Control flow keyword with suffix (done|, fi;, etc.)
# ===========================================================================
check "done semicolon" "a
b" "$(timeout 3 $DEN -c 'for f in a b; do echo "$f"; done; echo ""' | head -2)"
check "done pipe inline" "2" "$(timeout 3 $DEN -c 'for f in a b; do echo "$f"; done | wc -l | tr -d " "')"

# ===========================================================================
# 123. Heredoc in -c mode
# ===========================================================================
check "herestring basic" "hello world" "$(timeout 3 $DEN -c 'cat <<< "hello world"')"
check "herestring var" "hello world" "$(timeout 3 $DEN -c 'x="hello world"; cat <<< "$x"')"

# ===========================================================================
# 124. Command substitution with control flow pipe
# ===========================================================================
check "subst for pipe" "X
Y
Z" "$(timeout 3 $DEN -c 'result=$(for f in x y z; do echo "$f"; done | tr a-z A-Z); echo "$result"')"

# ===========================================================================
# 125. Case statement with quoted values and glob patterns
# ===========================================================================
check "case quoted exact" "matched" "$(timeout 3 $DEN -c 'case "hello" in hello) echo matched;; *) echo no;; esac')"
check "case quoted glob prefix" "matched" "$(timeout 3 $DEN -c 'case "hello" in h*) echo matched;; *) echo no;; esac')"
check "case quoted glob suffix" "matched" "$(timeout 3 $DEN -c 'case "hello" in *lo) echo matched;; *) echo no;; esac')"
check "case quoted pipe pattern" "pipe" "$(timeout 3 $DEN -c 'case "hello" in hi|hello) echo pipe;; *) echo no;; esac')"
check "case single quoted" "matched" "$(timeout 3 $DEN -c "case 'hello' in hello) echo matched;; *) echo no;; esac")"
check "case var pattern" "varpat" "$(timeout 3 $DEN -c 'PAT=hello; case "hello" in $PAT) echo varpat;; *) echo no;; esac')"
check "case quoted both" "yes" "$(timeout 3 $DEN -c 'case "abc" in "abc") echo yes;; *) echo no;; esac')"
check "case unquoted ok" "yes" "$(timeout 3 $DEN -c 'case hello in hello) echo yes;; *) echo no;; esac')"

# ===========================================================================
# 126. Nested quotes in $() command substitution
# ===========================================================================
check "nested dq in cmd sub" "result: hello world" "$(timeout 3 $DEN -c 'echo "result: $(echo "hello world")"')"
check "nested dq pipe" "3" "$(timeout 3 $DEN -c 'echo "$(echo -e "a\nb\nc" | wc -l | tr -d " ")"')"
check "multi cmd sub dq" "hello world" "$(timeout 3 $DEN -c 'echo "$(echo "hello") $(echo "world")"')"
check "deep nested cmd sub" "deep" "$(timeout 3 $DEN -c 'echo "$(echo "$(echo "deep")")"')"

# ===========================================================================
# 127. Export variables visible in $()
# ===========================================================================
check "export in cmd sub" "hello" "$(timeout 3 $DEN -c 'export X=hello; echo $(echo $X)')"
check "export dq cmd sub" "val: world" "$(timeout 3 $DEN -c 'export X=world; echo "val: $(echo "$X")"')"
check "export name cmd sub" "done" "$(timeout 3 $DEN -c 'Y=done; export Y; echo $(echo $Y)')"

# ===========================================================================
# 128. Per-command temporary variable assignment (VAR=val cmd)
# ===========================================================================
check "IFS read colon" "a b c" "$(echo 'a:b:c' | timeout 3 $DEN -c 'IFS=: read x y z; echo "$x $y $z"')"
check "temp var env" "bar" "$(timeout 3 $DEN -c 'FOO=bar env | grep "^FOO=" | cut -d= -f2')"
check "temp var restore" "test
original" "$(timeout 3 $DEN -c 'X=original; X=temp echo test; echo $X')"
check "temp var unset after" "ok
unset" "$(timeout 3 $DEN -c 'NEWVAR=hello echo ok; echo ${NEWVAR:-unset}')"
check "multi temp var" "1 2" "$(timeout 3 $DEN -c 'A=1 B=2 env | grep -E "^(A|B)=" | sort | cut -d= -f2 | tr "\n" " " | sed "s/ $//"')"
check "IFS comma heredoc" "x y z" "$(timeout 3 $DEN -c 'IFS=, read -r a b c <<< "x,y,z"; echo "$a $b $c"')"

# ===========================================================================
# 129. Multiline strings in -c mode
# ===========================================================================
check "multiline dq var" "line1
line2" "$(timeout 3 $DEN -c 'x="line1
line2"; echo "$x"')"
check "multiline sq var" "line1
line2" "$(timeout 3 $DEN -c "x='line1
line2'; echo \"\$x\"")"
check "multiline heredoc -c" "hello world" "$(timeout 3 $DEN -c 'cat << EOF
hello world
EOF')"

# ===========================================================================
# 130. Glob suppression in quotes and escaped dollar
# ===========================================================================
check "dq no glob" "/dev/nul*" "$(timeout 3 $DEN -c 'echo "/dev/nul*"')"
check "sq no glob" "/dev/nul*" "$(timeout 3 $DEN -c "echo '/dev/nul*'")"
check "unquoted glob" "/dev/null" "$(timeout 3 $DEN -c 'echo /dev/nul*')"
check "escaped dollar dq" '$HOME' "$(timeout 3 $DEN -c 'echo "\$HOME"')"
check "escaped dollar cost" 'cost is $5' "$(timeout 3 $DEN -c 'echo "cost is \$5"')"

# ===========================================================================
# 131. Functions visible in command substitution
# ===========================================================================
check "func in cmd sub" "hello" "$(timeout 3 $DEN -c 'f() { echo hello; }; echo $(f)')"
check "func result var" "hello" "$(timeout 3 $DEN -c 'f() { echo hello; }; result=$(f); echo $result')"
check "recursive func" "120" "$(timeout 5 $DEN -c 'fact() { if [ $1 -le 1 ]; then echo 1; else local n=$1; local prev=$(fact $((n-1))); echo $((n * prev)); fi; }; fact 5')"

# ===========================================================================
# 132. Extended test [[ ]] in if statements
check "[[ glob in if ]]" "match" "$(timeout 3 $DEN -c 'if [[ "hello" == hel* ]]; then echo "match"; fi' 2>/dev/null)"
check "[[ regex in if ]]" "match" "$(timeout 3 $DEN -c 'if [[ "hello123" =~ ^hello[0-9]+$ ]]; then echo "match"; fi' 2>/dev/null)"
check "[[ != glob in if ]]" "nomatch" "$(timeout 3 $DEN -c 'if [[ "hello" != xyz* ]]; then echo "nomatch"; fi' 2>/dev/null)"

# 133. Positional params in arithmetic
check "arith \$1+\$2" "7" "$(timeout 3 $DEN -c 'add() { echo $(($1 + $2)); }; add 3 4' 2>/dev/null)"
check "arith \$1*\$2" "30" "$(timeout 3 $DEN -c 'mul() { echo $(($1 * $2)); }; mul 5 6' 2>/dev/null)"

# 134. read -r raw mode
check "read -r raw" 'hello\nworld' "$(timeout 3 $DEN -c 'read -r line <<< "hello\nworld"; echo "$line"' 2>/dev/null)"
check "read no-r escape" "hellonworld" "$(timeout 3 $DEN -c 'read line <<< "hello\nworld"; echo "$line"' 2>/dev/null)"

# 135. Functions in pipelines
check "func in pipeline" "HELLO" "$(timeout 3 $DEN -c 'upper() { tr a-z A-Z; }; echo hello | upper' 2>/dev/null)"
check "func mid pipeline" "HELLO HELLO" "$(timeout 3 $DEN -c 'double() { while read line; do echo "$line $line"; done; }; echo hello | double | tr a-z A-Z' 2>/dev/null)"

# 136. Functions with && and || operators
check "func && chain" "ok" "$(timeout 3 $DEN -c 'f() { return 0; }; f && echo ok' 2>/dev/null)"
check "func || chain" "fail" "$(timeout 3 $DEN -c 'f() { return 1; }; f || echo fail' 2>/dev/null)"
check "func && fail" "" "$(timeout 3 $DEN -c 'f() { return 1; }; f && echo nope' 2>/dev/null)"

# 137. Alpha brace expansion with step
check "alpha brace step" "a f k p u z" "$(timeout 3 $DEN -c 'echo {a..z..5}' 2>/dev/null)"
check "alpha brace step rev" "z u p k f a" "$(timeout 3 $DEN -c 'echo {z..a..5}' 2>/dev/null)"

# 138. $? expansion in double quotes
check "\$? unquoted" "1" "$(timeout 3 $DEN -c 'false; echo $?' 2>/dev/null)"
check "\$? in dquotes" "1" "$(timeout 3 $DEN -c 'false; echo "$?"' 2>/dev/null)"
check "\$? embedded" "exit: 1" "$(timeout 3 $DEN -c 'false; echo "exit: $?"' 2>/dev/null)"

# 139. ${?} and ${!} special variable expansion in braces
check "\${?} expansion" "1" "$(timeout 3 $DEN -c 'false; echo "${?}"' 2>/dev/null)"
check "\${$} expansion pid" "yes" "$(timeout 3 $DEN -c 'pid="${$}"; if [ "$pid" -gt 0 ]; then echo yes; fi' 2>/dev/null)"

# 140. $(cmd) inside $((...)) arithmetic
check "arith cmd sub" "7" "$(timeout 3 $DEN -c 'echo $(( $(echo 3) + $(echo 4) ))' 2>/dev/null)"
check "arith multi cmd sub" "60" "$(timeout 3 $DEN -c 'echo $(( $(echo 10) + $(echo 20) + $(echo 30) ))' 2>/dev/null)"
check "arith func cmd sub" "77" "$(timeout 3 $DEN -c 'add() { echo $(( $1 + $2 )); }; echo $(( $(add 3 4) * $(add 5 6) ))' 2>/dev/null)"

# 141. Brace group redirections
check "brace group basic" "hello" "$(timeout 3 $DEN -c '{ echo hello; }' 2>/dev/null)"
check "brace group > file" "hello
world" "$(timeout 3 $DEN -c '{ echo hello; echo world; } > /tmp/den_test_bg; cat /tmp/den_test_bg; rm /tmp/den_test_bg' 2>/dev/null)"
check "brace group 2>/dev/null" "out" "$(timeout 3 $DEN -c '{ echo out; echo err >&2; } 2>/dev/null' 2>/dev/null)"
check "brace group | pipe" "2" "$(timeout 3 $DEN -c '{ echo a; echo b; } | wc -l' 2>/dev/null | tr -d ' ')"

# 142. IFS word splitting
check "IFS split unquoted" "a b c" "$(timeout 3 $DEN -c 'x="a   b   c"; echo $x' 2>/dev/null)"
check "IFS quoted preserves" "a   b   c" "$(timeout 3 $DEN -c 'x="a   b   c"; echo "$x"' 2>/dev/null)"
check "IFS split args" "[hello]
[world]" "$(timeout 3 $DEN -c 'x="hello world"; printf "[%s]\n" $x' 2>/dev/null)"
check "IFS quoted single arg" "[hello world]" "$(timeout 3 $DEN -c 'x="hello world"; printf "[%s]\n" "$x"' 2>/dev/null)"

# ===========================================================================
# 143. Tilde expansion in quotes (REGRESSION: was expanding ~ inside quotes)
# ===========================================================================
check "tilde dquote literal" "~" "$(timeout 3 $DEN -c 'echo "~"' 2>/dev/null)"
check "tilde squote literal" "~" "$(timeout 3 $DEN -c "echo '~'" 2>/dev/null)"
check "tilde unquoted expands" "$HOME" "$(timeout 3 $DEN -c 'echo ~' 2>/dev/null)"
check "tilde dquote path" "~/test" "$(timeout 3 $DEN -c 'echo "~/test"' 2>/dev/null)"
check "tilde unquoted path" "$HOME/test" "$(timeout 3 $DEN -c 'echo ~/test' 2>/dev/null)"
check "tilde in mid-string" "before~after" "$(timeout 3 $DEN -c 'echo "before~after"' 2>/dev/null)"
check "tilde assign unquoted" "$HOME" "$(timeout 3 $DEN -c 'x=~; echo "$x"' 2>/dev/null)"
check "tilde assign quoted" "~" "$(timeout 3 $DEN -c 'x="~"; echo "$x"' 2>/dev/null)"
check "tilde assign path" "$HOME/test" "$(timeout 3 $DEN -c 'x=~/test; echo "$x"' 2>/dev/null)"
check "tilde assign quoted path" "~/test" "$(timeout 3 $DEN -c 'x="~/test"; echo "$x"' 2>/dev/null)"

# ===========================================================================
# 144. One-liner control flow in scripts (REGRESSION: was silent)
# ===========================================================================
check "oneliner for" "a b c" "$(timeout 3 $DEN -c 'for i in a b c; do echo $i; done' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "oneliner while" "0 1 2" "$(timeout 3 $DEN -c 'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "oneliner if then" "yes" "$(timeout 3 $DEN -c 'if true; then echo yes; fi' 2>/dev/null)"
check "oneliner if else" "no" "$(timeout 3 $DEN -c 'if false; then echo yes; else echo no; fi' 2>/dev/null)"
check "oneliner until" "3" "$(timeout 3 $DEN -c 'i=0; until [ $i -ge 3 ]; do i=$((i+1)); done; echo $i' 2>/dev/null)"
check "oneliner nested for-if" "found 2" "$(timeout 3 $DEN -c 'for i in 1 2 3; do if [ $i -eq 2 ]; then echo "found $i"; fi; done' 2>/dev/null)"
check "oneliner for concat" "123" "$(timeout 3 $DEN -c 'r=""; for i in 1 2 3; do r="$r$i"; done; echo $r' 2>/dev/null)"
check "oneliner nested for" "a1 a2 b1 b2" "$(timeout 3 $DEN -c 'for i in a b; do for j in 1 2; do echo "$i$j"; done; done' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "oneliner if multi body" "a b c" "$(timeout 3 $DEN -c 'if true; then echo "a"; echo "b"; echo "c"; fi' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 145. Case toggle operators (NEW: ${var~} and ${var~~})
# ===========================================================================
check "case toggle first" "Hello" "$(timeout 3 $DEN -c 'x=hello; echo ${x~}' 2>/dev/null)"
check "case toggle all" "HELLO world" "$(timeout 3 $DEN -c 'x="hello WORLD"; echo ${x~~}' 2>/dev/null)"
check "case toggle upper" "hELLO" "$(timeout 3 $DEN -c 'x=HELLO; echo ${x~}' 2>/dev/null)"
check "case toggle mixed" "FOObar" "$(timeout 3 $DEN -c 'x=fooBAR; echo ${x~~}' 2>/dev/null)"

# ===========================================================================
# 146. PIPESTATUS double-free fix (REGRESSION: crashed with pipefail)
# ===========================================================================
check "pipefail status" "1" "$(timeout 3 $DEN -c 'set -o pipefail; false | true; echo $?' 2>/dev/null)"
check "pipefail pass" "0" "$(timeout 3 $DEN -c 'set -o pipefail; true | true; echo $?' 2>/dev/null)"
check "pipestatus after pipe" "0 1 0" "$(timeout 3 $DEN -c 'true | false | true; echo ${PIPESTATUS[@]}' 2>/dev/null)"
check "pipestatus multi" "0" "$(timeout 3 $DEN -c 'echo a | cat | cat; echo $?' 2>/dev/null | tail -1)"

# ===========================================================================
# 147. read -p prompt (REGRESSION: prompt not displayed)
# ===========================================================================
check "read -p stderr" "prompt" "$(echo 'val' | timeout 3 $DEN -c 'read -p "prompt" x' 2>&1 >/dev/null)"

# ===========================================================================
# 148. Additional quoting edge cases
# ===========================================================================
check "empty dquote" "" "$(timeout 3 $DEN -c 'echo -n ""' 2>/dev/null)"
check "empty squote" "" "$(timeout 3 $DEN -c "echo -n ''" 2>/dev/null)"
check "dquote preserve spaces" "a  b  c" "$(timeout 3 $DEN -c 'echo "a  b  c"' 2>/dev/null)"
check "squote no expand" '$HOME' "$(timeout 3 $DEN -c "echo '\$HOME'" 2>/dev/null)"
check "mixed quotes concat" "helloworld" "$(timeout 3 $DEN -c "echo 'hello'\"world\"" 2>/dev/null)"
check "backslash in dquote" '\n' "$(timeout 3 $DEN -c 'echo "\n"' 2>/dev/null)"
check "dollar literal" '$' "$(timeout 3 $DEN -c 'echo \$' 2>/dev/null)"
check "escaped dquote" '"' "$(timeout 3 $DEN -c 'echo \"' 2>/dev/null)"

# ===========================================================================
# 149. Arithmetic edge cases
# ===========================================================================
check "arith power" "256" "$(timeout 3 $DEN -c 'echo $(( 2 ** 8 ))' 2>/dev/null)"
check "arith modulo" "1" "$(timeout 3 $DEN -c 'echo $(( 7 % 3 ))' 2>/dev/null)"
check "arith bitwise and" "2" "$(timeout 3 $DEN -c 'echo $(( 6 & 3 ))' 2>/dev/null)"
check "arith bitwise or" "7" "$(timeout 3 $DEN -c 'echo $(( 5 | 3 ))' 2>/dev/null)"
check "arith bitwise xor" "6" "$(timeout 3 $DEN -c 'echo $(( 5 ^ 3 ))' 2>/dev/null)"
check "arith unary minus" "-10" "$(timeout 3 $DEN -c 'echo $(( -(5+5) ))' 2>/dev/null)"
check "arith nested parens" "30" "$(timeout 3 $DEN -c 'echo $(( (2 + 3) * (1 + 5) ))' 2>/dev/null)"
check "arith large power" "1073741824" "$(timeout 3 $DEN -c 'echo $(( 2 ** 30 ))' 2>/dev/null)"
check "arith negative mod" "-3" "$(timeout 3 $DEN -c 'echo $(( -7 % 4 ))' 2>/dev/null)"
check "arith shift right" "4" "$(timeout 3 $DEN -c 'echo $(( 16 >> 2 ))' 2>/dev/null)"

# ===========================================================================
# 150. String operations edge cases
# ===========================================================================
check "param empty default" "default" "$(timeout 3 $DEN -c 'x=""; echo ${x:-default}' 2>/dev/null)"
check "param set no default" "value" "$(timeout 3 $DEN -c 'x=value; echo ${x:-default}' 2>/dev/null)"
check "param :+ set" "alt" "$(timeout 3 $DEN -c 'x=set; echo ${x:+alt}' 2>/dev/null)"
check "param :+ unset" "" "$(timeout 3 $DEN -c 'echo -n ${x:+alt}' 2>/dev/null)"
check "suffix strip %%" "hello" "$(timeout 3 $DEN -c 'x=hello.tar.gz; echo ${x%%.*}' 2>/dev/null)"
check "suffix strip %" "hello.tar" "$(timeout 3 $DEN -c 'x=hello.tar.gz; echo ${x%.*}' 2>/dev/null)"
check "prefix strip #" "llo" "$(timeout 3 $DEN -c 'x=hello; echo ${x#he}' 2>/dev/null)"
check "prefix strip ##" "file.txt" "$(timeout 3 $DEN -c 'x=/a/b/c/file.txt; echo ${x##*/}' 2>/dev/null)"
check "replace prefix" "xyz world" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x/#hello/xyz}' 2>/dev/null)"
check "replace suffix" "hello xyz" "$(timeout 3 $DEN -c 'x="hello world"; echo ${x/%world/xyz}' 2>/dev/null)"
check "lowercase first" "hELLO" "$(timeout 3 $DEN -c 'x=HELLO; echo ${x,}' 2>/dev/null)"

# ===========================================================================
# 151. Control flow edge cases
# ===========================================================================
check "empty for body" "" "$(timeout 3 $DEN -c 'for i in; do echo $i; done' 2>/dev/null)"
check "for empty list" "" "$(timeout 3 $DEN -c 'x=""; for i in $x; do echo $i; done' 2>/dev/null)"
check "while false" "" "$(timeout 3 $DEN -c 'while false; do echo nope; done' 2>/dev/null)"
check "case no match" "" "$(timeout 3 $DEN -c 'case x in a) echo a;; b) echo b;; esac' 2>/dev/null)"
check "case default" "default" "$(timeout 3 $DEN -c 'case x in a) echo a;; *) echo default;; esac' 2>/dev/null)"
check "if elif else" "medium" "$(timeout 3 $DEN -c 'x=5; if [ $x -gt 10 ]; then echo big; elif [ $x -gt 3 ]; then echo medium; else echo small; fi' 2>/dev/null)"
check "for in braces" "6" "$(timeout 3 $DEN -c 's=0; for i in {1..3}; do s=$((s+i)); done; echo $s' 2>/dev/null)"
check "nested while" "4" "$(timeout 3 $DEN -c 'c=0; i=0; while [ $i -lt 2 ]; do j=0; while [ $j -lt 2 ]; do c=$((c+1)); j=$((j+1)); done; i=$((i+1)); done; echo $c' 2>/dev/null)"
check "break from nested" "3" "$(timeout 3 $DEN -c 'for i in 1 2 3; do for j in a b c; do if [ $j = b ]; then break; fi; done; done; echo $i' 2>/dev/null)"

# ===========================================================================
# 152. Function edge cases
# ===========================================================================
check "func no args" "noargs" "$(timeout 3 $DEN -c 'f() { echo noargs; }; f' 2>/dev/null)"
check "func return 0" "0" "$(timeout 3 $DEN -c 'f() { return 0; }; f; echo $?' 2>/dev/null)"
check "func return 1" "1" "$(timeout 3 $DEN -c 'f() { return 1; }; f; echo $?' 2>/dev/null)"
check "func local default" "" "$(timeout 3 $DEN -c 'f() { local x; echo -n "$x"; }; f' 2>/dev/null)"
check "func argcount" "3" "$(timeout 3 $DEN -c 'f() { echo $#; }; f a b c' 2>/dev/null)"
check "func recursive" "6" "$(timeout 3 $DEN -c 'fact() { if [ $1 -le 1 ]; then echo 1; else echo $(( $1 * $(fact $(($1-1))) )); fi; }; fact 3' 2>/dev/null)"
check "func captures exit" "0" "$(timeout 3 $DEN -c 'f() { true; }; f; echo $?' 2>/dev/null)"

# ===========================================================================
# 153. Variable edge cases
# ===========================================================================
check "var underscore" "ok" "$(timeout 3 $DEN -c '_x=ok; echo $_x' 2>/dev/null)"
check "var numeric suffix" "ok" "$(timeout 3 $DEN -c 'x1=ok; echo $x1' 2>/dev/null)"
check "var empty assign" "" "$(timeout 3 $DEN -c 'x=; echo -n "$x"' 2>/dev/null)"
check "var plus-eq string" "helloworld" "$(timeout 3 $DEN -c 'x=hello; x+=world; echo $x' 2>/dev/null)"
check "var assign cmd sub" "hello" "$(timeout 3 $DEN -c 'x=$(echo hello); echo $x' 2>/dev/null)"
check "var embedded expand" "val=hello" "$(timeout 3 $DEN -c 'x=hello; echo "val=$x"' 2>/dev/null)"
check "var curly expand" "hello_world" "$(timeout 3 $DEN -c 'x=hello; echo "${x}_world"' 2>/dev/null)"
check "var concat no space" "ab" "$(timeout 3 $DEN -c 'a=a; b=b; c=$a$b; echo $c' 2>/dev/null)"
check "var double assign" "second" "$(timeout 3 $DEN -c 'x=first; x=second; echo $x' 2>/dev/null)"

# ===========================================================================
# 154. Redirection edge cases
# ===========================================================================
check "redir append create" "line1" "$(rm -f /tmp/den_test_app.txt; timeout 3 $DEN -c 'echo line1 >> /tmp/den_test_app.txt; cat /tmp/den_test_app.txt; rm -f /tmp/den_test_app.txt' 2>/dev/null)"
check "redir input" "hello" "$(echo 'hello' > /tmp/den_test_in.txt; timeout 3 $DEN -c 'cat < /tmp/den_test_in.txt' 2>/dev/null; rm -f /tmp/den_test_in.txt)"
check "redir stderr 2>" "" "$(timeout 3 $DEN -c 'echo err >&2' 2>/dev/null)"
check "redir stdout and stderr" "out" "$(timeout 3 $DEN -c 'echo out; echo err >&2' 2>/dev/null)"
check "redir both &>" "both" "$(timeout 3 $DEN -c 'echo both &>/tmp/den_test_both.txt; cat /tmp/den_test_both.txt; rm -f /tmp/den_test_both.txt' 2>/dev/null)"
check "redir both append &>>" "line2" "$(timeout 3 $DEN -c 'echo line1 &>/tmp/den_test_ba.txt; echo line2 &>>/tmp/den_test_ba.txt; tail -1 /tmp/den_test_ba.txt; rm -f /tmp/den_test_ba.txt' 2>/dev/null)"
check "redir fd close >&-" "ok" "$(timeout 3 $DEN -c 'echo ok 2>&-' 2>/dev/null)"

# ===========================================================================
# 155. Pipeline edge cases
# ===========================================================================
check "pipe exit status" "0" "$(timeout 3 $DEN -c 'echo hello | cat > /dev/null; echo $?' 2>/dev/null)"
check "multi pipe" "hello" "$(timeout 3 $DEN -c 'echo hello | cat | cat | cat' 2>/dev/null)"
check "pipe to head" "1" "$(timeout 3 $DEN -c 'printf "1\n2\n3\n" | head -1' 2>/dev/null)"
check "pipe to tail" "3" "$(timeout 3 $DEN -c 'printf "1\n2\n3\n" | tail -1' 2>/dev/null)"
check "pipe to wc" "3" "$(timeout 3 $DEN -c 'printf "a\nb\nc\n" | wc -l' 2>/dev/null | tr -d ' ')"
check "pipe to sort" "a b c" "$(timeout 3 $DEN -c 'printf "c\na\nb\n" | sort' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "pipe to uniq" "a b" "$(timeout 3 $DEN -c 'printf "a\na\nb\nb\n" | uniq' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 156. Heredoc edge cases
# ===========================================================================
check "heredoc expand" "hello" "$(timeout 3 $DEN -c 'x=hello; cat <<EOF
$x
EOF' 2>/dev/null)"
check "heredoc multiline" "a
b
c" "$(timeout 3 $DEN -c 'cat <<EOF
a
b
c
EOF' 2>/dev/null)"

# ===========================================================================
# 157. Process substitution
# ===========================================================================
check "proc subst diff" "same" "$(timeout 3 $DEN -c 'diff <(echo abc) <(echo abc) && echo same || echo diff' 2>/dev/null)"
check "proc subst cat" "hello" "$(timeout 3 $DEN -c 'cat <(echo hello)' 2>/dev/null)"

# ===========================================================================
# 158. Subshell edge cases
# ===========================================================================
check "subshell exit code" "1" "$(timeout 3 $DEN -c '(exit 1); echo $?' 2>/dev/null)"
check "subshell var isolate" "outer" "$(timeout 3 $DEN -c 'x=outer; (x=inner); echo $x' 2>/dev/null)"
check "subshell pipeline" "3" "$(timeout 3 $DEN -c '(echo -e "a\nb\nc") | wc -l' 2>/dev/null | tr -d ' ')"
check "subshell nested" "deep" "$(timeout 3 $DEN -c '(echo $(echo deep))' 2>/dev/null)"

# ===========================================================================
# 159. Array advanced operations
# ===========================================================================
check "arr string elem" "hello world" "$(timeout 3 $DEN -c 'arr=("hello world" "foo"); echo ${arr[0]}' 2>/dev/null)"
check "arr empty init" "0" "$(timeout 3 $DEN -c 'arr=(); echo ${#arr[@]}' 2>/dev/null)"
check "arr append multi" "a b c d e" "$(timeout 3 $DEN -c 'arr=(a b); arr+=(c d e); echo ${arr[@]}' 2>/dev/null)"
check "arr all star" "a b c" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[*]}' 2>/dev/null)"
check "arr index negative" "c" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[-1]}' 2>/dev/null)"

# ===========================================================================
# 160. Associative array edge cases
# ===========================================================================
check "assoc overwrite" "new" "$(timeout 3 $DEN -c 'declare -A m; m[k]=old; m[k]=new; echo ${m[k]}' 2>/dev/null)"
check "assoc unset elem" "" "$(timeout 3 $DEN -c 'declare -A m; m[k]=v; unset m[k]; echo -n "${m[k]}"' 2>/dev/null)"
check "assoc length" "2" "$(timeout 3 $DEN -c 'declare -A m=([a]=1 [b]=2); echo ${#m[@]}' 2>/dev/null)"

# ===========================================================================
# 161. Special variables
# ===========================================================================
check "\$\$ is positive" "yes" "$(timeout 3 $DEN -c 'if [ $$ -gt 0 ]; then echo yes; fi' 2>/dev/null)"
check "\$# no args" "0" "$(timeout 3 $DEN -c 'echo $#' 2>/dev/null)"
check "\$0 is den" "yes" "$(timeout 3 $DEN -c 'case $0 in *den*) echo yes;; *) echo no;; esac' 2>/dev/null)"
check "SECONDS type" "yes" "$(timeout 3 $DEN -c 'if [ "$SECONDS" -ge 0 ] 2>/dev/null; then echo yes; fi' 2>/dev/null)"

# ===========================================================================
# 162. Brace expansion edge cases
# ===========================================================================
check "brace numeric" "1 2 3 4 5" "$(timeout 3 $DEN -c 'echo {1..5}' 2>/dev/null)"
check "brace alpha" "a b c d e" "$(timeout 3 $DEN -c 'echo {a..e}' 2>/dev/null)"
check "brace reverse" "5 4 3 2 1" "$(timeout 3 $DEN -c 'echo {5..1}' 2>/dev/null)"
check "brace step" "1 3 5 7 9" "$(timeout 3 $DEN -c 'echo {1..9..2}' 2>/dev/null)"
check "brace list" "ax bx cx" "$(timeout 3 $DEN -c 'echo {a,b,c}x' 2>/dev/null)"
check "brace combo" "a1 a2 b1 b2" "$(timeout 3 $DEN -c 'echo {a,b}{1,2}' 2>/dev/null)"
check "brace zero pad" "01 02 03" "$(timeout 3 $DEN -c 'echo {01..03}' 2>/dev/null)"

# ===========================================================================
# 163. Printf edge cases
# ===========================================================================
check "printf string" "hello" "$(timeout 3 $DEN -c 'printf "%s" "hello"' 2>/dev/null)"
check "printf newline" "hello" "$(timeout 3 $DEN -c 'printf "%s\n" "hello"' 2>/dev/null)"
check "printf decimal" "42" "$(timeout 3 $DEN -c 'printf "%d" 42' 2>/dev/null)"
check "printf hex" "ff" "$(timeout 3 $DEN -c 'printf "%x" 255' 2>/dev/null)"
check "printf octal" "77" "$(timeout 3 $DEN -c 'printf "%o" 63' 2>/dev/null)"
check "printf width" "  42" "$(timeout 3 $DEN -c 'printf "%4d" 42' 2>/dev/null)"
check "printf left align" "42  " "$(timeout 3 $DEN -c 'printf "%-4d" 42' 2>/dev/null)"
check "printf %q" "'hello world'" "$(timeout 3 $DEN -c "printf '%q' 'hello world'" 2>/dev/null)"

# ===========================================================================
# 164. Echo edge cases
# ===========================================================================
check "echo -n no newline" "hello" "$(timeout 3 $DEN -c 'echo -n hello; echo -n ""' 2>/dev/null)"
check "echo -e tab" "a	b" "$(timeout 3 $DEN -c 'echo -e "a\tb"' 2>/dev/null)"
check "echo -e newline" "a
b" "$(timeout 3 $DEN -c 'echo -e "a\nb"' 2>/dev/null)"
check "echo -E no escape" 'a\nb' "$(timeout 3 $DEN -c 'echo -E "a\nb"' 2>/dev/null)"
check "echo no args" "" "$(timeout 3 $DEN -c 'echo' 2>/dev/null)"
check "echo multi args" "a b c" "$(timeout 3 $DEN -c 'echo a b c' 2>/dev/null)"

# ===========================================================================
# 165. Command substitution edge cases
# ===========================================================================
check "cmd sub nested" "INNER" "$(timeout 3 $DEN -c 'echo $(echo $(echo INNER))' 2>/dev/null)"
check "cmd sub in dquote" "result: hello" "$(timeout 3 $DEN -c 'echo "result: $(echo hello)"' 2>/dev/null)"
check "cmd sub backtick" "hello" "$(timeout 3 $DEN -c 'echo `echo hello`' 2>/dev/null)"
check "cmd sub strips newline" "hello" "$(timeout 3 $DEN -c 'x=$(printf "hello\n"); echo "$x"' 2>/dev/null)"
check "cmd sub multiline" "a b" "$(timeout 3 $DEN -c 'x=$(printf "a\nb"); echo $x' 2>/dev/null)"
check "cmd sub empty" "" "$(timeout 3 $DEN -c 'x=$(true); echo -n "$x"' 2>/dev/null)"

# ===========================================================================
# 166. Test builtin edge cases
# ===========================================================================
check "test -d dir" "yes" "$(timeout 3 $DEN -c '[ -d /tmp ] && echo yes' 2>/dev/null)"
check "test -e exists" "yes" "$(timeout 3 $DEN -c '[ -e /etc/hosts ] && echo yes' 2>/dev/null)"
check "test -r readable" "yes" "$(timeout 3 $DEN -c '[ -r /etc/shells ] && echo yes' 2>/dev/null)"
check "test -w writable" "yes" "$(timeout 3 $DEN -c '[ -w /tmp ] && echo yes' 2>/dev/null)"
check "test -x executable" "yes" "$(timeout 3 $DEN -c '[ -x /bin/sh ] && echo yes' 2>/dev/null)"
check "test ! neg" "yes" "$(timeout 3 $DEN -c '[ ! -f /nonexistent_file ] && echo yes' 2>/dev/null)"
check "test -a and" "yes" "$(timeout 3 $DEN -c '[ -d /tmp -a -f /etc/shells ] && echo yes' 2>/dev/null)"
check "test -o or" "yes" "$(timeout 3 $DEN -c '[ -f /nonexistent -o -d /tmp ] && echo yes' 2>/dev/null)"
check "test num eq" "yes" "$(timeout 3 $DEN -c '[ 5 -eq 5 ] && echo yes' 2>/dev/null)"
check "test num ne" "yes" "$(timeout 3 $DEN -c '[ 5 -ne 3 ] && echo yes' 2>/dev/null)"
check "test num le" "yes" "$(timeout 3 $DEN -c '[ 3 -le 5 ] && echo yes' 2>/dev/null)"
check "test num ge" "yes" "$(timeout 3 $DEN -c '[ 5 -ge 3 ] && echo yes' 2>/dev/null)"
check "test str !=" "yes" "$(timeout 3 $DEN -c '[ "abc" != "def" ] && echo yes' 2>/dev/null)"

# ===========================================================================
# 167. [[ ]] advanced tests
# ===========================================================================
check "[[ -z empty ]]" "yes" "$(timeout 3 $DEN -c '[[ -z "" ]] && echo yes' 2>/dev/null)"
check "[[ -n notempty ]]" "yes" "$(timeout 3 $DEN -c '[[ -n "hello" ]] && echo yes' 2>/dev/null)"
check "[[ && ]]" "yes" "$(timeout 3 $DEN -c '[[ 1 -eq 1 && 2 -eq 2 ]] && echo yes' 2>/dev/null)"
check "[[ || ]]" "yes" "$(timeout 3 $DEN -c '[[ 1 -eq 2 || 2 -eq 2 ]] && echo yes' 2>/dev/null)"
check "[[ ! ]]" "yes" "$(timeout 3 $DEN -c '[[ ! -f /nonexistent ]] && echo yes' 2>/dev/null)"
check "[[ string < ]]" "yes" "$(timeout 3 $DEN -c '[[ "abc" < "abd" ]] && echo yes' 2>/dev/null)"
check "[[ string > ]]" "yes" "$(timeout 3 $DEN -c '[[ "abd" > "abc" ]] && echo yes' 2>/dev/null)"
# SKIP: BASH_REMATCH not yet implemented
# check "[[ regex capture ]]" "123" "$(timeout 3 $DEN -c '[[ "abc123def" =~ ([0-9]+) ]] && echo ${BASH_REMATCH[1]}' 2>/dev/null)"

# ===========================================================================
# 168. Semicolon and compound command edge cases
# ===========================================================================
check "semicolon multi" "1 2 3" "$(timeout 3 $DEN -c 'echo 1; echo 2; echo 3' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "semicolon trailing" "ok" "$(timeout 3 $DEN -c 'echo ok;' 2>/dev/null)"
check "semicolon in dquote" "a;b" "$(timeout 3 $DEN -c 'echo "a;b"' 2>/dev/null)"
check "&& chain" "ok" "$(timeout 3 $DEN -c 'true && true && echo ok' 2>/dev/null)"
check "|| chain" "fallback" "$(timeout 3 $DEN -c 'false || false || echo fallback' 2>/dev/null)"
check "&& || combined" "B" "$(timeout 3 $DEN -c 'false && echo A || echo B' 2>/dev/null)"
check "grouped &&" "ok" "$(timeout 3 $DEN -c '{ true && echo ok; }' 2>/dev/null)"

# ===========================================================================
# 169. Trap edge cases
# ===========================================================================
check "trap EXIT from func" "cleanup" "$(timeout 3 $DEN -c 'trap "echo cleanup" EXIT; f() { return 0; }; f' 2>/dev/null)"
check "trap multiple" "before after" "$(timeout 3 $DEN -c 'trap "echo after" EXIT; echo before' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# ===========================================================================
# 170. set options edge cases
# ===========================================================================
check "set -e stops on fail" "before" "$(timeout 3 $DEN -c 'set -e; echo before; false; echo after' 2>/dev/null)"
check "set +e continues" "before after" "$(timeout 3 $DEN -c 'set -e; set +e; echo before; false; echo after' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "set -e func fail" "" "$(timeout 3 $DEN -c 'set -e; f() { return 1; }; f; echo should_not_reach' 2>/dev/null)"

# ===========================================================================
# 171. Glob expansion in command context
# ===========================================================================
check "glob star" "yes" "$(timeout 3 $DEN -c 'ls /etc/hos* > /dev/null 2>&1 && echo yes || echo no' 2>/dev/null)"
check "glob question" "yes" "$(timeout 3 $DEN -c 'ls /etc/host? > /dev/null 2>&1 && echo yes || echo no' 2>/dev/null)"
check "glob no match quoted" "*nonexist*" "$(timeout 3 $DEN -c 'echo "*nonexist*"' 2>/dev/null)"

# ===========================================================================
# 172. ANSI-C quoting
# ===========================================================================
check "ansi-c tab" "a	b" "$(timeout 3 $DEN -c "echo \$'a\tb'" 2>/dev/null)"
check "ansi-c newline" "a
b" "$(timeout 3 $DEN -c "echo \$'a\nb'" 2>/dev/null)"
check "ansi-c backslash" 'a\b' "$(timeout 3 $DEN -c "echo \$'a\\\\b'" 2>/dev/null)"
check "ansi-c squote" "a'b" "$(timeout 3 $DEN -c "echo \$'a\\'b'" 2>/dev/null)"

# ===========================================================================
# 173. Declare and readonly edge cases
# ===========================================================================
check "readonly prevents" "1" "$(timeout 3 $DEN -c 'readonly x=5; x=10; echo $?' 2>/dev/null)"
check "declare -r same" "5" "$(timeout 3 $DEN -c 'declare -r x=5; echo $x' 2>/dev/null)"
check "declare no val" "" "$(timeout 3 $DEN -c 'declare x; echo -n "$x"' 2>/dev/null)"

# ===========================================================================
# 174. Script execution edge cases (using temp files)
# ===========================================================================
check "script for loop" "a b c" "$(echo 'for i in a b c; do echo $i; done' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; rm -f /tmp/den_t_script.sh)"
check "script if oneliner" "yes" "$(echo 'if true; then echo yes; fi' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null; rm -f /tmp/den_t_script.sh)"
check "script while oneliner" "0 1 2" "$(echo 'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; rm -f /tmp/den_t_script.sh)"
check "script func def+call" "hello" "$(printf 'greet() {\n  echo hello\n}\ngreet\n' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null; rm -f /tmp/den_t_script.sh)"
check "script multi cmds" "1 2 3" "$(echo 'echo 1; echo 2; echo 3' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; rm -f /tmp/den_t_script.sh)"
check "script tilde quoted" "~" "$(echo 'echo "~"' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null; rm -f /tmp/den_t_script.sh)"
check "script tilde unquoted" "$HOME" "$(echo 'echo ~' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null; rm -f /tmp/den_t_script.sh)"
check "script var persist" "after" "$(printf 'x=before\nx=after\necho $x\n' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null; rm -f /tmp/den_t_script.sh)"
check "script exit code" "42" "$(echo 'exit 42' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null; echo $?; rm -f /tmp/den_t_script.sh)"
check "script nested if" "b" "$(printf 'x=5\nif [ $x -gt 10 ]; then\n  echo a\nelif [ $x -gt 3 ]; then\n  echo b\nelse\n  echo c\nfi\n' > /tmp/den_t_script.sh; timeout 3 $DEN /tmp/den_t_script.sh 2>/dev/null; rm -f /tmp/den_t_script.sh)"

# ===========================================================================
# 175. eval edge cases
# ===========================================================================
check "eval simple" "hello" "$(timeout 3 $DEN -c 'eval echo hello' 2>/dev/null)"
check "eval var expand" "world" "$(timeout 3 $DEN -c 'x=world; eval echo \$x' 2>/dev/null)"
check "eval assign" "from_eval" "$(timeout 3 $DEN -c 'eval "x=from_eval"; echo $x' 2>/dev/null)"

# ===========================================================================
# 176. Misc edge cases
# ===========================================================================
check "colon noop" "0" "$(timeout 3 $DEN -c ':; echo $?' 2>/dev/null)"
check "true builtin" "0" "$(timeout 3 $DEN -c 'true; echo $?' 2>/dev/null)"
check "false builtin" "1" "$(timeout 3 $DEN -c 'false; echo $?' 2>/dev/null)"
check "basename equiv" "file.txt" "$(timeout 3 $DEN -c 'x=/path/to/file.txt; echo ${x##*/}' 2>/dev/null)"
check "dirname equiv" "/path/to" "$(timeout 3 $DEN -c 'x=/path/to/file.txt; echo ${x%/*}' 2>/dev/null)"
check "type echo" "echo is a shell builtin" "$(timeout 3 $DEN -c 'type echo' 2>/dev/null)"
check "command -v cat" "$(which cat)" "$(timeout 3 $DEN -c 'command -v cat' 2>/dev/null)"
check "hash command" "0" "$(timeout 3 $DEN -c 'hash ls 2>/dev/null; echo $?' 2>/dev/null)"
check "let arith" "15" "$(timeout 3 $DEN -c 'let x=5+10; echo $x' 2>/dev/null)"
check "pwd builtin" "$(pwd)" "$(timeout 3 $DEN -c 'cd '"$(pwd)"'; pwd' 2>/dev/null)"

# ===========================================================================
# 177. Herestring single-quote fix (REGRESSION: $x expanded in single quotes)
# ===========================================================================
check "herestring squote literal" 'no expand $x' "$(timeout 3 $DEN -c "cat <<< 'no expand \$x'" 2>/dev/null)"
check "herestring dquote expand" "hello world" "$(timeout 3 $DEN -c 'x=world; cat <<< "hello $x"' 2>/dev/null)"
check "herestring unquoted" "hello" "$(timeout 3 $DEN -c 'cat <<< hello' 2>/dev/null)"
check "herestring unquoted var" "test" "$(timeout 3 $DEN -c 'x=test; cat <<< $x' 2>/dev/null)"

# ===========================================================================
# 178. Function name resolution (REGRESSION: short names matched aliases)
# ===========================================================================
check "func shadows alias" "from g" "$(timeout 3 $DEN -c 'g() { echo "from g"; }; g' 2>/dev/null)"
check "func indirect call" "from g" "$(timeout 3 $DEN -c 'g() { echo "from g"; }; f() { g; }; f' 2>/dev/null)"
check "func shadows builtin" "custom echo" "$(timeout 3 $DEN -c 'echo() { command echo "custom echo"; }; echo hello' 2>/dev/null)"

# ===========================================================================
# 179. Eval variable persistence (REGRESSION: eval assignments lost)
# ===========================================================================
check "eval assign persist" "from_eval" "$(timeout 3 $DEN -c 'eval "x=from_eval"; echo $x' 2>/dev/null)"
check "eval compound" "done" "$(timeout 3 $DEN -c 'eval "x=42; echo done"' 2>/dev/null)"
check "eval with expansion" "world" "$(timeout 3 $DEN -c 'x=world; eval echo \$x' 2>/dev/null)"

# ===========================================================================
# 180. Underscore in variable names (REGRESSION: $_x parsed as $_ + x)
# ===========================================================================
check "var underscore prefix" "ok" "$(timeout 3 $DEN -c '_x=ok; echo $_x' 2>/dev/null)"
check "var underscore mid" "ok" "$(timeout 3 $DEN -c 'a_b=ok; echo $a_b' 2>/dev/null)"
check "var double underscore" "ok" "$(timeout 3 $DEN -c '__x=ok; echo $__x' 2>/dev/null)"

# ===========================================================================
# 181. Printf escape sequences in command substitution
# ===========================================================================
check "printf newline in cmdsub" "hello" "$(timeout 3 $DEN -c 'x=$(printf "hello\n"); echo "$x"' 2>/dev/null)"
check "printf multiline cmdsub" "a b" "$(timeout 3 $DEN -c 'x=$(printf "a\nb"); echo $x' 2>/dev/null)"
check "printf tab in cmdsub" "a	b" "$(timeout 3 $DEN -c 'x=$(printf "a\tb"); echo "$x"' 2>/dev/null)"

# ===========================================================================
# 182. Negative array indexing
# ===========================================================================
check "arr neg last" "c" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[-1]}' 2>/dev/null)"
check "arr neg second" "b" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[-2]}' 2>/dev/null)"
check "arr neg first" "a" "$(timeout 3 $DEN -c 'arr=(a b c); echo ${arr[-3]}' 2>/dev/null)"

# ===========================================================================
# 183. Quoted array elements
# ===========================================================================
check "arr quoted space elem" "hello world" "$(timeout 3 $DEN -c 'arr=("hello world" "foo"); echo ${arr[0]}' 2>/dev/null)"
check "arr quoted count" "2" "$(timeout 3 $DEN -c 'arr=("hello world" "foo"); echo ${#arr[@]}' 2>/dev/null)"

# ===========================================================================
# 184. IFS and word splitting
# ===========================================================================
check "IFS colon split" "a b c" "$(timeout 3 $DEN -c 'IFS=:; x="a:b:c"; echo $x' 2>/dev/null)"
check "dquote preserves spaces" "a  b  c" "$(timeout 3 $DEN -c 'x="a  b  c"; echo "$x"' 2>/dev/null)"
check "unquote collapses spaces" "a b c" "$(timeout 3 $DEN -c 'x="a  b  c"; echo $x' 2>/dev/null)"

# ===========================================================================
# 185. Substring expansion
# ===========================================================================
check "substr offset" "llo" "$(timeout 3 $DEN -c 'x=hello; echo ${x:2}' 2>/dev/null)"
check "substr offset len" "ell" "$(timeout 3 $DEN -c 'x=hello; echo ${x:1:3}' 2>/dev/null)"

# ===========================================================================
# 186. Arithmetic with variables (no $ prefix)
# ===========================================================================
check "arith var no dollar" "5" "$(timeout 3 $DEN -c 'x=5; echo $(( x ))' 2>/dev/null)"
check "arith var add" "8" "$(timeout 3 $DEN -c 'x=5; echo $(( x + 3 ))' 2>/dev/null)"
check "arith ternary true" "10" "$(timeout 3 $DEN -c 'echo $(( 1 ? 10 : 20 ))' 2>/dev/null)"
check "arith ternary false" "20" "$(timeout 3 $DEN -c 'echo $(( 0 ? 10 : 20 ))' 2>/dev/null)"
check "arith base 16" "255" "$(timeout 3 $DEN -c 'echo $(( 16#ff ))' 2>/dev/null)"

# ===========================================================================
# 187. Complex pipeline patterns
# ===========================================================================
check "pipe tr uppercase" "HELLO" "$(timeout 3 $DEN -c 'echo hello | tr a-z A-Z' 2>/dev/null)"
check "pipe sort" "1 2 3" "$(timeout 5 $DEN -c 'printf "3\n1\n2\n" | sort' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "pipe wc" "6" "$(timeout 3 $DEN -c 'echo hello | wc -c' 2>/dev/null | tr -d ' ')"

# ===========================================================================
# 188. While read loop pattern
# ===========================================================================
check "while read lines" "line: a line: b line: c" "$(timeout 3 $DEN -c 'printf "a\nb\nc\n" | while read line; do echo "line: $line"; done' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "while IFS read" "1 2 3" "$(timeout 3 $DEN -c 'echo "1:2:3" | while IFS=: read a b c; do echo "$a $b $c"; done' 2>/dev/null)"

# ===========================================================================
# 189. Conditional chains
# ===========================================================================
check "and chain both" "A B" "$(timeout 3 $DEN -c 'true && echo A && echo B' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "and-or combined" "B" "$(timeout 3 $DEN -c 'false && echo A || echo B' 2>/dev/null)"
check "or chain fallthrough" "C" "$(timeout 3 $DEN -c 'false || false || echo C' 2>/dev/null)"
check "complex chain" "B" "$(timeout 3 $DEN -c 'true && false && echo A || echo B' 2>/dev/null)"

# ===========================================================================
# 190. Function features
# ===========================================================================
check "func with args" "hello world" "$(timeout 3 $DEN -c 'f() { echo "$1 $2"; }; f hello world' 2>/dev/null)"
check "func return 42" "42" "$(timeout 3 $DEN -c 'f() { return 42; }; f; echo $?' 2>/dev/null)"
check "func shift" "b" "$(timeout 3 $DEN -c 'f() { shift; echo $1; }; f a b c' 2>/dev/null)"
check "func nested call" "from g" "$(timeout 3 $DEN -c 'g() { echo "from g"; }; f() { g; }; f' 2>/dev/null)"

# ===========================================================================
# 191. Variable scoping
# ===========================================================================
check "subshell var isolate" "1" "$(timeout 3 $DEN -c 'x=1; (x=2); echo $x' 2>/dev/null)"
check "brace group var" "2" "$(timeout 3 $DEN -c 'x=1; { x=2; }; echo $x' 2>/dev/null)"
check "local var scoping" "outer" "$(timeout 3 $DEN -c 'f() { local x=inner; }; x=outer; f; echo $x' 2>/dev/null)"

# ===========================================================================
# 192. Glob patterns
# ===========================================================================
check "glob no match literal" "*nonexist*" "$(timeout 3 $DEN -c 'echo *nonexist*' 2>/dev/null)"
check "glob quoted no expand" "/etc/hos*" "$(timeout 3 $DEN -c 'echo "/etc/hos*"' 2>/dev/null)"

# ===========================================================================
# 193. Error handling patterns
# ===========================================================================
check "not found exit 127" "127" "$(timeout 3 $DEN -c 'cmd_not_found_xyz 2>/dev/null; echo $?' 2>/dev/null)"
check "subshell exit code" "42" "$(timeout 3 $DEN -c '(exit 42); echo $?' 2>/dev/null)"
check "negation true" "1" "$(timeout 3 $DEN -c '! true; echo $?' 2>/dev/null)"
check "negation false" "0" "$(timeout 3 $DEN -c '! false; echo $?' 2>/dev/null)"

# ===========================================================================
# 194. Heredoc variations
# ===========================================================================
check "heredoc no expand squote" 'hello $HOME' "$(timeout 3 $DEN -c "cat <<'EOF'
hello \$HOME
EOF" 2>/dev/null)"
check "heredoc expand dquote" "hello $HOME" "$(timeout 3 $DEN -c 'x=$HOME; cat <<EOF
hello $x
EOF' 2>/dev/null)"

# ===========================================================================
# 195. read builtin features
# ===========================================================================
check "read from pipe" "got: foo" "$(timeout 3 $DEN -c 'echo foo | { read x; echo "got: $x"; }' 2>/dev/null)"
check "read -r no backslash" 'hello\tworld' "$(timeout 3 $DEN -c 'read -r x <<< "hello\tworld"; echo "$x"' 2>/dev/null)"

# ===========================================================================
# 196. Parameter expansion: colon in patterns, slash in defaults
# ===========================================================================
check "suffix strip colon glob" "abc" "$(timeout 3 $DEN -c 'x="abc:def"; echo "${x%%:*}"' 2>/dev/null)"
check "suffix strip colon single" "a:b" "$(timeout 3 $DEN -c 'x="a:b:c"; echo "${x%:*}"' 2>/dev/null)"
check "PATH first component" "/usr/bin" "$(timeout 3 $DEN -c 'PATH="/usr/bin:/usr/local/bin"; echo "${PATH%%:*}"' 2>/dev/null)"
check "default with slash" "/etc/default" "$(timeout 3 $DEN -c 'echo ${C:-/etc/default}' 2>/dev/null)"
check "assign default slash" "/etc/default" "$(timeout 3 $DEN -c ': ${CONFIG:=/etc/default}; echo $CONFIG' 2>/dev/null)"

# ===========================================================================
# 197. Function positional params on re-call
# ===========================================================================
check "func args second call" "Hello, User" "$(timeout 3 $DEN -c 'greet() { echo "Hello, ${1:-World}"; }; greet; greet "User"' 2>/dev/null | tail -1)"
check "func args change" "c d" "$(timeout 3 $DEN -c 'f() { echo "$1 $2"; }; f a b; f c d' 2>/dev/null | tail -1)"

# ===========================================================================
# 198. Unset arrays
# ===========================================================================
check "unset indexed arr" "0" "$(timeout 3 $DEN -c 'arr=(1 2 3); unset arr; echo ${#arr[@]}' 2>/dev/null)"
check "unset assoc arr" "0" "$(timeout 3 $DEN -c 'declare -A m=([a]=1 [b]=2); unset m; echo ${#m[@]}' 2>/dev/null)"

# ===========================================================================
# 199. Associative array variable subscript
# ===========================================================================
check "assoc var subscript" "value" "$(timeout 3 $DEN -c 'declare -A m=([key]=value); k=key; echo "${m[$k]}"' 2>/dev/null)"
check "assoc var subscript 2" "1" "$(timeout 3 $DEN -c 'declare -A m=([a]=1 [b]=2); x=a; echo "${m[$x]}"' 2>/dev/null)"

# ===========================================================================
# 200. Double backslash in double quotes
# ===========================================================================
check "dquote double backslash" 'hello\world' "$(timeout 3 $DEN -c 'x="hello\\world"; echo "$x"' 2>/dev/null)"

# ===========================================================================
# 201. Multi-variable assignment
# ===========================================================================
check "multi assign simple" "1 2 3" "$(timeout 3 $DEN -c 'x=1 y=2 z=3; echo "$x $y $z"' 2>/dev/null)"
check "multi assign crossref" "hello world" "$(timeout 3 $DEN -c 'x=hello y="$x world"; echo "$y"' 2>/dev/null)"

# ===========================================================================
# 202. Bare redirect creates file
# ===========================================================================
check "bare redirect create" "exists" "$(timeout 3 $DEN -c '> /tmp/den_bare_t.txt; [ -f /tmp/den_bare_t.txt ] && echo exists; rm -f /tmp/den_bare_t.txt' 2>/dev/null)"

# ===========================================================================
# 203. Case character class patterns
# ===========================================================================
check "case char class digit" "digit" "$(timeout 3 $DEN -c 'case 5 in [0-9]) echo digit;; *) echo other;; esac' 2>/dev/null)"
check "case char class lower" "lower" "$(timeout 3 $DEN -c 'case a in [a-z]) echo lower;; *) echo other;; esac' 2>/dev/null)"
check "case char class upper" "upper" "$(timeout 3 $DEN -c 'case A in [A-Z]) echo upper;; *) echo other;; esac' 2>/dev/null)"

# ===========================================================================
# 204. Arithmetic compound assignments
# ===========================================================================
check "arith +=" "15" "$(timeout 3 $DEN -c 'x=10; echo $((x += 5))' 2>/dev/null)"
check "arith -=" "7" "$(timeout 3 $DEN -c 'x=10; echo $((x -= 3))' 2>/dev/null)"
check "arith *=" "20" "$(timeout 3 $DEN -c 'x=4; echo $((x *= 5))' 2>/dev/null)"
check "arith /=" "3" "$(timeout 3 $DEN -c 'x=12; echo $((x /= 4))' 2>/dev/null)"
check "arith %=" "1" "$(timeout 3 $DEN -c 'x=10; echo $((x %= 3))' 2>/dev/null)"
check "arith <<=" "16" "$(timeout 3 $DEN -c 'x=4; echo $((x <<= 2))' 2>/dev/null)"
check "arith >>=" "2" "$(timeout 3 $DEN -c 'x=8; echo $((x >>= 2))' 2>/dev/null)"
check "arith &=" "2" "$(timeout 3 $DEN -c 'x=6; echo $((x &= 3))' 2>/dev/null)"
check "arith |=" "7" "$(timeout 3 $DEN -c 'x=5; echo $((x |= 3))' 2>/dev/null)"
check "arith ^=" "6" "$(timeout 3 $DEN -c 'x=5; echo $((x ^= 3))' 2>/dev/null)"
check "arith += persists" "15" "$(timeout 3 $DEN -c 'x=10; : $((x += 5)); echo $x' 2>/dev/null)"

# ===========================================================================
# 205. C-style for loop with compound assignments
# ===========================================================================
check "cfor +=" "0 2 4 6 8" "$(timeout 3 $DEN -c 'for ((i=0; i<10; i+=2)); do printf "%s " $i; done; echo' 2>/dev/null | tr -s ' ' | sed 's/ $//')"
check "cfor -=" "10 8 6 4 2" "$(timeout 3 $DEN -c 'for ((i=10; i>0; i-=2)); do printf "%s " $i; done; echo' 2>/dev/null | tr -s ' ' | sed 's/ $//')"
check "cfor *=" "1 2 4 8" "$(timeout 3 $DEN -c 'for ((i=1; i<10; i*=2)); do printf "%s " $i; done; echo' 2>/dev/null | tr -s ' ' | sed 's/ $//')"

# ===========================================================================
# 206. IFS array join with ${arr[*]}
# ===========================================================================
check "ifs array join comma" "a,b,c" "$(timeout 3 $DEN -c 'arr=(a b c); IFS=,; echo "${arr[*]}"' 2>/dev/null)"
check "ifs array join pipe" "a|b|c" "$(timeout 3 $DEN -c 'arr=(a b c); IFS="|"; echo "${arr[*]}"' 2>/dev/null)"
check "ifs array join dash" "1-2-3" "$(timeout 3 $DEN -c 'arr=(1 2 3); IFS=-; echo "${arr[*]}"' 2>/dev/null)"

# ===========================================================================
# 207. Read builtin IFS whitespace trimming
# ===========================================================================
check "read trims leading space" "hello" "$(echo '  hello  ' | timeout 3 $DEN -c 'read x; echo "$x"' 2>/dev/null)"
check "read trims tab" "hello" "$(printf '\thello\t' | timeout 3 $DEN -c 'read x; echo "$x"' 2>/dev/null)"

# ===========================================================================
# 208. Test -L symlink detection
# ===========================================================================
check "test -L symlink" "yes" "$(timeout 3 $DEN -c 'ln -sf /dev/null /tmp/den_link_t; [ -L /tmp/den_link_t ] && echo yes; rm -f /tmp/den_link_t' 2>/dev/null)"
check "test -L regular" "no" "$(timeout 3 $DEN -c 'touch /tmp/den_reg_t; [ -L /tmp/den_reg_t ] && echo yes || echo no; rm -f /tmp/den_reg_t' 2>/dev/null)"

# ===========================================================================
# 209. set -e with || guard
# ===========================================================================
check "set -e or guard" "alive" "$(timeout 3 $DEN -c 'set -e; false || true; echo alive' 2>/dev/null)"
check "set -e and guard" "alive" "$(timeout 3 $DEN -c 'set -e; true && false; echo alive' 2>/dev/null)"
check "set -e kills unguarded" "" "$(timeout 3 $DEN -c 'set -e; false; echo dead' 2>/dev/null)"

# ===========================================================================
# 210. Suffix removal with comma in pattern
# ===========================================================================
check "suffix strip comma" "hello" "$(timeout 3 $DEN -c 'x="hello,world"; echo "${x%,*}"' 2>/dev/null)"
check "suffix strip comma glob" "hello" "$(timeout 3 $DEN -c 'x="hello,one,two"; echo "${x%%,*}"' 2>/dev/null)"

# ===========================================================================
# 211. pushd/popd directory changes
# ===========================================================================
check "pushd changes dir" "yes" "$(timeout 3 $DEN -c 'pushd /tmp >/dev/null 2>&1; case "$(pwd)" in *tmp) echo yes;; *) echo no;; esac' 2>/dev/null)"
check "popd restores dir" "yes" "$(timeout 3 $DEN -c 'ORIG=$(pwd); pushd /tmp >/dev/null 2>&1; popd >/dev/null 2>&1; [ "$(pwd)" = "$ORIG" ] && echo yes' 2>/dev/null)"

# ===========================================================================
# 212. Select statement outputs menu to stderr
# ===========================================================================
check "select menu stderr" "a" "$(echo 1 | timeout 3 $DEN -c 'select x in a b c; do echo "$x"; break; done' 2>/dev/null)"

# ===========================================================================
# 213. Function call with redirections
# ===========================================================================
check "func redir output" "hello" "$(timeout 3 $DEN -c 'f() { echo hello; }; f > /tmp/den_fr_t.txt; cat /tmp/den_fr_t.txt; rm -f /tmp/den_fr_t.txt' 2>/dev/null)"
check "func redir stderr" "err" "$(timeout 3 $DEN -c 'f() { echo err >&2; }; f 2>/tmp/den_fre_t.txt; cat /tmp/den_fre_t.txt; rm -f /tmp/den_fre_t.txt' 2>/dev/null)"

# ===========================================================================
# 214. Pre/post increment/decrement in arithmetic
# ===========================================================================
check "arith pre-increment" "11" "$(timeout 3 $DEN -c 'x=10; echo $((++x))' 2>/dev/null)"
check "arith post-increment" "10" "$(timeout 3 $DEN -c 'x=10; echo $((x++))' 2>/dev/null)"
check "arith post-incr persists" "11" "$(timeout 3 $DEN -c 'x=10; : $((x++)); echo $x' 2>/dev/null)"
check "arith pre-decrement" "9" "$(timeout 3 $DEN -c 'x=10; echo $((--x))' 2>/dev/null)"
check "arith post-decrement" "10" "$(timeout 3 $DEN -c 'x=10; echo $((x--))' 2>/dev/null)"

# ===========================================================================
# 215. Arithmetic ternary operator
# ===========================================================================
check "arith ternary true" "1" "$(timeout 3 $DEN -c 'echo $((1 ? 1 : 0))' 2>/dev/null)"
check "arith ternary false" "0" "$(timeout 3 $DEN -c 'echo $((0 ? 1 : 0))' 2>/dev/null)"
check "arith ternary expr" "yes" "$(timeout 3 $DEN -c 'x=5; r=$((x > 3 ? 1 : 0)); [ $r -eq 1 ] && echo yes' 2>/dev/null)"

# ===========================================================================
# 216. Nested arithmetic expressions
# ===========================================================================
check "arith nested parens" "14" "$(timeout 3 $DEN -c 'echo $(( (2 + 5) * 2 ))' 2>/dev/null)"
check "arith complex expr" "7" "$(timeout 3 $DEN -c 'x=3; y=4; echo $((x*x + y - x*y/2))' 2>/dev/null)"

# ===========================================================================
# 217. Multiple redirections on single command
# ===========================================================================
check "multi redir out+err" "out:err" "$(timeout 3 $DEN -c 'echo out > /tmp/den_mr1.txt; echo err > /tmp/den_mr2.txt; echo "$(cat /tmp/den_mr1.txt):$(cat /tmp/den_mr2.txt)"; rm -f /tmp/den_mr1.txt /tmp/den_mr2.txt' 2>/dev/null)"

# ===========================================================================
# 218. Here-string with variable expansion
# ===========================================================================
check "herestring var expand" "hello" "$(timeout 3 $DEN -c 'x=hello; read y <<< "$x"; echo "$y"' 2>/dev/null)"
check "herestring literal" "hello world" "$(timeout 3 $DEN -c 'read y <<< "hello world"; echo "$y"' 2>/dev/null)"

# ===========================================================================
# 219. Subshell variable isolation
# ===========================================================================
check "subshell var isolated" "outer" "$(timeout 3 $DEN -c 'x=outer; (x=inner); echo $x' 2>/dev/null)"
check "subshell exit no affect" "alive" "$(timeout 3 $DEN -c '(exit 1); echo alive' 2>/dev/null)"

# ===========================================================================
# 220. While read loop with pipeline
# ===========================================================================
check "while read pipe" "3" "$(printf 'a\nb\nc\n' | timeout 3 $DEN -c 'n=0; while read line; do n=$((n+1)); done; echo $n' 2>/dev/null)"

# ===========================================================================
# 221. [[ ]] operator precedence (&&  binds tighter than ||)
# ===========================================================================
check "[[ ]] && tighter than ||" "0" "$(timeout 3 $DEN -c '[[ -n "a" || -n "b" && -z "c" ]]; echo $?' 2>/dev/null)"
check "[[ ]] or-and chain" "0" "$(timeout 3 $DEN -c '[[ -z "a" || -z "b" && -z "c" || -n "x" ]]; echo $?' 2>/dev/null)"
check "[[ ]] simple and" "1" "$(timeout 3 $DEN -c '[[ -n "x" && -z "x" ]]; echo $?' 2>/dev/null)"
check "[[ ]] simple or" "0" "$(timeout 3 $DEN -c '[[ -z "x" || -n "x" ]]; echo $?' 2>/dev/null)"

# ===========================================================================
# 222. set -exu combined flags
# ===========================================================================
check "set -eu combined" "ok" "$(timeout 3 $DEN -c 'set -eu; x=ok; echo $x' 2>/dev/null)"
check "set -xu nounset" "1" "$(timeout 3 $DEN -c 'set -xu; echo $UNDEFINED_VAR_12345; echo $?' 2>/dev/null)"
check "set +eu disable" "ok" "$(timeout 3 $DEN -c 'set -eu; set +eu; x=ok; echo $x' 2>/dev/null)"

# ===========================================================================
# 223. Command substitution stderr inherits
# ===========================================================================
check "cmd subst stderr" "err" "$(timeout 3 $DEN -c 'x=$(echo err >&2); echo "$x"' 2>&1 | head -1)"

# ===========================================================================
# 224. Exponentiation right-associativity
# ===========================================================================
check "power right-assoc" "512" "$(timeout 3 $DEN -c 'echo $((2**3**2))' 2>/dev/null)"
check "power simple" "8" "$(timeout 3 $DEN -c 'echo $((2**3))' 2>/dev/null)"
check "power chain" "256" "$(timeout 3 $DEN -c 'echo $((2**2**3))' 2>/dev/null)"

# ===========================================================================
# 225. Quoted keywords treated as words
# ===========================================================================
check "quoted while not keyword" "while" "$(timeout 3 $DEN -c 'echo "while"' 2>/dev/null)"
check "quoted if not keyword" "if" "$(timeout 3 $DEN -c 'echo "if"' 2>/dev/null)"
check "single-quoted for" "for" "$(timeout 3 $DEN -c "echo 'for'" 2>/dev/null)"

# ===========================================================================
# 226. Parameter expansion with local vars
# ===========================================================================
check "param expand local default" "fallback" "$(timeout 3 $DEN -c 'f() { local x; echo ${x:-fallback}; }; f' 2>/dev/null)"
check "param expand local set" "hello" "$(timeout 3 $DEN -c 'f() { local x=hello; echo ${x:-fallback}; }; f' 2>/dev/null)"

# ===========================================================================
# 227. C-style for loop arithmetic condition
# ===========================================================================
check "c-for loop sum" "10" "$(timeout 3 $DEN -c 'sum=0; for ((i=1; i<=4; i++)); do sum=$((sum+i)); done; echo $sum' 2>/dev/null)"
check "c-for zero iters" "0" "$(timeout 3 $DEN -c 'n=0; for ((i=10; i<5; i++)); do n=$((n+1)); done; echo $n' 2>/dev/null)"

# ===========================================================================
# 228. done not matched as substring
# ===========================================================================
check "echo undone in loop" "undone" "$(timeout 3 $DEN -c 'for x in a; do echo undone; done' 2>/dev/null)"
check "echo done in quotes" "not done yet" "$(timeout 3 $DEN -c 'for x in a; do echo "not done yet"; done' 2>/dev/null)"

# ===========================================================================
# 229. declare +r readonly protection
# ===========================================================================
check "declare +r blocked" "1" "$(timeout 3 $DEN -c 'declare -r RO=val; declare +r RO 2>/dev/null; echo $?' 2>/dev/null)"
check "readonly preserved" "val" "$(timeout 3 $DEN -c 'declare -r RO=val; declare +r RO 2>/dev/null; echo $RO' 2>/dev/null)"

# ===========================================================================
# 230. $* joins with IFS
# ===========================================================================
check '$* unquoted' "a b c" "$(timeout 3 $DEN -c 'set -- a b c; echo $*' 2>/dev/null)"
check '$* positional params' "x y z" "$(timeout 3 $DEN -c 'set -- x y z; echo $*' 2>/dev/null)"

# ===========================================================================
# 231. ${VAR@Q} single quote escaping
# ===========================================================================
check '${VAR@Q} simple' "'hello'" "$(timeout 3 $DEN -c "x=hello; echo \${x@Q}" 2>/dev/null)"
check '${VAR@Q} with quote' "'it'\\''s'" "$(timeout 3 $DEN -c "x=\"it's\"; echo \${x@Q}" 2>/dev/null)"

# ===========================================================================
# 232. Heredoc delimiter matching
# ===========================================================================
check "heredoc basic" "hello" "$(timeout 3 $DEN -c 'cat <<EOF
hello
EOF' 2>/dev/null)"
check "heredoc strip tabs" "indented" "$(timeout 3 $DEN -c "$(printf 'cat <<-EOF\n\t\tindented\n\tEOF')" 2>/dev/null)"

# ===========================================================================
# 233. declare -i integer attribute
# ===========================================================================
check "declare -i eval" "10" "$(timeout 3 $DEN -c 'declare -i x=5+5; echo $x' 2>/dev/null)"
check "declare -i var" "15" "$(timeout 3 $DEN -c 'declare -i x=10; declare -i y=x+5; echo $y' 2>/dev/null)"

# ===========================================================================
# 234. $RANDOM produces different values
# ===========================================================================
check '$RANDOM is numeric' "0" "$(timeout 3 $DEN -c 'r=$RANDOM; if [ "$r" -ge 0 ] 2>/dev/null && [ "$r" -le 32767 ] 2>/dev/null; then echo 0; else echo 1; fi' 2>/dev/null)"

# ===========================================================================
# 235. Arithmetic short-circuit
# ===========================================================================
check "arith || short-circuit" "1" "$(timeout 3 $DEN -c 'echo $((1 || 0))' 2>/dev/null)"
check "arith && short-circuit" "0" "$(timeout 3 $DEN -c 'echo $((0 && 1))' 2>/dev/null)"
check "arith ternary true" "5" "$(timeout 3 $DEN -c 'echo $((1 ? 5 : 10))' 2>/dev/null)"
check "arith ternary false" "10" "$(timeout 3 $DEN -c 'echo $((0 ? 5 : 10))' 2>/dev/null)"

# ===========================================================================
# 236. (( x++ )) with valid names only
# ===========================================================================
check "(( x++ ))" "6" "$(timeout 3 $DEN -c 'x=5; (( x++ )); echo $x' 2>/dev/null)"
check "(( ++x ))" "6" "$(timeout 3 $DEN -c 'x=5; (( ++x )); echo $x' 2>/dev/null)"
check "(( x-- ))" "4" "$(timeout 3 $DEN -c 'x=5; (( x-- )); echo $x' 2>/dev/null)"

# ===========================================================================
# 237. readonly cannot be unset
# ===========================================================================
check "readonly reassign blocked" "1" "$(timeout 3 $DEN -c 'readonly RO=val; readonly RO=new 2>/dev/null; echo $?' 2>/dev/null)"
check "readonly value preserved" "val" "$(timeout 3 $DEN -c 'readonly RO=val; readonly RO=new 2>/dev/null; echo $RO' 2>/dev/null)"

# ===========================================================================
# 238. printf hex/octal input
# ===========================================================================
check "printf hex input" "255" "$(timeout 3 $DEN -c 'printf "%d" 0xff' 2>/dev/null)"
check "printf octal input" "8" "$(timeout 3 $DEN -c 'printf "%d" 010' 2>/dev/null)"

# ===========================================================================
# 239. read with custom IFS
# ===========================================================================
check "read splits on IFS" "usr" "$(echo 'usr:x:1000' | timeout 3 $DEN -c 'IFS=:; read a b rest; echo $a' 2>/dev/null)"

# ===========================================================================
# 240. ${#VAR} with local variables
# ===========================================================================
check '${#local_var}' "5" "$(timeout 3 $DEN -c 'f() { local x=hello; echo ${#x}; }; f' 2>/dev/null)"

# ===========================================================================
# 241. ${VAR:offset} with local variables
# ===========================================================================
check '${local:2}' "llo" "$(timeout 3 $DEN -c 'f() { local x=hello; echo ${x:2}; }; f' 2>/dev/null)"
check '${local:1:3}' "ell" "$(timeout 3 $DEN -c 'f() { local x=hello; echo ${x:1:3}; }; f' 2>/dev/null)"

# ===========================================================================
# 242. %N job spec syntax
# ===========================================================================
check "fg %invalid" "1" "$(timeout 3 $DEN -c 'fg %999 2>/dev/null; echo $?' 2>/dev/null)"

# ===========================================================================
# 243. C-style for break in loop
# ===========================================================================
check "c-for break" "done" "$(timeout 3 $DEN -c 'for i in 1 2 3; do if [ $i -eq 2 ]; then break; fi; done; echo done' 2>/dev/null)"

# ===========================================================================
# 244. ${*} braced with IFS
# ===========================================================================
check '${*} unquoted' "a b c" "$(timeout 3 $DEN -c 'set -- a b c; echo ${*}' 2>/dev/null)"

# ===========================================================================
# 245. hash -r clears cache
# ===========================================================================
check "hash -r runs" "0" "$(timeout 3 $DEN -c 'hash -r 2>/dev/null; echo $?' 2>/dev/null)"

# ===========================================================================
# 246. test -nt/-ot/-ef file tests
# ===========================================================================
check "test -ef same file" "0" "$(timeout 3 $DEN -c '[ /etc/hosts -ef /etc/hosts ]; echo $?' 2>/dev/null)"
check "test -nt nonexist" "0" "$(timeout 3 $DEN -c '[ /etc/hosts -nt /nonexistent_file_xyz ]; echo $?' 2>/dev/null)"

# ===========================================================================
# 247. unset readonly blocked
# ===========================================================================
check "unset readonly var" "1" "$(timeout 3 $DEN -c 'declare -r ROVAR=x; unset ROVAR 2>/dev/null; echo $?' 2>/dev/null)"
check "unset readonly preserved" "x" "$(timeout 3 $DEN -c 'declare -r ROVAR=x; unset ROVAR 2>/dev/null; echo $ROVAR' 2>/dev/null)"

# ===========================================================================
# 248. export -n keeps value
# ===========================================================================
check "export -n keeps var" "bar" "$(timeout 3 $DEN -c 'export FOO=bar; export -n FOO; echo $FOO' 2>/dev/null)"

# ===========================================================================
# 249. echo -e single hex digit
# ===========================================================================
check "echo -e hex 2 digits" "A" "$(timeout 3 $DEN -c 'echo -e "\x41"' 2>/dev/null)"
check "echo -e hex 1 digit" "	" "$(timeout 3 $DEN -c 'echo -e "\x9"' 2>/dev/null)"

# ===========================================================================
# 250. let wrapping arithmetic
# ===========================================================================
check "let basic" "15" "$(timeout 3 $DEN -c 'x=10; let x=x+5; echo $x' 2>/dev/null)"
check "let multiply" "50" "$(timeout 3 $DEN -c 'x=10; let x=x*5; echo $x' 2>/dev/null)"

# ===========================================================================
# 251. popd/pushd bounds check
# ===========================================================================
check "popd no stack" "1" "$(timeout 3 $DEN -c 'popd 2>/dev/null; echo $?' 2>/dev/null)"

# ===========================================================================
# 252. Arithmetic precedence in loops
# ===========================================================================
check "arith precedence" "14" "$(timeout 3 $DEN -c 'echo $((2+3*4))' 2>/dev/null)"

# ===========================================================================
# 253. ${var:-"with}braces"} brace scan respects quotes
# ===========================================================================
check 'brace in default quotes' "ab}" "$(timeout 3 $DEN -c 'echo ${UNDEF_VAR:-a\}b}' 2>/dev/null)"
check 'default value basic' "default" "$(timeout 3 $DEN -c 'echo ${UNDEF_VAR:-default}' 2>/dev/null)"

# ===========================================================================
# 245. $- option flags
# ===========================================================================
check '$- returns u' "u" "$(timeout 3 $DEN -c 'set -u; echo $-' 2>/dev/null)"

# ===========================================================================
# 246. Arithmetic assignment operators
# ===========================================================================
check 'arith +=' "15" "$(timeout 3 $DEN -c 'x=10; (( x += 5 )); echo $x' 2>/dev/null)"
check 'arith -=' "5" "$(timeout 3 $DEN -c 'x=10; (( x -= 5 )); echo $x' 2>/dev/null)"
check 'arith *=' "50" "$(timeout 3 $DEN -c 'x=10; (( x *= 5 )); echo $x' 2>/dev/null)"

# ===========================================================================
# 247. Parameter expansion case operators with local
# ===========================================================================
check '${local^^}' "HELLO" "$(timeout 3 $DEN -c 'f() { local x=hello; echo ${x^^}; }; f' 2>/dev/null)"
check '${local,,}' "hello" "$(timeout 3 $DEN -c 'f() { local x=HELLO; echo ${x,,}; }; f' 2>/dev/null)"

# ===========================================================================
# 248. Parameter expansion pattern with local
# ===========================================================================
check '${local#pattern}' "world" "$(timeout 3 $DEN -c 'f() { local x="hello_world"; echo ${x#hello_}; }; f' 2>/dev/null)"
check '${local%pattern}' "hello" "$(timeout 3 $DEN -c 'f() { local x="hello_world"; echo ${x%_world}; }; f' 2>/dev/null)"

# ===========================================================================
# 249. printf format specifiers
# ===========================================================================
check 'printf %x' "ff" "$(timeout 3 $DEN -c 'printf "%x" 255' 2>/dev/null)"
check 'printf %o' "10" "$(timeout 3 $DEN -c 'printf "%o" 8' 2>/dev/null)"
check 'printf %s' "hello" "$(timeout 3 $DEN -c 'printf "%s" hello' 2>/dev/null)"

# ===========================================================================
# 250. read -a with IFS
# ===========================================================================
check "read -a basic" "b" "$(echo 'a b c' | timeout 3 $DEN -c 'read -a arr; echo ${arr[1]}' 2>/dev/null)"

# ===========================================================================
# 251. Nested command substitution
# ===========================================================================
check "nested cmd subst" "HELLO" "$(timeout 3 $DEN -c 'echo $(echo $(echo HELLO))' 2>/dev/null)"
check "cmd subst in arith" "10" "$(timeout 3 $DEN -c 'echo $(( $(echo 5) + $(echo 5) ))' 2>/dev/null)"

# ===========================================================================
# 252. printf %b octal escapes (\0NNN)
# ===========================================================================
check 'printf %b \0101=A' "A" "$(timeout 3 $DEN -c "printf '%b' '\0101'" 2>/dev/null)"
check 'printf %b \0110=H' "H" "$(timeout 3 $DEN -c "printf '%b' '\0110'" 2>/dev/null)"

# ===========================================================================
# 253. printf %b hex escapes (\xHH)
# ===========================================================================
check 'printf %b \x41=A' "A" "$(timeout 3 $DEN -c "printf '%b' '\x41'" 2>/dev/null)"
check 'printf %b \x48=H' "H" "$(timeout 3 $DEN -c "printf '%b' '\x48'" 2>/dev/null)"

# ===========================================================================
# 254. printf %b \c stops output
# ===========================================================================
check 'printf %b \c stops' "hello" "$(timeout 3 $DEN -c "printf '%b' 'hello\cworld'" 2>/dev/null)"

# ===========================================================================
# 255. printf format \x with single hex digit
# ===========================================================================
check 'printf \xA single hex' "$(printf 'a\nz')" "$(timeout 3 $DEN -c "printf 'a\xAz'" 2>/dev/null)"
check 'printf \x41=A' "A" "$(timeout 3 $DEN -c "printf '\x41'" 2>/dev/null)"

# ===========================================================================
# 256. echo -e Unicode escapes
# ===========================================================================
check 'echo -e \u0041=A' "A" "$(timeout 3 $DEN -c 'echo -e "\u0041"' 2>/dev/null)"
check 'echo -e \u00e9=e-acute' "$(printf '\xc3\xa9')" "$(timeout 3 $DEN -c 'echo -e "\u00e9"' 2>/dev/null)"

# ===========================================================================
# 257. read -d empty string = NUL delimiter
# ===========================================================================
check 'read -d "" basic' "hello" "$(printf 'hello\0world' | timeout 3 $DEN -c "read -d '' var; echo \$var" 2>/dev/null)"

# ===========================================================================
# 258. Arithmetic overflow-checked increment
# ===========================================================================
check 'arith normal increment' "6" "$(timeout 3 $DEN -c 'x=5; echo $((++x))' 2>/dev/null)"
check 'arith normal decrement' "4" "$(timeout 3 $DEN -c 'x=5; echo $((--x))' 2>/dev/null)"

# ===========================================================================
# 259. ${!VAR} indirect expansion with local vars
# ===========================================================================
check '${!VAR} basic' "world" "$(timeout 3 $DEN -c 'target=world; ref=target; echo ${!ref}' 2>/dev/null)"

# ===========================================================================
# 260. trap - SIGNAL resets to default
# ===========================================================================
check 'trap - removes handler' "" "$(timeout 3 $DEN -c 'trap "echo trapped" USR1; trap - USR1; trap -p USR1' 2>/dev/null)"

# ===========================================================================
# 261. umask -S symbolic display
# ===========================================================================
check 'umask octal' "0022" "$(timeout 3 $DEN -c 'umask 0022; umask' 2>/dev/null)"
check 'umask -S display' "u=rwx,g=r-x,o=r-x" "$(timeout 3 $DEN -c 'umask 0022; umask -S' 2>/dev/null)"

# ===========================================================================
# 262. umask symbolic mode set
# ===========================================================================
check 'umask symbolic u=rwx,g=rx,o=rx' "0022" "$(timeout 3 $DEN -c 'umask u=rwx,g=rx,o=rx; umask' 2>/dev/null)"

# ===========================================================================
# 263. source multi-line constructs
# ===========================================================================
printf 'if true; then\necho yes\nfi\n' > /tmp/den_test_source_ml.sh
check 'source if/then/fi' "yes" "$(timeout 3 $DEN -c 'source /tmp/den_test_source_ml.sh' 2>/dev/null)"
rm -f /tmp/den_test_source_ml.sh
printf 'myfn() {\necho hello\n}\n' > /tmp/den_test_source_fn.sh
check 'source function def' "hello" "$(timeout 3 $DEN -c 'source /tmp/den_test_source_fn.sh; myfn' 2>/dev/null)"
rm -f /tmp/den_test_source_fn.sh

# ===========================================================================
# 264. exec with redirections (no args)
# ===========================================================================
check 'exec >file redirect' "hello" "$(timeout 3 $DEN -c 'exec > /tmp/den_test_exec_redir.txt; echo hello; exec > /dev/stdout; cat /tmp/den_test_exec_redir.txt; rm /tmp/den_test_exec_redir.txt' 2>/dev/null)"

# ===========================================================================
# 265. Array assignment key leak fix (functional test)
# ===========================================================================
check 'array reassign' "new" "$(timeout 3 $DEN -c 'arr=(old); arr=(new); echo ${arr[0]}' 2>/dev/null)"
check 'array reassign multi' "c" "$(timeout 3 $DEN -c 'arr=(a b); arr=(c d e); echo ${arr[0]}' 2>/dev/null)"

# Results
# ===========================================================================
echo ""
if [ $FAIL -gt 0 ]; then
    echo -e "$FAILURES"
fi
TOTAL=$((PASS+FAIL))
echo "Results: $PASS / $TOTAL passed ($SKIP skipped)"
if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED!"
    exit 0
else
    echo "$FAIL test(s) failed"
    exit 1
fi
