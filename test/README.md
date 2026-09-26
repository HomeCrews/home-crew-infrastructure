# test/ - verification harness for the local dev setup

This directory checks that the local dev setup (`dev`, `dev.ps1`,
`compose.dev.yml`, `dev-reload.sh`, `webapp-dev.sh`, `Dockerfile.dev`) does
what the top-level [README](../README.md) says it does. It checks on the
machine you actually use: Windows with Docker Desktop first, macOS and Linux
as well. One run leaves one report, `test/results/<run>/summary.md`. It lists
each check, the requirement it backs, and the evidence behind the verdict.

Why a harness and not a checklist: most of what the dev-setup change fixes
cannot be seen by reading the files. That includes:

- a race: twelve Maven builds on one cache;
- platform differences: PowerShell 5.1 vs 7, Git Bash, CRLF checkouts, the
  WSL2 clock;
- launch details: a JVM's argv, the order of its classpath.

These problems show up only when the files run, many times over, and the
results are compared. Where it is possible, each check is also run against
the setup *before* the change, and it has to FAIL there. A check that still
passes there is reported WEAK, because its PASS would prove nothing.

Quick start, on Windows, from the `home-crew-infrastructure` checkout:

    pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Suite quick

Then open the `summary.md` path that the run prints at the end.

- [What it verifies](#what-it-verifies)
- [Prerequisites](#prerequisites)
- [Running it](#running-it)
- [The suites](#the-suites)
- [Safety](#safety)
- [Results and exit codes](#results-and-exit-codes)
- [Reading the statuses](#reading-the-statuses)
- [After a crash: -Restore](#after-a-crash--restore)
- [Adding a test](#adding-a-test)
- [Files](#files)

## What it verifies

Each result row carries the ids of the requirements it is evidence for. A
`*` in a test id stands for a family, for example one row per service or per
scenario.

| Req | What must hold | Checked by |
|---|---|---|
| R1 | Maven cache lifecycle. There is one Maven cache, the external volume `homecrew-maven-repo`. `dev up` and `dev.ps1 up` create it, and running them again is harmless. `down -v` keeps it. No service binds `${HOME}/.m2`. | A-CFG-01d, A-CFG-04; B up, down-v and volume-create-fails scenarios; D-WARM, H-VOL-01, H-VOL-02, H-UP-01, H-WEB-*; F-VOL-01; opt-in: D-REAL-UP, H-VOL-03 |
| R2 | Networking is unchanged. Containers reach each other by service name. Config is served by config-server. Every host port binds to 127.0.0.1. | A-CFG-01a, A-CFG-01e, A-URL-01; F-NET-01..05; mutation M |
| R3 | The Maven wrapper install is race-free. It is shared and serialised by `flock`, installed once, never nested, and a half-finished install is removed rather than run. | A-WRAP-01/02, C-WRAP-*, D-WRAP-ONCE, D-WRAP-PARTIAL, D-WRAP-READY, D-WRAP-<round>-* |
| R4 | Twelve simultaneous cold builds, and warm ones, share one volume safely. There is no lock, transfer, checksum or zip error, and each artifact is downloaded once. The repository is clean afterwards. The lock files are kept, and they really exclude other processes. An idle stack stays idle. | A-CFG-01h, C-MVN-*, D-COLD-mvnd, D-COLD-mvnw, D-SCAN-*, D-LOCK-ADAPTER-*, D-LOCK-HOLD-*, D-LOCK-JCMD, D-LOCK-PROBE, D-WARM, D-STACK-COLD, D-STACK-COLD-IDLE, F-IDLE; mutation M; opt-in: D-REAL-READY |
| R5 | All twelve services mount that one volume at `/root/.m2`, and every classpath jar comes from it. | A-CFG-01d, D-COLD-*-CP, F-VOL-01..03 |
| R6 | Launching with plain `java` is equivalent to `spring-boot:run`. The JVM args and their order match. The main class is found from compiled classes, with no silent fallback. Classpath, environment, working directory and merged stderr all match. | A-CFG-05, A-TOOLS-*, C-MC-*, C-LC-*, D-COLD-*-MAIN, E-<svc>-* for all 12, E-VOLATILE |
| R7 | Reload semantics. Every kind of change is picked up exactly once, at the cheapest level: a source change restarts the context in the same JVM, and a pom change starts a new JVM. A broken edit leaves the running app serving. | C-FP-*, C-GOOD-*, C-RES-*, C-VAL-*, C-SM-mvnd-*, C-SM-mvnw-*; G-*; mutation M |
| R8 | Everything is validated before it runs. That covers the compose config, sh/dash/bash/busybox parsing, PowerShell 5.1 and 7 parsing, and LF line endings. | A-SH-*, A-PS-*, A-EOL-01..03, A-CFG-01..02 |
| R9 | `dev` and `dev.ps1` behave the same under every shell they are used with: sh, dash, busybox, Git Bash, WSL, PowerShell 5.1 and 7. | B-<impl>-<scenario>, B-PARITY-<scenario>, B-MAP-01; H-UP-01..03; mutation M |
| R10 | Production is untouched: `docker-compose.yml`, `.github/`, `postgres/` and the service repositories. The production findings this change leaves alone are re-checked and reported. | A-PROD-01..04, R-PROD-<nn> (INFO) |
| R11 | JDWP. Every JVM listens on container port 5005, which is published on its own host port on 127.0.0.1 (5005-5016). The socket is owned by the application's own pid, and a debugger can attach. | A-CFG-01a/b/c/h, E-<svc>-jdwp, F-JDWP-01..05; mutation M |

Two kinds of row carry no requirement id. SECRET-SCAN is the final check
that nothing from `.env` reached the results (see [Safety](#safety)). The
`*-HARNESS-ERROR` rows report a bug in the harness itself.

## Prerequisites

| What | Needed for | Check |
|---|---|---|
| PowerShell 7.2 or later (`pwsh`) | everything except `sh test/run.sh` without pwsh | `pwsh -v` |
| Windows PowerShell 5.1 | the 5.1 halves of A-PS and B; ships with Windows | nothing to install |
| Docker Desktop (WSL2 backend) with Compose 2.24.4 or later | every suite except the host-only parts of A and B | `docker compose version` |
| git on PATH (Git for Windows on Windows) | A-EOL, A-PROD, baseline comparisons, dirty-checkout checks | `git --version` |
| Git for Windows' `bin\sh.exe` | A-SH on the Windows host, B-gitbash, H-UP-03; found from `git --exec-path`, never from PATH | comes with Git for Windows |
| `.env` (a filled-in copy of `.env.example`) | A-CFG-02, and D, E, F, G, H: config-server needs the git token to clone home-crew-config | `Test-Path .env` |
| Network | building `homecrew-dev-runtime:jdk25` once, pulling `node:24-alpine`, Maven Central (D, E, M), GitHub (config-server) | - |
| Docker VM memory | D and M: about 10 GB for the test project, or 20 GB with your own stack running beside it. E: 5 GB. The live stack alone: 14 GB of limits. | `docker info --format "{{.MemTotal}}"` |

**Installing PowerShell 7.** Run this in any terminal:

    winget install --id Microsoft.PowerShell

If winget is missing, or UAC or company policy blocks the installer, use the
portable ZIP instead. It needs no admin rights:

1. Download `PowerShell-7.x.y-win-x64.zip` (any 7.2 or later; the LTS is a
   good choice) from https://github.com/PowerShell/PowerShell/releases.
2. In Windows PowerShell, where `7.x.y` is the version you downloaded, run:

       Unblock-File -Path .\PowerShell-7.x.y-win-x64.zip
       Expand-Archive -Path .\PowerShell-7.x.y-win-x64.zip -DestinationPath "$env:LOCALAPPDATA\pwsh"
       & "$env:LOCALAPPDATA\pwsh\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Suite quick

**Docker VM memory on Windows.** With the WSL2 backend, the VM's memory is set
in `%UserProfile%\.wslconfig`, not in Docker Desktop's settings. By default
the VM gets half your RAM:

    [wsl2]
    memory=16GB

Then run `wsl --shutdown`, start Docker Desktop again, and check with
`docker info --format "{{.MemTotal}}"`. Docker reports slightly less than the
configured value, so configure at least `memory=12GB` to pass the 10 GB check.
When memory is short, the suites that need it report BLOCKED with this same
hint. They do not start twelve JVMs and risk an OOM in the VM, which could
also kill containers from your other projects.

**Execution policy.** `-ExecutionPolicy Bypass` covers the harness and
`dev.ps1`. A Group Policy overrides it, though. If `Get-ExecutionPolicy -List`
shows anything other than `Undefined` for MachinePolicy or UserPolicy, the
PowerShell checks report BLOCKED, or the run does not start at all. A checkout
downloaded as a ZIP rather than cloned also needs:

    Get-ChildItem -Recurse | Unblock-File

**Managed machines.** On Windows, suite B compiles a small fake `docker.exe`
into `%TEMP%`. AppLocker, WDAC or Smart App Control may refuse to run it. B's
Windows implementations are then BLOCKED: they are never passed through a
weaker stand-in.

## Running it

Run everything from the `home-crew-infrastructure` checkout. Each run writes
a new `test/results/<yyyyMMdd-HHmmss>-<host>/` and prints its path at the
start and at the end.

### Windows

    # A + B + C: no stack needed, about 10-20 min
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Suite quick

    # every suite, about 2-3 h (more on a cold cache or a slow network); your data and Maven cache are kept
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Suite all

    # one suite: static cli unit concurrency parity stack reload lifecycle mutation
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Suite concurrency

    # after a crash: put back the files that run had edited
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Restore 20260926-143012-mypc

**Several suites in one run.** `-File` passes every argument as a literal
string. So `-Suite static,cli` arrives as the single string `static,cli`,
which the script rejects. Start pwsh, and call the script from inside it,
where the list syntax works:

    pwsh -NoProfile -ExecutionPolicy Bypass
    PS> ./test/run.ps1 -Suite concurrency, parity, mutation
    PS> $LASTEXITCODE

**Switches.** They combine with any `-Suite`. The first two are the only ways
to touch your real data, and both are off by default.

| Switch | Effect |
|---|---|
| `-ColdRealMavenVolume` | D-REAL. It runs `.\dev.ps1 down` (`sh ./dev` off Windows), then `docker volume rm homecrew-maven-repo`, then `up`: **your Maven cache is deleted and downloaded again**. Use it with `-Suite concurrency`. |
| `-AllowDataLoss` | H-VOL-03. It runs `.\dev.ps1 down -v` on your own stack: **your databases, Kafka's log and the build caches are emptied**. The Maven volume must survive. Use it with `-Suite lifecycle`. |
| `-WithWsl` | Windows: also runs `./dev` in your default WSL distribution (B-wsl). Without it, B-wsl is SKIP. |
| `-KeepTestProject` | Leaves the isolated `homecrew-test` project and its Maven volume in place afterwards, so that you can inspect them. Remove them later with `docker compose -p homecrew-test -f docker-compose.yml -f compose.dev.yml -f test/compose.test.yml down -v` and then `docker volume rm homecrew-maven-repo-test`. |
| `-BaselineRef <commit>` | The pre-change commit that the parity, mutation and scope checks compare against. The default is the infra row of `baseline-refs.tsv` (`82ca122`). A shallow clone may lack it; run `git fetch --unshallow`. |
| `-Restore <run-id>` | Restores the edits of a crashed run; no suite runs. See [below](#after-a-crash--restore). |

**A full verification in two passes.** `stack` and `reload` inspect *your*
running dev stack. `concurrency` and `mutation` start twelve more JVMs in the
test project. Doing both in one `-Suite all` needs about 20 GB in the Docker
VM. With less, run two passes:

1. Stop your stack with `.\dev.ps1 down`. Then run `-Suite quick`, and in one
   pwsh session `./test/run.ps1 -Suite concurrency, parity, mutation`.
2. Start your stack with `.\dev.ps1 up`, and wait until every service has
   logged `[dev-reload] app-ready`. Close any debugger attached to 5005-5016.
   Then run `./test/run.ps1 -Suite stack, reload, lifecycle`.

Lifecycle runs last. It stops your stack, starts parts of it, and at the end
starts again whatever was running before (H-RESTORE). It keeps your data
unless you pass `-AllowDataLoss`.

### macOS and Linux

    pwsh -NoProfile -File test/run.ps1 -Suite quick    # every command above works, with / paths
    sh test/run.sh                                      # without pwsh: see below
    sh test/run.sh -Suite all                           # with pwsh on PATH, this simply runs run.ps1

PowerShell 7 for macOS comes from `brew install --cask powershell`. For Linux,
see Microsoft's packages. The Windows-only checks report SKIP here: PowerShell
5.1, Git Bash, `FakeDocker.exe` and `Get-NetTCPConnection`. The launcher under
test is `sh ./dev`.

**Without pwsh**, `sh test/run.sh` runs the two parts that need neither pwsh
nor docker:

- `static/sh-syntax.sh`, which parses every shell file with each shell present
  (sh, dash, bash, busybox) and checks it for CR bytes;
- `cli/run-cli.sh --check`, which runs every row of `cli/scenarios.tsv`
  through `./dev` against `cli/fake-docker.sh`.

It prints the HCRESULT lines to the terminal and writes no results directory.
It exits 0 when every row is PASS and 1 otherwise, and takes under a minute.

## The suites

The suites run in this order: static, cli, unit, concurrency, parity, stack,
reload, lifecycle, mutation. `quick` is static + cli + unit. When the run ends,
it removes the test project (unless `-KeepTestProject`), runs SECRET-SCAN and
writes the summary. A suite whose file is missing is reported as SKIP
`<suite>-MISSING`. The times below are rough first-run estimates;
`commands.log` has the real durations.

| Suite | Req | Needs | Time | What it touches |
|---|---|---|---|---|
| A `static` | R1-R8 R10 R11 | Nothing; docker for the compose model and the dash/busybox parses; `.env` for A-CFG-02 | ~3 min | nothing |
| B `cli` | R9 R1 | Nothing; docker for the dash/busybox runs; Windows for ps51/gitbash | 5-10 min | a throwaway sandbox in temp |
| C `unit` | R3 R4 R6 R7 | docker; the dev image is built on first use, which needs the network once | 5-15 min | nothing: `--network none`, the checkout mounted read-only |
| D `concurrency` | R1 R3 R4 R5 R6 | docker, `.env`, the network, 10 GB of VM memory (20 GB with your stack up) | 45-90 min | the test project only; D-REAL needs the opt-in |
| E `parity` | R6 R11 | docker, `.env`, the network, 5 GB of VM memory | 40-60 min | the test project only |
| F `stack` | R1 R2 R4 R5 R11 | your dev stack up and serving | 10-15 min | read-only; probe scripts are copied to `/tmp` in your containers |
| G `reload` | R7 R11 | your dev stack up; the checkouts it edits must be clean | 30-60 min | edits in your checkouts, through the manifest, restored |
| H `lifecycle` | R1 R9 | docker, `.env` | 15-30 min | stops your stack, starts parts of it, then puts it back as found; an edit to the webapp lockfile, restored; `-AllowDataLoss` for `down -v` |
| M `mutation` | R1 R2 R4 R7 R9 R11 | as D and C, plus the baseline commit | 30-60 min | the test project only |

### A static (lib/SuiteStatic.ps1)

- **A-SH.** Every shell file parses in sh, dash, bash and busybox ash, and has
  no CR byte. It runs on the host, in the dev image and in node:24-alpine.
- **A-PS.** `dev.ps1` and every `.ps1` in `test/` parse under PowerShell 5.1
  and 7, and are ASCII without a BOM.
- **A-EOL-01..03.** `git ls-files --eol` across the fifteen checkouts:
  - every file that is run is LF;
  - the tolerated files (`.mvn/jvm.config`, `lombok.config`, `Dockerfile.dev`,
    `*.sql`) are checked too;
  - every run file has an `eol=lf` attribute.
- **A-CFG-01a..h.** The rendered `docker-compose.yml` + `compose.dev.yml`
  model is checked for:
  - (a) 127.0.0.1 on every port;
  - (b) the debug-port table;
  - (c) the JDWP args;
  - (d) the external Maven volume, mounted once per service;
  - (e) `depends_on`;
  - (f) the healthchecks;
  - (g) the `DEV_*` passthrough;
  - (h) the shared environment anchor, identical in all twelve.
- **A-CFG-02.** `config --quiet` with your real `.env`; only the exit code is
  kept.
- **A-CFG-04.** No `${HOME}` in `compose.dev.yml`.
- **A-CFG-05.** The environment of each service is compared with the baseline
  `compose.dev.yml`, through an allowlist.
- **A-URL-01.** The effective container-profile URLs name services, never the
  host.
- **A-PROD-01..04.**
  - (01) The production files are unchanged since the baseline.
  - (02) Every changed file is a dev file or is under `test/`.
  - (03) The fifteen checkouts end the run as they started it: same HEAD, same
    status, and the same `.git/config` and hooks.
  - (04) The siblings are at their baseline commits.
- **R-PROD-nn.** Each row of `prod-findings.tsv` is re-checked and reported as
  INFO.
- **A-WRAP-01/02.** All twelve use one wrapper distribution.
- **A-TOOLS-\*.** The tools `dev-reload.sh` relies on are in the image.

### B cli (lib/SuiteCli.ps1, cli/)

Every row of `cli/scenarios.tsv` runs under every implementation. There are
about sixty rows:

- help and unknown commands;
- `up`, `up svc`, `up a b`, `down -v`, `--volumes`, `logs -t`;
- a `.env` that is missing, UTF-16 or CRLF;
- a missing sibling, or a CRLF `mvnw`;
- no docker, or a dead daemon;
- Compose versions either side of 2.24.4;
- a failing volume create or config;
- exit-code passthrough, the working directory, the MSYS variables, and a
  hijacked `docker` function;
- checkout paths with a space, `[x]` or a non-ASCII character.

The implementations are:

- `sh` (the host), `dash` (dev image) and `busybox` (node:24-alpine);
- `gitbash` and `ps51` (Windows only), and `ps7`;
- `wsl` (Windows, with `-WithWsl`).

On Windows, gitbash, ps51 and ps7 all call one compiled `FakeDocker.exe`;
elsewhere, ps7 uses `fake-docker.sh`. Each fake records its argv and cwd, so
the checks compare what the launchers *called*, not what they printed.

- **B-\<impl\>-\<id\>.** One scenario on one implementation, compared with the
  table.
- **B-PARITY-\<id\>.** Every implementation gave the same exit code, the same
  docker calls in the same directories, and the same `==>` lines.
- **B-MAP-01.** Every function of `dev` has its `dev.ps1` twin in
  `cli/function-map.txt`.

### C unit (lib/SuiteUnit.ps1, container/unit-*.sh)

C runs in the dev image, with the same dash, GNU find, flock and javap that
the real containers use.

`unit-dev-reload.sh` sources the functions with `DEV_RELOAD_LIB_ONLY=1` and
tests them one at a time:

- **C-FP.** The fingerprints: create, modify, delete, rename, an mtime-only
  change, a backdated mtime, a space in a name, `src/test` ignored, and
  `.mvn`/`lombok.config` changes.
- **C-MC.** The main class: 0, 1 and 2 candidates, decoys, an instance
  `main()`, `Outer$Inner`, `DEV_MAIN_CLASS`, and `.hidden/`.
- **C-LC.** The launch argv: order, absolute path, no globbing, and a refusal
  on a bad classpath.
- **C-GOOD / C-RES.** The last-good snapshot, and resource pruning.
- **C-VAL.** Settings validation.
- **C-WRAP.** The wrapper install under flock.
- **C-MVN.** The compiler choice, and the Maven flags on every call.

`unit-state-machine.sh` drives the real loop against fake mvnd, mvnw, java and
curl, once per compiler. Its rows are **C-SM-mvnd-\*** and **C-SM-mvnw-\***.
The cases are:

- boot;
- a source edit, and a failed one;
- a pom edit (exactly one STOP, then one START), and a broken pom;
- a failing classpath step;
- crash backoff, and SIGTERM;
- an edit during a compile, and an app that ignores SIGTERM;
- no main class at boot;
- a save during boot, and a boot timeout;
- build retries;
- a deleted file, and a backdated edit;
- a burst of saves, and a failed reload.

**C-UNIT-RUN** and **C-SM-\<c\>-RUN** check that each script ran to the end:
it printed its final `HCDONE` line, and exited 0, or 1 when cases failed.

### D concurrency (lib/SuiteConcurrency.ps1)

D runs in the isolated test project, starting from an empty test Maven
volume. It keeps the volume it filled for the suites after it, so parity
does not download everything again; the run removes it at the end.

- **D-COLD-mvnd, D-COLD-mvnw.** Twelve `dev-reload.sh --build-only` runs,
  released together by a barrier: once through mvnd and once through `./mvnw`.
  - They fail on any lock, transfer, checksum or zip error, and on any
    artifact URL downloaded more than once.
  - **D-COLD-\*-MAIN** checks the main classes.
  - **D-COLD-\*-CP** checks that every classpath entry is on the shared
    volume.
- **D-SCAN-\*.** After each round, the volume is scanned:
  - no `.tmp`, `.part` or `.lastUpdated` leftovers;
  - no zero-byte jar or pom;
  - every `.sha1` matches;
  - every jar entry is readable;
  - the lock files are still there.
- **D-WRAP-\*.** The wrapper was installed once, is not nested, and is
  complete. An incomplete install planted beforehand was removed and never
  run.
- **D-LOCK-\*.**
  - The resolver logged file-lock with file-gav.
  - `jcmd` shows `deleteLockFiles=false` on the mvnd daemon.
  - A held lock blocks a build.
  - The reverse probe sees Maven holding the very file it created.
- **H-VOL-02 and D-WARM.** The test project's `down -v` removes its own
  volumes and keeps both Maven volumes. A warm round then downloads nothing.
- **D-STACK-COLD.** The real entrypoint, for all twelve, from an empty volume,
  until each one serves. It is followed by **D-STACK-COLD-IDLE**: two quiet
  minutes with no rebuild or restart marker.
- **D-REAL** (opt-in). The same cold start on your real cache, through the
  real launcher.

### E parity (lib/SuiteParity.ps1, container/capture-launch.sh, java/LaunchDiff.java)

For each of the twelve services, the harness launches the app twice in fresh
test-project containers with `-T`:

- OLD is the baseline `dev-reload.sh`, which uses `spring-boot:run`;
- NEW is today's script, which uses plain `java`.

The two live JVMs are then compared. The facts come from `jcmd` and
`/proc/<pid>`:

- the JVM args, exactly;
- the main class;
- the classpath, as an ordered list, minus the starter, annotation-processor
  and devtools jars that `spring-boot:run` drops;
- the system properties and the environment, minus the volatile set (learned
  from two NEW launches, **E-VOLATILE**) and `parity/whitelist.txt`;
- the working directory `/app`, the same exe, stdout equal to stderr, and no
  Maven JVM left;
- JDWP 5005 owned by the application pid;
- the logs: the same profile, the same `Located environment` and the same
  port.

Its rows are **E-\<svc\>-\<check\>**.

- Every compose call here pins `DEV_OPTIMIZED_LAUNCH=true`,
  `DEV_MAVEN_EXTRA_ARGS=`, `DEV_COMPILER=auto` and
  `SPRING_PROFILES_ACTIVE=container` (**E-ENV**). Your own tuning in `.env`
  therefore cannot show up as a parity failure of the defaults.
- The memory precondition counts what a running dev stack already uses.
- A secret's value is compared as a salted hash, so a secret that changed or
  went empty between the two launches is still caught.
- A network or memory failure of the baseline's own build is BLOCKED, not
  FAIL.

### F stack (lib/SuiteStack.ps1, container/stack-probe.sh, java/KafkaProbe.java)

F checks your running dev stack:

- **F-VOL-01..03.** One `homecrew-maven-repo` mount at `/root/.m2` in all
  twelve, with the same dev:inode. Every `dev-classpath.txt` entry and every
  jar on the running JVM's `-cp` lies under `/root/.m2/repository`.
- **F-NET-01.** Eureka lists 11 apps UP, and their hostnames resolve.
- **F-NET-02.** The gateway routes are not 5xx, and `/users/test` returns 200.
- **F-NET-03.** Health is UP from the host and from container to container,
  `db` is UP in the 7 JPA services, and `discoveryComposite` is UP.
- **F-NET-04.** `Located environment` appears in the 10 config clients.
- **F-NET-05.** A Kafka AdminClient reaches `kafka:9092`.
- **F-JDWP-01..05.**
  - The application pid owns 5005.
  - A host `JDWP-Handshake` works on 127.0.0.1:5005-5016. It is skipped while
    a debugger is attached.
  - The host listeners are 127.0.0.1 only, and the LAN IP is unreachable.
  - The README port table equals the compose mapping.
- **F-IDLE.** Two minutes with no rebuild or restart marker.

### G reload (lib/SuiteReload.ps1)

G edits the live user-service through the edit manifest. It refuses to start
on a dirty checkout. Small probe `@Component`s print markers. A case counts
`Started` lines until the expected count is reached, then waits for 20 s of
quiet. The cases are:

- create, modify, rename or delete a class: one restart, the same pid, and the
  old class gone;
- a syntax error: no restart, health still UP, the classes intact; the fix
  then gives one restart. The case first waits for `dev-reload.sh`'s one
  automatic retry, which fails the same way, so that the fix cannot race it;
- a resource added or deleted: pruned;
- a broken `src/test`: ignored;
- a pom edit: one new JVM, which owns 5005;
- a `.mvn/jvm.config` edit;
- a dependency added and removed, and an exclusion change: checked against
  both the classpath file and the live `java.class.path`;
- a broken pom, again waited on until its first automatic retry has failed;
- a backdated edit;
- a save during boot: exactly one reload;
- a burst of saves: at most one restart;
- a JDWP session kept across a DevTools restart;
- a create/delete probe in all twelve services.

At the end, `.git/config` and the hooks are hashed and compared with the start.
While G runs, leave the checkouts it edits alone. An edit of yours makes the
restore refuse that file, which keeps your edit but leaves the harness's
edits in the rest of the file.

### H lifecycle (lib/SuiteLifecycle.ps1)

- **H-VOL-01.** `docker volume create homecrew-maven-repo` run twice: both
  exit 0, and the volume is not replaced.
- **H-VOL-02.** The test project's `down -v` removes its own volumes and keeps
  the external Maven volumes.
- **H-VOL-03** (opt-in). A real `.\dev.ps1 down -v` removes your stack's
  volumes and keeps the Maven cache.
- **H-UP-01.** `up user-service` starts exactly postgres, kafka,
  service-discovery, config-server and user-service. It runs through
  `.\dev.ps1` on Windows and `sh ./dev` elsewhere.
- **H-UP-02.** `up webapp` starts the webapp alone, and 127.0.0.1:4200 answers
  200.
- **H-UP-03.** The same through Git Bash's `sh.exe`. Off Windows, this row is
  SKIP and **H-UP-03-sh** runs instead.
- **H-WEB-01..03.**
  - A lockfile change triggers `npm ci` at the next start, onto the populated
    `node_modules` volume.
  - The host `package*.json` bytes and git status never change.
  - **H-WEB-02-RESTORE** checks that the edit was put back byte for byte.
- **H-RESTORE.** The services that were running at the start are started
  again. A stack that was down is left down.

If your stack runs from another checkout (the same container names under
another compose project), H-UP and H-WEB are SKIP and nothing of it is
touched.

### M mutation (lib/SuiteMutation.ps1)

M re-runs the key checks with the fix taken away, and each one must FAIL.
When a check still passes, its row is WEAK:

- D-COLD with `rwlock-local` and `deleteLockFiles=true` must show duplicate
  downloads;
- C-FP and C-SM against the baseline `dev-reload.sh`;
- the A-CFG port checks against the baseline `compose.dev.yml`;
- B `down -v` against the baseline `dev.ps1`.

## Safety

The harness runs against your real machine, beside your real stack, so it is
built to fail closed.

- **An isolated test project.** Suites D, E and M run in
  `docker compose -p homecrew-test ... -f test/compose.test.yml`. B and C use
  throwaway `docker run --rm --network none` containers instead. The test
  project has its own containers (no pinned `homecrew-*` names), its own network
  `homecrew-test`, its own Maven volume `homecrew-maven-repo-test`, no host
  ports and no restart policy. Every checkout is mounted **read-only**, so a
  test build cannot write to your repositories, `.git/config` included. Before
  anything starts, the rendered test model is checked to be isolated in
  exactly these ways, and if it is not, the suite does not run.
- **A fail-closed docker guard.** Every docker call goes through
  `Assert-DockerArgsSafe`. It refuses:
  - any `prune`;
  - any `volume rm` except of the test project's volumes;
  - any container `rm` except of `hct-*` and `homecrew-test-*` containers;
  - any `compose down -v` of your stack without `-AllowDataLoss`;
  - removing `homecrew-maven-repo` without `-ColdRealMavenVolume`.

  The launcher calls docker itself, outside the guard. So the steps that run
  it with destructive arguments are gated by the same switches:
  `-ColdRealMavenVolume` for D-REAL, and `-AllowDataLoss` for H-VOL-03's
  `down -v`. Your stack is recognised by its pinned
  `homecrew-*` container names, not by a project name that depends on what
  your clone's directory is called.
- **Hash-guarded edits.** Files in your checkouts are changed only through the
  edit manifest, `results/<run>/manifests/*.json`. The manifest records the
  original bytes and the hash of every version the harness wrote, and it is
  saved *before* each edit. A restore puts the original back only if the file
  still holds bytes the harness wrote. If you edited the file in the meantime,
  the harness refuses and names it rather than overwrite your work. Nothing
  ever runs `git checkout`, `reset` or `clean` on your checkouts.
- **Dirty checkouts are left alone.** The reload suite refuses to start on a
  checkout with uncommitted changes. The lifecycle webapp tests are SKIP if
  `home-crew-webapp` has uncommitted changes. All git calls use
  `--no-optional-locks`, so they never take `index.lock` from under your IDE.
- **Opt-in for real data.** Your real Maven cache and your databases are
  touched only with `-ColdRealMavenVolume` or `-AllowDataLoss`. Without them,
  those steps are SKIP with the reason.
- **Secrets are never written.**
  - The compose JSON checks render with `test/fixtures/ci.env`, which holds
    dummy values.
  - With your `.env`, the harness only runs `config --quiet`, and keeps only
    its exit code.
  - Every value from `.env` that is 12 characters or longer and differs from
    `.env.example` is replaced by `<redacted#n>`. This covers `commands.log`
    and all evidence saved through `Save-Evidence`. The container-side
    captures of a process environment never let a secret's value out either.
    stack-probe.sh blanks every `...TOKEN...=`, `...PASSWORD...=`,
    `...SECRET...=` and `ENCRYPT_KEY=` value. capture-launch.sh replaces each
    one with the first 12 hex digits of a salted SHA-256. The salt is made per
    run, kept in memory only, and passed to the container through docker's
    environment, never on a command line.
  - SECRET-SCAN then greps the whole results directory for those values,
    including files that containers wrote there directly, and FAILs on any
    hit.

  Values shorter than 12 characters are not treated as secrets, so use real
  secrets longer than that.
- **Production is not touched.** No production file is written:
  `docker-compose.yml`, `.github/`, `postgres/` and `.env` stay as they are.
  A-PROD proves this for every run.
- **Bounded.** Every wait has a timeout. The B and C containers run with
  `--network none`. At the end of every run, the test project is removed
  (containers, network, volumes and `homecrew-maven-repo-test`), and so is any
  `hct-*` container still there, such as one that Ctrl+C interrupted. Pass
  `-KeepTestProject` to keep them. The suite that started a one-off `hct-*`
  container removes it.

## Results and exit codes

`test/results/` is gitignored. Each run writes `test/results/<run>/`:

| File | Contents |
|---|---|
| `summary.md` | The report to read, or paste back. It holds the counts, the environment, the files changed since the baseline, and one table per suite (status, id, requirements, result, evidence). It lists every SKIP, BLOCKED, WARN and WEAK under "Limitations of this run", and every R-PROD finding under "Intentionally unchanged production findings". |
| `summary.json` | The same rows, machine-readable: `Suite, Id, Req[], Status, Message, Evidence[], At`. |
| `commands.log` | Every external command the run executed, with its exit code and duration, and any TIMED OUT or START-FAILED. It is redacted. |
| `env.txt` | OS; the pwsh and PowerShell 5.1 versions; the docker and Compose versions; Docker VM memory; the git version and `core.autocrlf`; the baseline; the HEAD of every `home-crew-*` checkout, and whether it is dirty. |
| `<suite>/` | The evidence the rows point at: rendered models, transcripts, container logs, launch captures, diffs, scans. |
| `manifests/` | The edit manifests of any suite that changed a checkout. `-Restore` reads these. |

| Exit code | Meaning |
|---|---|
| 0 | Nothing FAILed, was WEAK or was BLOCKED. SKIP, WARN and INFO do not change the exit code, so still read "Limitations of this run". |
| 1 | At least one FAIL, WEAK or BLOCKED row. |
| 2 | A harness error: a suite threw. Its row is `<suite>-HARNESS-ERROR`, with the position. |

`-Restore` exits 0 when every file was restored, and 1 when a file was
refused. `sh test/run.sh` without pwsh exits 0 or 1.

## Reading the statuses

| Status | Meaning | What to do |
|---|---|---|
| PASS | The check ran and held. | - |
| FAIL | The thing under test is wrong: the dev setup, or the harness's expectation of it. | Open the evidence named in the row. |
| WEAK | Only the mutation suite gives this. The check also passed with the fix taken away, so its PASS elsewhere proves nothing. | The test needs a sharper assertion. It counts as a failure. |
| BLOCKED | The environment stopped the check: memory, network (for example HTTP 429 from Maven Central), a policy (AppLocker, WDAC, a Group Policy execution policy), or an image that would not build. | Fix the environment, then re-run that suite. The requirement is unverified until then, so BLOCKED counts as a failure. |
| SKIP | The check does not apply here, or was not asked for: no docker, not Windows, no `.env`, an opt-in not given. The message says which. | Nothing, unless the requirement matters on this machine. A SKIP proves nothing either way. |
| WARN | The check passed with a caveat, often a documented limitation. | Read the message. |
| INFO | A finding, not a verdict: R-PROD rows, A-WRAP-02, D-MVND. | Read the message. |

## After a crash: -Restore

A suite that edits a checkout restores it in a `finally` block, which also
runs on Ctrl+C. After Ctrl+C the reload suite does only the quick part,
because a `finally` cannot be interrupted again:
- the files go back;
- the probe classes are purged;
- the clean reload that follows is not waited for.

Its RESTORE row is then WARN, and names the two commands to run if an
HC-PROBE line still appears. If the window was closed, or the machine slept or
crashed, restore by hand. Use the run id, which is the name of the results
directory:

    pwsh -NoProfile -ExecutionPolicy Bypass -File .\test\run.ps1 -Restore 20260926-143012-mypc

It puts back only the files that still hold bytes the harness wrote. A file
you changed since is listed as REFUSED and left alone. Its original bytes are
still in the manifest JSON, base64 in `Original`.

A crash can also leave the reload suite's probe classes (package `devprobe`)
compiled in a running service, where they load again at every restart. To
remove them, run:

    docker exec homecrew-<service> sh -c 'find /app/target/classes -type d -name devprobe -prune -exec rm -rf {} +'

Then save any source file of that service.

## Adding a test

The conventions are in the header of `lib/Harness.ps1`. In short:

- **Where it goes.**
  - A new check belongs in the suite whose prerequisites it shares.
  - A new launcher behaviour is a row in `cli/scenarios.tsv`: both launchers
    and every shell pick it up.
  - A new `dev-reload.sh` behaviour goes into a group of
    `container/unit-dev-reload.sh`, or a case of
    `container/unit-state-machine.sh`.
- **A new suite.** A new suite is `lib/Suite<Name>.ps1`, with exactly one
  public function, `Invoke-Suite<Name>`, that takes no parameters. Add its
  name to the `ValidateSet` and to `$order` in `run.ps1`. Every suite file is
  dot-sourced into one scope, so prefix each helper with the suite's name
  (`Static-*`, `Cli-*`, `Unit-*`, `Conc-*`, `Parity-*`, ...). Call
  `Enter-Suite '<name>' '<title>'` first.
- **Results.** Report only through
  `Add-Result -Id <X-AREA-nn> -Status <...> -Message <...> -Req @('Rn') -Evidence @(<path>)`.
  Ids start with the suite letter and are unique within a run. Save evidence
  with `Save-Evidence`, which also redacts it, or under
  `Get-EvidenceDir <suite>`, and never into a checkout. Never print a verdict
  any other way.
- **Commands.** Run every external command through `Invoke-Native`,
  `Invoke-Docker`, `Invoke-TestCompose`, `Invoke-LiveCompose` or `Invoke-Git`,
  with a `-TimeoutSec`, so that it appears in `commands.log`. For waits, use
  `Wait-Until` with a timeout.
- **Docker.** Never work around `Assert-DockerArgsSafe`: if it refuses, the
  test is wrong. Use the test project (`Initialize-TestProject`,
  `Invoke-TestCompose`, one-off containers named `hct-*`). Check memory with
  `Test-DockerMemory` before starting many JVMs.
- **Checkouts.** Edit through `Start-EditManifest`, `Set-TrackedFile` and
  `Remove-TrackedFile`, and put everything back with `Restore-EditManifest` in
  a `finally`. Check `Test-RepoClean` before the first edit.
- **Verdicts.**
  - SKIP, with the reason, when a prerequisite is missing: no docker, not
    Windows, no opt-in.
  - BLOCKED when the environment stops the check: memory, network, policy.
  - FAIL only for the thing under test.
  - One step that throws must not cost the rest of the suite its results.
    Catch the exception per step, as `Conc-Step` does, and report
    `<id>-HARNESS-ERROR`.
- **PowerShell rules.**
  - Everything runs under `Set-StrictMode -Version 3.0`:
    - initialise every variable;
    - put `@()` around pipeline results that you index or `.Count`;
    - read optional JSON fields through `$o.PSObject.Properties['name']`.
  - Files are ASCII, with no BOM and LF endings.
  - A-PS also parses every `.ps1` with Windows PowerShell 5.1. So do not use
    the ternary operator, `??`, `?.` or `&&`/`||` chains.
- **Container side.**
  - Scripts are POSIX sh for dash, and for busybox ash where stated. They
    source `container/lib.sh` and report with `hc_pass`, `hc_fail`,
    `hc_skip`, `hc_warn` and `hc_info`, which print HCRESULT lines.
  - Run them through `Invoke-InDevImage`: `--network none`, with the checkout
    read-only at `/src`. Turn their output into rows with `Import-HcResults`.
  - Byte-level tools are single-file Java under `java/`, run as
    `java /src/test/java/X.java`, using the JDK only.
  - Check shell files with `dash -n` and `bash -n`; A-SH does the rest.
- **Discrimination.** If the check guards a fix, add its mutation to suite M:
  it must FAIL against the baseline. Then add its id to the table at the top
  of this file.

## Files

    run.ps1                  the driver: -Suite, the switches, -Restore, cleanup, summary
    run.sh                   POSIX entry: execs run.ps1 if pwsh exists, else the sh-only checks
    lib/Harness.ps1          results, Invoke-*, the docker guard, the edit manifest, the summary
    lib/Suite*.ps1           one file per suite (A static ... M mutation)
    compose.test.yml         the isolated test project overlay (-p homecrew-test)
    static/                  sh-syntax.sh (A-SH), Test-PsParse.ps1 (A-PS)
    cli/                     scenarios.tsv, run-cli.sh, Invoke-CliScenarios.ps1, the two fake dockers, function-map.txt
    container/               lib.sh (HCRESULT helpers) and the container-side scripts of C, D, E, F
    java/                    LaunchDiff, LockProbe, VerifyJars, KafkaProbe (single-file tools)
    parity/whitelist.txt     the launch differences suite E allows, each with its reason
    baseline-refs.tsv        the pre-change commit of all fifteen repositories
    prod-findings.tsv        the production findings R-PROD re-checks
    fixtures/ci.env          dummy .env values for rendering the compose model
    results/                 output, one directory per run (gitignored)
