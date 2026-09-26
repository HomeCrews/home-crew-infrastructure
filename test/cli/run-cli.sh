#!/bin/sh
# Suite B (cli), the ./dev half: runs ./dev through every scenario in
# test/cli/scenarios.tsv against a fake docker, each in a fresh throwaway
# sandbox, and with --check compares every transcript with the table.
#
#   sh test/cli/run-cli.sh [--check] [--shell PATH] [--out DIR] [--script PATH]
#                          [--impl LABEL] [--only ID,ID...] [--keep]
#
#   --check        compare with scenarios.tsv, print one HCRESULT line per
#                  scenario (test/container/lib.sh format) and exit 1 on any
#                  mismatch. Without it, only the transcripts are written.
#   --shell PATH   the shell ./dev runs under (default: sh from PATH). Run this
#                  script under the same one: `dash run-cli.sh --shell dash`.
#   --out DIR      where transcripts go, one directory per scenario (default:
#                  inside the sandbox, which is kept only if something failed)
#   --script PATH  the ./dev to test (default: ../../dev). The mutation suite
#                  points this at the baseline script and expects FAILs.
#   --impl LABEL   result ids are B-<LABEL>-<id> (default: sh)
#   --only IDS     run just these scenarios (comma-separated)
#   --keep         keep the sandbox
#
# Needs no docker and no network: `docker` on PATH is test/cli/fake-docker.sh,
# which only records its arguments. Runs under dash, bash, busybox ash and Git
# Bash - it is run in all of them - so it is strictly POSIX: no `local`, no
# arrays, no GNU-only flags (awk does the string work, by literal index(), so
# a path with '[x]' or a space in it is never read as a pattern).
#
# SANDBOX. <tmp>/s/<id>/ holds, per scenario, fake checkouts of all thirteen
# siblings (pom.xml, or package.json for webapp, and an LF mvnw) next to a
# home-crew-infrastructure/ with a copy of the ./dev under test, both compose
# files, dev-reload.sh, webapp-dev.sh and test/fixtures/ci.env as .env. Fresh
# per scenario, because the setup flags break it in different ways. Nothing
# outside the sandbox is ever written, except --out.
#
# TRANSCRIPTS. <out>/<id>/: exit, stdout.raw, stderr.raw, docker.log (the
# fake's records), and normalised stdout, stderr, calls (argv per line),
# calls.cwd (normalised cwd<TAB>argv), info (the '==>' lines), verdict
# (STATUS<TAB>message). Normalised = CR and ANSI escapes removed, the sandbox
# replaced by <ROOT> (the infra checkout), <SIB> (the directory holding the
# checkouts) and <BASE>. test/lib/SuiteCli.ps1 compares these files across
# implementations, and Invoke-CliScenarios.ps1 writes the same layout for
# dev.ps1, so the two must stay in step.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
TEST=$(dirname "$HERE")
INFRA=$(dirname "$TEST")

. "$TEST/container/lib.sh"

usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$HERE/run-cli.sh"; }
die2() {
    printf 'run-cli.sh: %s\n' "$*" >&2
    exit 2
}
need() { [ $# -ge 2 ] || die2 "$1 needs a value"; }

CHECK=0 SHELL_ARG=sh OUT="" SCRIPT="$INFRA/dev" IMPL=sh ONLY="" KEEP=0
while [ $# -gt 0 ]; do
    case $1 in
        --check) CHECK=1 ;;
        --shell) need "$@"; SHELL_ARG=$2; shift ;;
        --out) need "$@"; OUT=$2; shift ;;
        --script) need "$@"; SCRIPT=$2; shift ;;
        --impl) need "$@"; IMPL=$2; shift ;;
        --only) need "$@"; ONLY=$2; shift ;;
        --keep) KEEP=1 ;;
        -h | --help) usage; exit 0 ;;
        *) die2 "unknown option '$1' (try --help)" ;;
    esac
    shift
done

case $IMPL in '' | *[!A-Za-z0-9._-]*) die2 "bad --impl '$IMPL'" ;; esac

# Absolute paths only from here on: every scenario runs in its own cwd.
abspath() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }

case $SHELL_ARG in
    */*) SH_BIN=$(abspath "$SHELL_ARG") || SH_BIN="" ;;
    *) SH_BIN=$(command -v "$SHELL_ARG" 2>/dev/null) || SH_BIN="" ;;
esac
[ -n "$SH_BIN" ] && [ -f "$SH_BIN" ] && [ -x "$SH_BIN" ] || die2 "no such shell: $SHELL_ARG"
[ -f "$SCRIPT" ] || die2 "no such script: $SCRIPT"
SCRIPT=$(abspath "$SCRIPT")
DEFAULT_SCRIPT=0
[ "$SCRIPT" = "$INFRA/dev" ] && DEFAULT_SCRIPT=1

SCENARIOS=$HERE/scenarios.tsv
FAKE=$HERE/fake-docker.sh
for _f in "$SCENARIOS" "$FAKE" "$TEST/fixtures/ci.env" "$INFRA/docker-compose.yml" "$INFRA/compose.dev.yml"; do
    [ -f "$_f" ] || die2 "missing $_f"
done

TAB=$(printf '\t')
CR=$(printf '\r')
ESC=$(printf '\033')
US=$(printf '\037')
# e-acute in UTF-8, for the non-ASCII sandbox path: generated, so that this
# file and scenarios.tsv stay ASCII.
EACUTE=$(printf '\303\251')

# The same list ./dev checks. A service added there and not here shows up as
# "missing or incomplete" in every `up` scenario, which is the right alarm.
SIBLINGS="service-discovery config-server api-gateway auth-service user-service
admin-service booking-service worker-service notification-service
payment-service xp-service assignment-service"

ORIG_PATH=$PATH

# Physical path: on macOS mktemp answers under /var, a symlink to
# /private/var, and ./dev's `pwd` must print the same string the normaliser
# looks for.
BASE=$(mktemp -d "${TMPDIR:-/tmp}/hc-cli.XXXXXX") || die2 "mktemp failed"
BASE=$(cd "$BASE" && pwd -P) || die2 "cannot enter $BASE"

OUT_IN_BASE=0
if [ -z "$OUT" ]; then
    OUT=$BASE/out
    OUT_IN_BASE=1
fi
mkdir -p "$OUT" || die2 "cannot create $OUT"
OUT=$(cd "$OUT" && pwd -P)

cleanup() {
    if [ "$KEEP" = 1 ] || { [ "$OUT_IN_BASE" = 1 ] && [ "$HC_FAILED" != 0 ]; }; then
        printf 'run-cli.sh: sandbox kept: %s\n' "$BASE" >&2
    else
        case $BASE in */hc-cli.*) rm -rf "$BASE" ;; esac
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# The template every scenario sandbox is copied from, and the fake docker
# ---------------------------------------------------------------------------

TPL=$BASE/template
mkdir -p "$TPL/home-crew-infrastructure" "$TPL/elsewhere" || die2 "cannot build the template"
cp "$SCRIPT" "$TPL/home-crew-infrastructure/dev"
for _f in docker-compose.yml compose.dev.yml dev-reload.sh webapp-dev.sh; do
    if [ -f "$INFRA/$_f" ]; then cp "$INFRA/$_f" "$TPL/home-crew-infrastructure/$_f"; fi
done
cp "$TEST/fixtures/ci.env" "$TPL/home-crew-infrastructure/.env"
for _svc in $SIBLINGS; do
    mkdir -p "$TPL/home-crew-$_svc"
    printf '<project/>\n' >"$TPL/home-crew-$_svc/pom.xml"
    # LF bytes, always: a CRLF mvnw is itself a scenario (crlf-mvnw), so the
    # default one must be clean or every `up` would fail on it.
    printf '#!/bin/sh\necho fake mvnw\n' >"$TPL/home-crew-$_svc/mvnw"
done
mkdir -p "$TPL/home-crew-webapp"
printf '{}\n' >"$TPL/home-crew-webapp/package.json"

BIN=$BASE/bin
mkdir -p "$BIN"
cp "$FAKE" "$BIN/docker"
chmod 755 "$BIN/docker"

# Prove that `docker` on the scenario PATH is the fake, before anything runs:
# a real docker would answer the probe with an error, not the magic word.
_probe=$(
    PATH=$BIN:$ORIG_PATH
    export PATH
    FAKE_DOCKER_LOG=
    export FAKE_DOCKER_LOG
    docker __fake_probe 2>/dev/null
) || _probe=""
[ "$_probe" = fake-docker-probe ] || die2 "the docker on PATH is not the fake in $BIN"

# PATH for `nodocker`: no docker anywhere, but the tools ./dev needs. On a
# Linux host /usr/bin often holds the REAL docker, and a scenario that reached
# it would run a real `compose up` or `down` - so then it is a directory of
# links to just those tools, and if docker is still found the scenario is
# BLOCKED rather than risked.
if [ ! -e /usr/bin/docker ] && [ ! -e /bin/docker ]; then
    NODOCKER_PATH=/usr/bin:/bin
else
    NODOCKER_PATH=$BASE/nodocker-bin
    mkdir -p "$NODOCKER_PATH"
    for _t in awk cat cmp dirname grep sed tr; do
        _p=$(command -v "$_t" 2>/dev/null) || continue
        case $_p in /*) ln -s "$_p" "$NODOCKER_PATH/$_t" ;; esac
    done
fi
NODOCKER_BLOCKED=""
if (PATH=$NODOCKER_PATH; command -v docker >/dev/null 2>&1); then
    NODOCKER_BLOCKED="a docker is still on the no-docker PATH ($NODOCKER_PATH)"
fi

# ---------------------------------------------------------------------------
# Normalisation (awk, by literal index(): paths may hold [ ] * and spaces)
# ---------------------------------------------------------------------------

NORM_FUNCS='
function repl(s, a, b,    out, i) {
    if (a == "") return s
    out = ""
    while ((i = index(s, a)) > 0) {
        out = out substr(s, 1, i - 1) b
        s = substr(s, i + length(a))
    }
    return out s
}
function unesc(s,    out, i, rest) {
    out = ""
    while ((i = index(s, ENVIRON["HCN_ESC"])) > 0) {
        out = out substr(s, 1, i - 1)
        rest = substr(s, i + 1)
        if (substr(rest, 1, 1) == "[") {
            rest = substr(rest, 2)
            while (rest != "" && index("0123456789;?", substr(rest, 1, 1)) > 0) rest = substr(rest, 2)
            rest = substr(rest, 2)
        }
        s = rest
    }
    return out s
}
function norm(s) {
    s = repl(s, ENVIRON["HCN_CR"], "")
    s = unesc(s)
    s = repl(s, ENVIRON["HCN_ROOT"], "<ROOT>")
    s = repl(s, ENVIRON["HCN_SIB"], "<SIB>")
    return repl(s, ENVIRON["HCN_BASE"], "<BASE>")
}
'

# normalise <in> <out>
normalise() {
    HCN_CR=$CR HCN_ESC=$ESC HCN_ROOT=$ROOT HCN_SIB=$SIB HCN_BASE=$BASE \
        LC_ALL=C awk "$NORM_FUNCS"'{ print norm($0) }' "$1" >"$2"
}

# extract_calls <docker.log> <calls> <calls.cwd>
extract_calls() {
    : >"$2"
    : >"$3"
    HCN_CR=$CR HCN_ESC=$ESC HCN_ROOT=$ROOT HCN_SIB=$SIB HCN_BASE=$BASE HCN_US=$US \
        HCN_CALLS=$2 HCN_CWD=$3 LC_ALL=C awk -F '\t' "$NORM_FUNCS"'
        $1 == "CALL" {
            cwd = norm($2)
            gsub(/\\/, "/", cwd)
            argv = norm(repl($5, ENVIRON["HCN_US"], " "))
            print argv > ENVIRON["HCN_CALLS"]
            print cwd "\t" argv > ENVIRON["HCN_CWD"]
        }' "$1"
}

# join <sep> <file>: the file's lines joined by sep, or '-' if it has none.
join_lines() {
    _j=$(LC_ALL=C awk -v sep="$1" '{ printf "%s%s", (NR > 1 ? sep : ""), $0 }' "$2")
    if [ -z "$_j" ]; then printf '%s' -; else printf '%s' "$_j"; fi
}

# ---------------------------------------------------------------------------
# Scenario setup
# ---------------------------------------------------------------------------

to_crlf() {
    LC_ALL=C awk '{ printf "%s\r\n", $0 }' "$1" >"$1.crlf" && mv "$1.crlf" "$1"
}

# A .env the way Windows PowerShell 5.1's `>` writes one: UTF-16LE with a BOM.
# Built as a printf format of octal escapes, since neither iconv nor a NUL in
# a shell string is portable.
write_utf16_env() {
    _fmt='\377\376'
    for _l in POSTGRES_USER=homecrew POSTGRES_PASSWORD=homecrew POSTGRES_DB=homecrew; do
        _fmt="$_fmt$(printf '%s' "$_l" | LC_ALL=C sed 's/./&\\000/g')\\015\\000\\012\\000"
    done
    # shellcheck disable=SC2059  # the format IS the data, on purpose
    printf "$_fmt" >"$1"
}

# set_fake_env 'K=V;K=V': exported for the scenario's subshell. Only FAKE_*
# names: a typo in the table must not quietly set something else.
set_fake_env() {
    [ "$1" = - ] && return 0
    _rest=$1
    while [ -n "$_rest" ]; do
        case $_rest in
            *';'*) _kv=${_rest%%;*}; _rest=${_rest#*;} ;;
            *) _kv=$_rest; _rest="" ;;
        esac
        _k=${_kv%%=*}
        _v=${_kv#*=}
        case $_k in FAKE_[A-Z]*) ;; *) return 1 ;; esac
        case $_k in *[!A-Z0-9_]*) return 1 ;; esac
        export "$_k=$_v"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

WHY=""
note() { WHY="${WHY:+$WHY; }$*"; }
contains() {
    case $1 in *"$2"*) return 0 ;; esac
    return 1
}

# check_pieces <file> <spec> <label>: the |-separated substrings of spec must
# appear in the file ('!x': must not), compared with '\' read as '/'.
check_pieces() {
    [ "$2" = - ] && return 0
    _hay=$(tr '\\' '/' <"$1")
    _label=$3
    _oldifs=$IFS
    IFS='|'
    set -f
    # shellcheck disable=SC2086  # split on | on purpose
    set -- $2
    IFS=$_oldifs
    set +f
    for _p in "$@"; do
        _p=$(printf '%s' "$_p" | tr '\\' '/')
        case $_p in
            '!'*)
                _p=${_p#!}
                if contains "$_hay" "$_p"; then note "$_label must not contain '$_p'"; fi
                ;;
            *) contains "$_hay" "$_p" || note "$_label lacks '$_p'" ;;
        esac
    done
}

first_line() { LC_ALL=C sed -n '/[^[:space:]]/{p;q;}' "$1" | cut -c1-160; }

check_scenario() {
    WHY=""
    [ "$RC" = "$exp_exit" ] || note "exit $RC, expected $exp_exit"

    _got=$(join_lines ';' "$D/calls")
    [ "$_got" = "$exp_calls" ] || note "docker calls [$_got], expected [$exp_calls]"

    _bad=$(LC_ALL=C awk -F '\t' '$2 ~ /^compose -f / && $1 != "<ROOT>" { print $1; exit }' "$D/calls.cwd")
    [ -z "$_bad" ] || note "compose ran in '$_bad', not in <ROOT>"

    _got=$(join_lines '|' "$D/info")
    [ "$_got" = "$exp_info" ] || note "'==>' lines [$_got], expected [$exp_info]"

    case $exp_err in
        -) ;;
        '(empty)')
            if [ -n "$(tr -d ' \t\n' <"$D/stderr")" ]; then
                note "stderr is not empty: $(first_line "$D/stderr")"
            fi
            ;;
        *) check_pieces "$D/stderr" "$exp_err" stderr ;;
    esac
    check_pieces "$D/stdout" "$exp_out" stdout

    # Output is captured, not a terminal: ./dev must not colour it.
    if LC_ALL=C grep -q "$ESC" "$D/stdout.raw"; then note "stdout carries ANSI escapes"; fi

    if [ "$EXPECT_MSYS" = 1 ]; then
        LC_ALL=C awk -F '\t' '$1 == "CALL" { n++; if ($3 != "1" || $4 != "*") bad++ }
            END { exit !(n > 0 && bad == 0) }' "$D/docker.log" ||
            note "not every docker call saw MSYS_NO_PATHCONV=1 and MSYS2_ARG_CONV_EXCL=*"
    fi
}

# verdict <STATUS> <message>
verdict() {
    printf '%s\t%s\n' "$1" "$2" >"$D/verdict"
    case $1 in
        PASS) N_PASS=$((N_PASS + 1)) ;;
        FAIL) N_FAIL=$((N_FAIL + 1)) ;;
        *) N_OTHER=$((N_OTHER + 1)) ;;
    esac
    if [ "$CHECK" = 1 ]; then
        case $1 in
            FAIL) hc_fail "B-$IMPL-$id" "$2" ;;
            *) hc_result "B-$IMPL-$id" "$1" "$2" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# One scenario
# ---------------------------------------------------------------------------

run_scenario() {
    SIB=$BASE/s/$id
    case ",$setup," in
        *,hostile-sp,*) SIB="$SIB/hc cli [x]" ;;
        *,hostile-u,*) SIB="$SIB/hc-$EACUTE" ;;
    esac
    ROOT=$SIB/home-crew-infrastructure
    D=$OUT/$id
    rm -rf "$D"
    mkdir -p "$D"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$argv" "$setup" "$envs" "$exp_exit" \
        "$exp_calls" "$exp_err" "$exp_out" "$exp_info" "$req" >"$D/scenario"
    : >"$D/docker.log"
    : >"$D/stdout.raw"
    : >"$D/stderr.raw"

    # Copied to a path that does not exist yet: `cp -R dir dst` is then the
    # same operation in GNU, BSD and busybox cp (dir/. into an existing dst
    # is not quite).
    if ! { mkdir -p "$(dirname "$SIB")" && cp -R "$TPL" "$SIB"; }; then
        verdict FAIL "could not build the sandbox at $SIB"
        return
    fi

    NODOCKER=0 SPRING=0 CWDMODE=elsewhere EXPECT_MSYS=0
    if [ "$setup" != - ]; then
        _oldifs=$IFS
        IFS=,
        set -f
        # shellcheck disable=SC2086
        set -- $setup
        IFS=$_oldifs
        set +f
        for _flag in "$@"; do
            case $_flag in
                noenv) rm -f "$ROOT/.env" ;;
                utf16env) write_utf16_env "$ROOT/.env" ;;
                crlfenv) to_crlf "$ROOT/.env" ;;
                # A password typed in an ANSI editor: one byte that is not
                # UTF-8, and no NUL, so it is plain text.
                latin1env) printf 'HC_LATIN1=caf\351\n' >>"$ROOT/.env" ;;
                missing-xp) rm -f "$SIB/home-crew-xp-service/pom.xml" ;;
                crlf-mvnw) to_crlf "$SIB/home-crew-user-service/mvnw" ;;
                crlf-reload) to_crlf "$ROOT/dev-reload.sh" ;;
                nodocker) NODOCKER=1 ;;
                spring-profile) SPRING=1 ;;
                cwd-root) CWDMODE=root ;;
                cwd-sibling) CWDMODE=sibling ;;
                expect-msys) EXPECT_MSYS=1 ;;
                hostile-sp | hostile-u | sh-only) ;;
                *)
                    verdict FAIL "scenarios.tsv: unknown setup flag '$_flag'"
                    return
                    ;;
            esac
        done
    fi

    if [ "$NODOCKER" = 1 ] && [ -n "$NODOCKER_BLOCKED" ]; then
        verdict BLOCKED "not run: $NODOCKER_BLOCKED"
        return
    fi

    case $CWDMODE in
        root) RUN_CWD=$ROOT RUN_SCRIPT=./dev ;;
        sibling) RUN_CWD=$SIB/home-crew-user-service RUN_SCRIPT=../home-crew-infrastructure/dev ;;
        *) RUN_CWD=$SIB/elsewhere RUN_SCRIPT=$ROOT/dev ;;
    esac
    if [ "$NODOCKER" = 1 ]; then RUN_PATH=$NODOCKER_PATH; else RUN_PATH=$BIN:$ORIG_PATH; fi

    RC=0
    (
        # Nothing from the caller may steer the run: the fake's knobs come
        # from the table only, and ./dev must set the MSYS variables itself.
        unset FAKE_INFO_EXIT FAKE_INFO_STDERR FAKE_COMPOSE_VERSION FAKE_VERSION_EXIT \
            FAKE_VOLUME_CREATE_EXIT FAKE_CONFIG_EXIT FAKE_COMPOSE_EXIT FAKE_COMPOSE_STDERR \
            SPRING_PROFILES_ACTIVE MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL BASH_ENV ENV CDPATH
        FAKE_DOCKER_LOG=$D/docker.log
        export FAKE_DOCKER_LOG
        if [ "$SPRING" = 1 ]; then
            SPRING_PROFILES_ACTIVE=dev
            export SPRING_PROFILES_ACTIVE
        fi
        set_fake_env "$envs" || exit 126
        PATH=$RUN_PATH
        export PATH
        cd "$RUN_CWD" || exit 125
        set -f
        if [ "$argv" = - ]; then exec "$SH_BIN" "$RUN_SCRIPT"; fi
        # shellcheck disable=SC2086  # argv is split on spaces on purpose
        exec "$SH_BIN" "$RUN_SCRIPT" $argv
    ) </dev/null >"$D/stdout.raw" 2>"$D/stderr.raw" || RC=$?
    printf '%s\n' "$RC" >"$D/exit"

    normalise "$D/stdout.raw" "$D/stdout"
    normalise "$D/stderr.raw" "$D/stderr"
    extract_calls "$D/docker.log" "$D/calls" "$D/calls.cwd"
    LC_ALL=C grep '^==> ' "$D/stdout" >"$D/info" || :

    if [ "$RC" = 126 ] && [ "$CHECK" = 1 ]; then
        verdict FAIL "scenarios.tsv: bad env column '$envs'"
        return
    fi
    if [ "$CHECK" != 1 ]; then
        verdict INFO "exit $RC"
        return
    fi
    check_scenario
    if [ -z "$WHY" ]; then
        _n=$(LC_ALL=C grep -c . "$D/calls")
        verdict PASS "exit $RC, $_n docker call(s) and the output as expected"
    else
        verdict FAIL "$WHY"
    fi
}

# ---------------------------------------------------------------------------
# B-MAP-01, the ./dev-side view (test/lib/SuiteCli.ps1 repeats it with the
# PowerShell parser): every function in dev and dev.ps1 is in function-map.txt
# ---------------------------------------------------------------------------

map_check() {
    _map=$HERE/function-map.txt
    if [ ! -f "$_map" ]; then
        hc_fail B-MAP-01 "test/cli/function-map.txt is missing"
        return
    fi
    if [ ! -f "$INFRA/dev.ps1" ]; then
        hc_skip B-MAP-01 "no dev.ps1 next to dev"
        return
    fi
    _t=$BASE/map
    mkdir -p "$_t"
    LC_ALL=C sed -n -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*(\{.*)?$/\1/p' \
        "$INFRA/dev" | sort -u >"$_t/sh"
    # PowerShell names are case-insensitive, so they are compared lowercased.
    LC_ALL=C sed -n -E 's/^[[:space:]]*[Ff][Uu][Nn][Cc][Tt][Ii][Oo][Nn][[:space:]]+([A-Za-z][A-Za-z0-9_-]*).*$/\1/p' \
        "$INFRA/dev.ps1" | tr 'A-Z' 'a-z' | sort -u >"$_t/ps"
    : >"$_t/left"
    : >"$_t/right"
    : >"$_t/bad"
    HCM_L=$_t/left HCM_R=$_t/right HCM_BAD=$_t/bad LC_ALL=C awk '
        {
            line = $0; c = ""
            i = index(line, "#")
            if (i > 0) { c = substr(line, i + 1); line = substr(line, 1, i - 1) }
            gsub(/[ \t\r]+/, "", line)
            if (line == "") next
            j = index(line, "=")
            if (j == 0) { print "line " NR ": no =" > ENVIRON["HCM_BAD"]; next }
            a = substr(line, 1, j - 1); b = substr(line, j + 1)
            if (a == "" && b == "") { print "line " NR ": empty entry" > ENVIRON["HCM_BAD"]; next }
            if ((a == "" || b == "") && c !~ /[A-Za-z]/) print "line " NR ": one-sided entry without a reason" > ENVIRON["HCM_BAD"]
            if (a != "") print a > ENVIRON["HCM_L"]
            if (b != "") print tolower(b) > ENVIRON["HCM_R"]
        }' "$_map"
    _why=""
    while IFS= read -r _fn; do
        grep -Fxq -e "$_fn" "$_t/left" || _why="$_why dev:$_fn(unmapped)"
    done <"$_t/sh"
    while IFS= read -r _fn; do
        grep -Fxq -e "$_fn" "$_t/right" || _why="$_why dev.ps1:$_fn(unmapped)"
    done <"$_t/ps"
    while IFS= read -r _fn; do
        grep -Fxq -e "$_fn" "$_t/sh" || _why="$_why map:$_fn(not in dev)"
    done <"$_t/left"
    while IFS= read -r _fn; do
        grep -Fxq -e "$_fn" "$_t/ps" || _why="$_why map:$_fn(not in dev.ps1)"
    done <"$_t/right"
    while IFS= read -r _fn; do _why="$_why $_fn"; done <"$_t/bad"
    if [ -z "$_why" ]; then
        hc_pass B-MAP-01 "all $(grep -c . "$_t/sh") dev and $(grep -c . "$_t/ps") dev.ps1 functions are paired in function-map.txt"
    else
        hc_fail B-MAP-01 "function-map.txt is out of step:$_why"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Ten columns on every data row, before anything runs: a shifted column would
# otherwise surface as a baffling mismatch far from its cause.
LC_ALL=C awk -F '\t' '!/^#/ && NF > 0 && NF != 10 { printf "scenarios.tsv:%d: %d columns, expected 10\n", NR, NF; bad = 1 }
    END { exit bad }' "$SCENARIOS" >&2 || die2 "malformed scenarios.tsv"

N_PASS=0 N_FAIL=0 N_OTHER=0
while IFS=$TAB read -r id argv setup envs exp_exit exp_calls exp_err exp_out exp_info req <&3; do
    case $id in '' | '#'*) continue ;; esac
    req=${req%"$CR"}
    case $id in *[!A-Za-z0-9._-]*) die2 "scenarios.tsv: bad id '$id'" ;; esac
    case ",$setup," in *,ps-only,*) continue ;; esac
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in *",$id,"*) ;; *) continue ;; esac
    fi
    run_scenario
done 3<"$SCENARIOS"

if [ "$CHECK" = 1 ] && [ "$DEFAULT_SCRIPT" = 1 ] && [ -z "$ONLY" ]; then
    map_check
fi

printf 'run-cli.sh: %s (%s): %d passed, %d failed, %d other; transcripts in %s\n' \
    "$IMPL" "$SH_BIN" "$N_PASS" "$N_FAIL" "$N_OTHER" "$OUT" >&2

if [ "$CHECK" = 1 ]; then hc_exit; fi
exit 0
