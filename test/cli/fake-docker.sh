#!/bin/sh
# A stand-in for the docker CLI, used by test/cli/run-cli.sh (sh, dash,
# busybox) and by test/cli/Invoke-CliScenarios.ps1 when dev.ps1 runs under
# pwsh on macOS or Linux. On Windows every implementation uses FakeDocker.exe
# instead (test/cli/FakeDocker.cs), because a shell script run from Git Bash
# is exec'd MSYS-to-MSYS and so never shows the argument rewriting a real
# docker.exe gets. The two fakes must behave identically: same log format,
# same knobs, same output.
#
# It never talks to a daemon. It records how it was called and then does what
# the FAKE_* variables say, so a scenario can play a healthy docker, a dead
# daemon, an old Compose, a failing volume create and so on.
#
# LOG. One record per call, appended to $FAKE_DOCKER_LOG (if set):
#
#     CALL<TAB><cwd><TAB><MSYS_NO_PATHCONV><TAB><MSYS2_ARG_CONV_EXCL><TAB><argv>
#
# argv is joined with the ASCII unit separator (\037), so an argument with a
# space in it stays one argument. An unset MSYS variable is logged as '-':
# ./dev must export both for Git Bash, and the log is how the test sees that.
#
# BEHAVIOUR.
#
#     __fake_probe            prints fake-docker-probe; the drivers use it to
#                             prove this fake, not a real docker, is on PATH
#     info                    FAKE_INFO_STDERR on stderr if set, then exit
#                             FAKE_INFO_EXIT (0)
#     compose ... version     FAKE_COMPOSE_VERSION (2.29.1) on stdout, or
#                             nothing for the value @empty; exit
#                             FAKE_VERSION_EXIT (0) - non-zero plays a docker
#                             without the compose plugin
#     volume create X         prints X, exit FAKE_VOLUME_CREATE_EXIT (0)
#     compose ... config      exit FAKE_CONFIG_EXIT (FAKE_COMPOSE_EXIT, 0)
#     compose ... <sub>       'fake-docker: compose <sub>' on stdout, so a test
#                             can see compose output reaching the user; exit
#                             FAKE_COMPOSE_EXIT (0)
#     anything else           exit FAKE_COMPOSE_EXIT (0)
#
# Every compose call except version also writes FAKE_COMPOSE_STDERR to stderr
# if it is set: real compose writes its progress there, and Windows PowerShell
# 5.1 is known to trip over native stderr.
#
# @empty stands for "prints nothing" because Windows cannot hold an empty
# environment variable - setting one to "" deletes it - and both fakes must
# read the same scenario table.

US=$(printf '\037')

if [ -n "${FAKE_DOCKER_LOG:-}" ]; then
    _rec="" _sep=""
    for _a in "$@"; do
        _rec="$_rec$_sep$_a"
        _sep=$US
    done
    printf 'CALL\t%s\t%s\t%s\t%s\n' "$(pwd)" "${MSYS_NO_PATHCONV:--}" \
        "${MSYS2_ARG_CONV_EXCL:--}" "$_rec" >>"$FAKE_DOCKER_LOG"
fi

# code <value> <default>: an exit status from a FAKE_* value. Anything that is
# not a plain number of at most three digits falls back to the default, as in
# FakeDocker.cs.
code() {
    case ${1:-} in
        '' | *[!0-9]* | ????*) printf '%s' "$2" ;;
        *) printf '%s' "$1" ;;
    esac
}

# The compose subcommand: the first word after compose that is neither a
# global flag nor the value of one (-f FILE, -p NAME, ...).
compose_sub() {
    while [ $# -gt 0 ]; do
        case $1 in
            -f | --file | -p | --project-name | --env-file | --project-directory | \
                --profile | --ansi | --progress | --parallel)
                shift
                ;;
            -*) ;;
            *)
                printf '%s' "$1"
                return 0
                ;;
        esac
        [ $# -gt 0 ] && shift
    done
    return 0
}

if [ $# -eq 1 ] && [ "$1" = __fake_probe ]; then
    echo fake-docker-probe
    exit 0
fi

case ${1:-} in
    info)
        if [ -n "${FAKE_INFO_STDERR:-}" ]; then printf '%s\n' "$FAKE_INFO_STDERR" >&2; fi
        exit "$(code "${FAKE_INFO_EXIT:-}" 0)"
        ;;
    volume)
        if [ "${2:-}" = create ]; then
            _rc=$(code "${FAKE_VOLUME_CREATE_EXIT:-}" 0)
            if [ "$_rc" -eq 0 ]; then
                _name=fake-anonymous-volume
                if [ $# -gt 2 ]; then for _a in "$@"; do _name=$_a; done; fi
                printf '%s\n' "$_name"
            fi
            exit "$_rc"
        fi
        ;;
    compose)
        shift
        _sub=$(compose_sub "$@")
        if [ "$_sub" = version ]; then
            _rc=$(code "${FAKE_VERSION_EXIT:-}" 0)
            if [ "$_rc" -ne 0 ]; then
                printf "docker: 'compose' is not a docker command.\n" >&2
                exit "$_rc"
            fi
            _v=${FAKE_COMPOSE_VERSION-2.29.1}
            if [ "$_v" != @empty ]; then
                case " $* " in
                    *" --short "*) printf '%s\n' "$_v" ;;
                    *) printf 'Docker Compose version %s\n' "$_v" ;;
                esac
            fi
            exit 0
        fi
        if [ -n "${FAKE_COMPOSE_STDERR:-}" ]; then printf '%s\n' "$FAKE_COMPOSE_STDERR" >&2; fi
        _all=$(code "${FAKE_COMPOSE_EXIT:-}" 0)
        if [ "$_sub" = config ]; then
            exit "$(code "${FAKE_CONFIG_EXIT:-}" "$_all")"
        fi
        printf 'fake-docker: compose %s\n' "$_sub"
        exit "$_all"
        ;;
esac

exit "$(code "${FAKE_COMPOSE_EXIT:-}" 0)"
