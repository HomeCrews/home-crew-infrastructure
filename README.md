# home-crew-infrastructure

The docker compose topology for HomeCrew and the workflow that deploys it to
the Hetzner dev host.

One of fifteen repositories that make up HomeCrew, a home-services marketplace
built as a Spring Boot microservice system. This one holds no application
code; it is what runs the other fourteen.

## At a glance

| | |
|---|---|
| Stack | docker compose, one host |
| Images | `mthanuj/homecrew-*:dev` on Docker Hub |
| Deploy trigger | `repository_dispatch`, type `service-image-updated` |
| Default branch | `dev` |
| Build | none |

## Running the stack

    cp .env.example .env            # Windows: Copy-Item .env.example .env
    ./dev up                        # Windows: .\dev.ps1 up

Three commands, and that is the whole interface:

| Command | What it does |
|---|---|
| `./dev up [svc...]` | start everything - or only the named services and what they depend on - hot reloading |
| `./dev down [-v]` | stop everything; `-v` also empties the databases, Kafka's log and the build caches (the Maven cache is kept) |
| `./dev logs [svc...]` | follow logs |

`./dev up user-service` starts postgres, kafka, service-discovery,
config-server and user-service, and nothing else - a fraction of the memory of
the full stack. `./dev up webapp` starts the frontend alone.

Your machine needs docker, with **Compose 2.24.4 or later** (the dev override
uses its `!override` and `!reset` tags; `./dev` checks and says so), and a
`.env`. It does **not** need a JDK or Maven, because the containers do the
compiling.

**There is no non-watch mode.** Every service runs from its sibling checkout at
`../home-crew-<service>`, compiled inside its own container.

That includes **webapp**, which is the odd one out: it is Angular, not a JVM,
so it gets `node:24-alpine` and Angular's own dev server instead of
`Dockerfile.dev` and the compile loop. Its `node_modules` lives in a named
volume rather than on the bind mount, installed with `npm ci` - which never
rewrites your `package-lock.json` - and installed again automatically, at the
next start of the webapp container, whenever `package.json` or
`package-lock.json` differs from what was installed last. It
starts at once, without waiting for the Java services: it calls nothing
server-side, only your browser does.

`.env` is gitignored and is **required**, not optional: `POSTGRES_PASSWORD` is
declared `${VAR:?}` in the compose file, so `docker compose config` exits
non-zero without one. That is deliberate - the deploy runs
`docker compose config --quiet`, and until this was a hard failure it passed
happily against a host with no `.env` at all.

To wipe the databases, Kafka's log and the build caches: `./dev down -v`. A
plain `docker compose down -v`, without the two `-f` flags `./dev` passes, only
knows the volumes of `docker-compose.yml` and leaves the dev caches behind.

### On Windows

Use `dev.ps1`, which mirrors `dev` exactly - same commands, same guards, same
messages: `.\dev.ps1 up`, `.\dev.ps1 down -v`, `.\dev.ps1 logs`. It works in
Windows PowerShell 5.1 and in PowerShell 7. From `cmd.exe`,
`powershell -ExecutionPolicy Bypass -File dev.ps1 up`. The two scripts are a
pair; a change to one belongs in the other, and `test/` runs both against the
same scenarios. `./dev` also works from Git Bash or a WSL shell.

- **Execution policy.** If PowerShell refuses to run the script at all, allow
  local scripts once with `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`,
  or pass `-ExecutionPolicy Bypass` per call. A checkout downloaded as a ZIP
  also needs `Unblock-File .\dev.ps1`.
- **Line endings.** Everything a container executes or reads is checked out
  with LF endings (`.gitattributes`), whatever `core.autocrlf` says. A clone
  made before those rules, or an editor that rewrites endings, can still leave
  CRLF behind - which breaks the scripts inside Linux. `dev.ps1` refuses to
  start in that case and names the files; check each out again with
  `Remove-Item <file>; git -C <its repository> checkout -- <file>`.
- **Memory.** With Docker Desktop's WSL2 backend the VM's memory is set in
  `%UserProfile%\.wslconfig` (`[wsl2]`, `memory=12GB`, then `wsl --shutdown`),
  not in Docker Desktop's settings. It defaults to half your RAM.
- **Ports.** If `up` fails with "an attempt was made to access a socket in a
  way forbidden by its access permissions", Windows has reserved that port for
  Hyper-V: `netsh interface ipv4 show excludedportrange protocol=tcp` shows the
  ranges. A local PostgreSQL service on 5432 collides the same way.
- **Speed.** A checkout on the Windows filesystem is read through Docker
  Desktop's file sharing, which is slower than a checkout inside the WSL
  filesystem (`\\wsl$\...`, with `./dev` run from a WSL shell). Excluding the
  checkouts from Defender's real-time scanning, or putting them on a Dev Drive,
  helps either way.
- **`.env` encoding.** Windows PowerShell 5.1's `>` and `Out-File` write
  UTF-16, which compose cannot read. `dev.ps1` refuses such a `.env` and shows
  how to convert it. `.env.example` also shows how to generate `ENCRYPT_KEY`
  without openssl.

## Hot reload

Save a file. That service picks the change up; nothing else is touched, and no
image is rebuilt.

| You change | What happens |
|---|---|
| anything under `src/main` - `.java`, `application.properties`, any resource | compile, then DevTools restarts the context in-process: same JVM, same pid, an attached debugger stays attached |
| `pom.xml`, `.mvn/**` or `lombok.config` | full build - compile plus the dependency classpath - then the application is stopped and a new JVM started |
| anything under `src/test` | nothing, deliberately - a test edit should not bounce the running service |

A dependency change is the one case that cannot be hot-reloaded: a JVM's
classpath is fixed when it launches, so the process has to go.

Each service's log narrates what happens, one `[dev-reload] <event>: ...` line
at a time - `source-changed`, `compile-ok`, `trigger-touched`, `build-changed`,
`app-started`, `app-ready` and so on. The event names are a stable contract
(listed at the top of `dev-reload.sh`), which is what `test/` counts.

### How it works

What makes the loop work is that **no container holds a copy of your code**.
`compose.dev.yml` puts every Java service on `Dockerfile.dev` - a JDK and Maven
tooling, no application - and bind-mounts its checkout at `/app`.
`dev-reload.sh` then does two things inside each container:

1. **It polls the checkout and builds.** Every two seconds it fingerprints
   `src/main`, and separately `pom.xml`, `.mvn` and `lombok.config`: the sorted
   list of path, size and modification time, hashed. Any difference is a
   change - an edit, a new file, a deletion, a rename, even a modification time
   that went *backwards*. It then waits for the tree to stop changing (a
   `git checkout` mid-write, an IDE "save all") before building once.
2. **It runs the application with plain `java`.** Not `mvnw spring-boot:run`,
   which kept a whole Maven JVM parked beside every application, compiled the
   tests on every start (so one half-written test stopped the service from
   starting at all), and made the application a grandchild that only `pkill`
   could reach. What `spring-boot:run` 4.1.1 forks is reproduced exactly, in
   its order - `java -XX:TieredStopAtLevel=1 <debug agent> -cp
   /app/target/classes:<deps> <main class>`, with the project directory as the
   working directory and the environment unchanged - and `test/` compares the
   two launches of all twelve services property by property. The dependency
   list comes from `dependency:build-classpath`, rebuilt on every build-file
   change. The main class is found the way `spring-boot:run` finds it, from
   the compiled classes: exactly one class annotated `@SpringBootApplication`
   with a `public static void main(String[])`. Zero or several, and it refuses
   to start and names what it found, rather than guess.

**DevTools restarts on a trigger file, not on class files.** Left to itself,
DevTools restarts on any change in `target/classes`, and it cannot tell a
finished compile from one still writing. `compose.dev.yml` sets
`SPRING_DEVTOOLS_RESTART_TRIGGER_FILE`, so DevTools ignores all of that until
the loop touches `target/classes/.reloadtrigger`, which it does once per
successful compile. One save, one restart, on a complete set of classes.

**Both halves poll rather than using inotify, and that is not laziness.** Docker
Desktop's bind mounts on macOS and Windows do not propagate inotify events from
the host, so `inotifywait` and anything built on Java's `WatchService` never
fire - they do not error, they simply see nothing, which is the worst way for a
watcher to fail. Spring Boot DevTools has always polled, which is why the
second half works at all.

**Nothing depends on the clocks agreeing.** The Docker VM's clock drifts from
the host's - WSL2 notoriously, after the laptop sleeps. The old `find -newer`
stamp compared the two and silently skipped edits while the VM ran ahead; the
fingerprints only ever compare with themselves. javac has the same weakness in
its staleness check, so every compile is a full module rebuild
(`-DlastModGranularityMs=-86400000`), which takes seconds for modules this
size.

**Resources ride the same path as source**, because `mvn compile` runs
`process-resources` - so an edited `application.properties` is copied into
`target/classes` and picked up by the same restart. A resource you delete or
rename is removed from `target/classes` too; the resources plugin itself never
deletes anything.

`spring-boot-devtools` is in all twelve poms as `<optional>true</optional>`. It
is inert in production regardless: DevTools disables itself when it detects it
is running from a fully packaged jar, which is how every deployed image starts.

### Why mvnd

Every build `dev-reload.sh` runs goes through **mvnd**, the Maven Daemon, which
`Dockerfile.dev` installs. A cold `mvn` spends most of its time booting a JVM
and re-checking the dependency tree for a module with three source files; mvnd
keeps that JVM warm between invocations.

The install is deliberately **not fatal**. mvnd's release asset naming has moved
around between versions, so if the download fails the image still builds and
`dev-reload.sh` falls back to `sh ./mvnw`. It logs which one it picked, so check
there if the loop feels slow:

    docker logs homecrew-user-service | grep 'compiler:'

Three mvnd flags are load-bearing, all set in `dev-reload.sh`:
`mvnd.daemonStorage` is moved to `/tmp`, because it defaults to
`~/.m2/mvnd/registry/<version>` and `~/.m2` is shared by all twelve containers - they would otherwise share one
daemon registry and try to reach sockets that do not exist in their own
namespace. `mvnd.idleTimeout=15m` lets the services you are not editing drop
their daemon instead of each holding a JVM for the default three hours. And
`mvnd.maxHeapSize=320m` caps it, because the daemon is a second persistent JVM
in a 1g container. The daemon also gets the lock setting described next, in
`JAVA_TOOL_OPTIONS`. After a build-file change the daemon is stopped before the
build: it caches each project's resolved dependencies, and not every pom edit
invalidates that cache.

### The shared Maven cache

All twelve containers share **one Maven repository, in a Docker volume**
(`homecrew-maven-repo`, mounted at `/root/.m2`), not your `~/.m2`. They used to
bind-mount the host's, where twelve cold builds, twelve daemons and your IDE all
wrote one local repository - and Maven 3.9's default lock only coordinates
threads inside one JVM, so concurrent builds of the same artifacts raced each
other. Now:

- **Cross-process locking is on.** Every Maven invocation runs with
  `aether.syncContext.named.factory=file-lock` and `nameMapper=file-gav`, with
  lock files under `/root/.m2/repository/.locks`. That works because the volume
  is one ext4 filesystem inside one kernel - the Docker VM's - which a Windows
  or macOS bind mount is not.
- **And it actually excludes.** On Linux, resolver 1.9's file locks unlink each
  lock file the moment they open it, so the next process locks a *different*
  file of the same name and nobody ever waits. `-Daether.named.file-lock.deleteLockFiles=false`
  turns that off. It is read once, when the JVM loads the lock class, so it is
  on the JVM's own command line: `MAVEN_OPTS` for `./mvnw`, and for the mvnd
  daemon `JAVA_TOOL_OPTIONS` in the environment of the mvnd command that starts
  it. mvnd 1.0.2 drops the two routes it documents: `mvnd.jvmArgs` is replaced
  by the service's `.mvn/jvm.config`, and `JDK_JAVA_OPTIONS` by mvnd's own
  `--add-opens` list. The application's own `java` never gets it.
- **The wrapper's Maven is installed once, safely.** `./mvnw` downloads Maven
  itself the first time, outside any resolver lock, and used to copy it into
  place file by file - so a second container could run a half-copied Maven.
  `dev-reload.sh` installs it under `flock`, unpacked on the volume so the final
  move is an atomic rename, and clears out anything incomplete a killed attempt
  left behind.
- **It outlives `./dev down -v`.** The volume is declared external, so emptying
  the databases does not cost you a cold download of every dependency. Remove it
  on purpose with `docker volume rm homecrew-maven-repo`. It does not survive
  `docker system prune -a --volumes` or Docker Desktop's "Clean / Purge data".
- **It is separate from your IDE's.** The containers no longer see your
  `~/.m2/settings.xml` (no service needs one today - every parent is
  `spring-boot-starter-parent` from Maven Central), and your IDE and host builds
  keep their own repository. The first start after this change downloads
  everything once into the volume.

**Your IDE's compiler does not reach the container, on purpose.** Each service
container compiles into its own `target/` - a named volume mounted over
`/app/target` - not the one in your checkout. Sharing it meant two compilers
writing one `target/classes`: the VS Code Java extension builds into it on the
host, so one save restarted the service twice, and anything that made the IDE
rebuild the workspace (opening it, a pull, a pom change) restarted every service
at once. A host `./mvnw clean verify`, which the pre-push hook runs, also
deleted the classes out from under the running application. The container's
own compile is now the only path in, and the host's `target/` is yours to build
into.

### Debugging

Every JVM listens for a debugger on container port 5005; the host port is what
differs, and all of them are bound to **127.0.0.1** only. Attach to
`127.0.0.1:<port>` - not `localhost`, which Windows resolves to `::1` first:

| Service | App port | Debug port |
|---|---|---|
| service-discovery | 8761 | 5005 |
| config-server | 8888 | 5006 |
| api-gateway | 8080 | 5007 |
| auth-service | 8082 | 5008 |
| user-service | 8081 | 5009 |
| admin-service | 8083 | 5010 |
| booking-service | 8084 | 5011 |
| worker-service | 8085 | 5012 |
| notification-service | 8086 | 5013 |
| payment-service | 8087 | 5014 |
| xp-service | 8088 | 5015 |
| assignment-service | 8089 | 5016 |

DevTools restarts happen inside the same JVM, so an attached debugger survives
them. A build-file change starts a new JVM, which ends the session; reattach.

Every port the dev stack publishes - postgres, kafka, the services, the
debuggers, webapp - is bound to 127.0.0.1. The base file publishes on all
interfaces, which on a laptop meant anyone on the same network could reach
postgres with its public default password, config-server's `/decrypt`, and
twelve JDWP ports, which are remote code execution without a password. Inside
the Docker network the containers still reach one another by service name, as
before.

### Memory

Twelve watched services at `DEV_SERVICE_MEM` (1g by default), webapp at
`WEBAPP_DEV_MEM` (also 1g), plus postgres and kafka is **14g of ceiling**.
Those are limits rather than reservations, but the Docker VM gets only part of
your RAM - on Windows, half of it unless `.wslconfig` says otherwise. Either
raise the VM's memory (see [On Windows](#on-windows)), lower the ceiling in
`.env`:

    DEV_SERVICE_MEM=768m

or start only what you are working on: `./dev up user-service`.

Each container runs two JVMs - the application, and an mvnd daemon once it has
compiled at least once. The daemon is capped at `-Xmx320m` and times out after
15 minutes idle, so services you are not editing settle back down to one.

### Tuning

These go in `.env`; compose passes each one into every Java container.

| Setting | Default | What it does |
|---|---|---|
| `DEV_RELOAD_INTERVAL` | 2 | seconds between polls of the checkout |
| `DEV_COMPILER` | auto | `mvnd` or `mvnw` to pin the build tool instead of probing |
| `DEV_BOOT_TIMEOUT` | 300 | seconds a JVM gets to start answering before it is replaced |
| `DEV_STOP_TIMEOUT` | 35 | seconds a JVM gets to shut down before SIGKILL |
| `DEV_OPTIMIZED_LAUNCH` | true | `false` drops `-XX:TieredStopAtLevel=1`, as `spring-boot.run.optimizedLaunch` did |
| `DEV_MAVEN_EXTRA_ARGS` | - | appended to every Maven invocation, e.g. `-X` to debug the build |

The default poll interval picks a single save up within two seconds, and a
burst of saves collapses into one build: the loop waits for the tree to settle,
and takes its fingerprints *before* compiling, so nothing saved during a build
is lost. Going below 1 buys nothing - the compile is the slow part, not the
polling.

One setting is per service rather than global: `DEV_MAIN_CLASS`, for a
checkout with zero or several `@SpringBootApplication` classes. Add it to that
service's `environment` in `compose.dev.yml`. A line in `.env` does nothing - it
is deliberately not passed through, because one value cannot suit twelve
services.

### Things worth knowing

- **The first `./dev up` is slow.** Every container resolves its dependency tree
  and compiles from cold. The downloads happen once, into the shared cache, and
  concurrent builds of the same artifacts wait for each other rather than race.
- **`./dev up` returns before the services are serving.** `--wait` covers the
  containers with healthchecks (postgres, kafka, service-discovery,
  config-server); the other eleven are merely running while they start. A
  service is serving once its log shows `[dev-reload] app-ready`.
- **`service-discovery` and `config-server` get a long health `start_period`**
  in the dev override - 600s and 240s, against 20s and 60s in the base file.
  Everything else is gated behind them by `depends_on: service_healthy`, and a
  cold Maven build does not fit in the production budget - they would be marked
  unhealthy and the other ten would never start. service-discovery gets the
  longest because it builds first, while the Maven cache is still empty.
- **A compile error does not take a service down.** The trigger file is only
  touched after a compile succeeds, so DevTools never restarts onto a failed
  one - and because the compiler deletes the previous build's classes before it
  starts, the last good ones are put back afterwards. You get an error in
  `./dev logs`, not an outage. One gap remains: while javac runs, the classes
  are briefly absent, and a class the application first loads in exactly that
  window stays unloadable until the next restart.
  The same holds for a `pom.xml` that does not resolve: the old JVM keeps
  serving until a build succeeds. And for the very first build: a checkout that
  does not build leaves the container up and waiting, rather than exiting and
  being restarted straight back into the same failure.
- **A build that fails for a passing reason is retried** - a network blip on a
  cold start, a lock wait that ran out - three times, 30s, 60s and 120s apart.
  A genuine compile error just fails again until you fix it.
- **A save while a service is starting waits for it.** DevTools only starts
  watching late in startup, so a change compiled before then used to be lost.
  The loop now waits until the application answers on its own port
  (`reload-deferred` in the log) and then reloads once.
- **If the application dies anyway** - a context that fails to refresh, an OOM,
  a port clash, or config-server down for longer than the config client's retry
  (about 75s) - the container stays up and restarts it, waiting 5s, then 10, 20,
  40 and 80. A cause that clears in that time heals on its own; one that
  outlasts all five attempts is a real failure, and the log says to fix the code
  and save, which starts it again with a fresh set of attempts.
- **A DevTools restart that fails is caught too.** A save that compiles but
  breaks the context - a bean that cannot be wired - leaves the JVM alive with
  no application in it, which looks healthy from outside. The loop notices
  (`reload-failed` in the log) and compiles your next save straight away, which
  is the change DevTools is waiting for. If nothing arrives within
  `DEV_BOOT_TIMEOUT`, the JVM is replaced, out of the same budget as a crash.
- **Tests are not compiled in the container.** Nothing in the loop needs them;
  the pre-commit and pre-push hooks and CI still run them.
- **The git-hooks install is skipped inside the container.** `pom-plugins.xml`
  runs `git config core.hooksPath .githooks` at the validate phase;
  `-Dhooks.install.skip=true` turns that off, because those hooks belong to your
  clone, and `.git` is on the bind mount - a container installing them would be
  reconfiguring your repository. (`Dockerfile.dev` still installs git, because
  the build assumes it is on PATH.)
- **Spotless and Checkstyle are skipped inside the container too.** Both bind to
  the validate phase, which `compile` runs first, so without
  `-Dspotless.check.skip=true -Dcheckstyle.skip=true` the full formatting gate
  would run in front of every save. A save is the wrong moment to ask *is this
  fit to commit*, because code mid-thought is routinely mid-format. Nothing is
  lost by moving the gate: the pre-commit hook, the pre-push `clean verify` and
  CI all still run it, on the host, where `spotless:apply` is there to fix what
  they find.
- **Running `./mvnw` in a service repository while the stack is up is fine.**
  The container builds into its own `target/` volume and its own Maven cache,
  so a host build - the pre-push hook's `clean verify` included - no longer
  touches what the running service is loaded from.
- **The stack comes back when Docker starts.** Every service inherits
  `restart: unless-stopped` from the base file, so one you did not stop with
  `./dev down` is revived the next time Docker Desktop starts.
- **Kafka cannot be used from the host.** Port 9092 is published, but the
  broker advertises `kafka:9092`, a name only the containers can resolve.

### Verifying the dev setup

`test/` holds a harness that checks all of the above against a real Docker
install - the concurrency of the shared cache from cold, the launch against
`spring-boot:run` for all twelve services, reload semantics, the ports, and
`dev`/`dev.ps1` parity. See [test/README.md](test/README.md).

## Topology

| Service | Port | Image | Waits for |
|---|---|---|---|
| postgres | 5432 | `postgres:18` | - |
| kafka | 9092 | `apache/kafka:4.1.0` | - |
| service-discovery | 8761 | `mthanuj/homecrew-service-discovery:dev` | postgres, kafka |
| config-server | 8888 | `mthanuj/homecrew-config-server:dev` | service-discovery |
| api-gateway | 8080 | `mthanuj/homecrew-api-gateway:dev` | config-server, service-discovery |
| user-service | 8081 | `mthanuj/homecrew-user-service:dev` | + postgres |
| auth-service | 8082 | `mthanuj/homecrew-auth-service:dev` | + postgres |
| admin-service | 8083 | `mthanuj/homecrew-admin-service:dev` | + postgres, kafka |
| booking-service | 8084 | `mthanuj/homecrew-booking-service:dev` | + postgres, kafka |
| worker-service | 8085 | `mthanuj/homecrew-worker-service:dev` | + postgres, kafka |
| notification-service | 8086 | `mthanuj/homecrew-notification-service:dev` | + kafka |
| payment-service | 8087 | `mthanuj/homecrew-payment-service:dev` | + postgres, kafka |
| xp-service | 8088 | `mthanuj/homecrew-xp-service:dev` | + postgres, kafka |
| assignment-service | 8089 | `mthanuj/homecrew-assignment-service:dev` | + kafka |
| webapp | 4200 | `mthanuj/homecrew-webapp:dev` | api-gateway (started) |

In the dev stack every published port is bound to 127.0.0.1 - see
[Debugging](#debugging).

Everything is on one user-defined bridge network named `homecrew`, and every
service is memory-capped - the target is a small single host, so the JVMs run
with `-Xmx128m` to `-Xmx192m` and the serial collector.

## Databases

`postgres/init/01-create-databases.sql` runs once, on first boot of an empty
volume, and creates:

    homecrew_auth     homecrew_user      homecrew_admin
    homecrew_booking  homecrew_worker    homecrew_payment
    homecrew_xp

Local credentials are `homecrew` for user, password and default database.
They are a development convenience, documented as such, and are not used
anywhere reachable.

There is deliberately no `homecrew_assignment`: assignment-service has no
`spring-boot-starter-data-jpa` and no datasource, so it needs no database. Its
`depends_on: postgres` was dead weight and has been removed.

One trap worth knowing: **the init script only runs on an empty volume.** Adding
a database to that file does nothing to a stack that has already been started.
Create it by hand, or empty the volume and lose the data - locally, `./dev down -v`.

## Deployment

There is no `push` trigger. `.github/workflows/deploy.yml` fires only on a
`repository_dispatch` of type `service-image-updated`, sent by a service
repository's CI after it has pushed a new image.

The payload carries four keys:

    service   the compose service name, for example "user-service"
    image     the Docker Hub repository, for example "mthanuj/homecrew-user-service"
    tag       must be "dev"
    sha       the source commit, for traceability only

The workflow validates all three of the first before it touches the host, and
fails closed:

- `service` must be in its allow-list of the twelve compose services
- `tag` must be exactly `dev` - there is no production path here
- `image` must match `mthanuj/homecrew-*`

It then copies `docker-compose.yml` to the host over SSH, pulls, and restarts.
`concurrency` serialises deployments so two services landing at once cannot
interleave.

Before copying the compose file, the workflow writes `/opt/homecrew/.env` from
GitHub secrets, piped over stdin and renamed into place atomically. It is never
scp'd, never passed as an ssh argument, and never printed. Rotation is therefore
"change the secret and dispatch any service" rather than "ssh in and edit a file
nobody documented".

Required secrets, by name. The five deployment ones are repository-scoped; the
rest are on the `dev` environment, which the job declares:

    HETZNER_SSH_PRIVATE_KEY    HETZNER_HOST    HETZNER_USER
    DOCKERHUB_USERNAME         DOCKERHUB_TOKEN

    POSTGRES_USER    POSTGRES_PASSWORD    POSTGRES_DB
    CONFIG_GIT_USERNAME    CONFIG_GIT_TOKEN    (required - the config
                                                repository is private)

    ENCRYPT_KEY              (required - config-server decrypts the {cipher}
                              values in home-crew-config before serving them)
    CONFIG_CLIENT_PASSWORD   (required - 8888 now needs HTTP basic, and every
                              service presents this)

Adding a thirteenth service means three edits here: a compose service, an
entry in the deploy allow-list, and a database in the init script if it needs
one.

## Quality gates

This repository is deliberately outside the shared git hooks. There is no
Maven build here, so the Spotless, Checkstyle, SpotBugs and JaCoCo gates that
guard the twelve service repositories have nothing to bind to, and
`apply.py`'s `HOOKS_OPT_OUT` skips it.

The practical consequence is worth stating plainly: **nothing checks this
repository before a push.** No formatter, no secret scan, no branch-name
check. Review the diff yourself.

`.editorconfig` and `.gitattributes` are still generated from
`_standards/templates/`. Everything else here is hand-written.

## Contributing

See [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Related repositories

HomeCrew is fifteen repositories. The ones you are most likely to need next:

| Repository | What it is | Port |
|---|---|---|
| [home-crew-infrastructure](https://github.com/HomeCrews/home-crew-infrastructure) | docker compose topology and the Hetzner deploy | - |
| [home-crew-config](https://github.com/HomeCrews/home-crew-config) | shared configuration, served by config-server | - |
| [home-crew-service-discovery](https://github.com/HomeCrews/home-crew-service-discovery) | Eureka registry | 8761 |
| [home-crew-config-server](https://github.com/HomeCrews/home-crew-config-server) | Spring Cloud Config server | 8888 |
| [home-crew-api-gateway](https://github.com/HomeCrews/home-crew-api-gateway) | single entry point, routes to everything below | 8080 |
| [home-crew-user-service](https://github.com/HomeCrews/home-crew-user-service) | `/users/**` | 8081 |
| [home-crew-auth-service](https://github.com/HomeCrews/home-crew-auth-service) | `/auth/**` | 8082 |
| [home-crew-admin-service](https://github.com/HomeCrews/home-crew-admin-service) | `/admin/**` | 8083 |
| [home-crew-booking-service](https://github.com/HomeCrews/home-crew-booking-service) | `/bookings/**` | 8084 |
| [home-crew-worker-service](https://github.com/HomeCrews/home-crew-worker-service) | `/workers/**` | 8085 |
| [home-crew-notification-service](https://github.com/HomeCrews/home-crew-notification-service) | `/notifications/**` | 8086 |
| [home-crew-payment-service](https://github.com/HomeCrews/home-crew-payment-service) | `/payments/**` | 8087 |
| [home-crew-xp-service](https://github.com/HomeCrews/home-crew-xp-service) | `/xp/**` | 8088 |
| [home-crew-assignment-service](https://github.com/HomeCrews/home-crew-assignment-service) | `/assignments/**` | 8089 |
| [home-crew-webapp](https://github.com/HomeCrews/home-crew-webapp) | web frontend, Angular | 4200 |

## Licence

MIT. See [LICENSE](LICENSE).
