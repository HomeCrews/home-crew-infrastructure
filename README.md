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

    cp .env.example .env
    ./dev up

Three commands, and that is the whole interface:

| Command | What it does |
|---|---|
| `./dev up` | start everything, hot reloading |
| `./dev down` | stop everything, keeping the volumes |
| `./dev logs [svc...]` | follow logs |

**There is no non-watch mode.** Every service runs from its sibling checkout at
`../home-crew-<service>`, compiled inside its own container. Your machine needs
docker and a `.env`; it does **not** need a JDK or Maven, because the containers
do the compiling.

`.env` is gitignored and is **required**, not optional: `POSTGRES_PASSWORD` is
declared `${VAR:?}` in the compose file, so `docker compose config` exits
non-zero without one. That is deliberate - the deploy runs
`docker compose config --quiet`, and until this was a hard failure it passed
happily against a host with no `.env` at all.

To wipe the databases and Kafka's log, which `./dev` deliberately will not do
for you: `docker compose down -v`.

## Hot reload

Save a file. That service picks the change up; nothing else is touched, and no
image is rebuilt.

| You change | What happens | Roughly |
|---|---|---|
| anything under `src/main` - `.java`, `application.properties`, any resource | compile, then DevTools restarts the context in-process | 3-5s |
| `pom.xml` or `.mvn/**` | compile, then the application process is stopped and relaunched | 30-60s |
| anything under `src/test` | nothing, deliberately - a test edit should not bounce the running service | - |

A dependency change is the one case that cannot be hot-reloaded:
`spring-boot:run` fixed its classpath when it launched, so the process has to
go. `dev-reload.sh` owns the application as a child process rather than
`exec`ing it, which is what makes that restart possible.

### Why mvnd

That 3-5s assumes **mvnd**, the Maven Daemon, which `Dockerfile.dev` installs.
Without it the same edit costs **8-15s**, and the extra ten seconds are not
compilation - a cold `mvn` spends most of its time booting a JVM and re-checking
the dependency tree for a module with three source files. mvnd keeps that JVM
warm between invocations.

It is used for the compile loop only. `spring-boot:run` always goes through
`./mvnw`: mvnd is built for build goals that finish, and parking a process that
runs until you stop the container on one of its daemons is not what it is for.

The install is deliberately **not fatal**. mvnd's release asset naming has moved
around between versions, so if the download fails the image still builds and
`dev-reload.sh` falls back to `./mvnw`. It logs which one it picked on the first
line, so check there if the loop feels slow:

    ./dev logs user-service | grep 'compiling with'

Three mvnd flags are load-bearing, all set in `dev-reload.sh`:
`mvnd.daemonStorage` is moved to `/tmp` because it defaults to `~/.m2/mvnd` and
`~/.m2` is shared by all twelve containers - they would otherwise share one
daemon registry and try to reach sockets that do not exist in their own
namespace. `mvnd.idleTimeout=15m` lets the ten services you are not editing drop
their daemon instead of each holding a JVM for the default three hours. And
`mvnd.jvmArgs` caps it, because the daemon is a third persistent JVM in a 1g
container.

**The fastest option is still your IDE.** If IntelliJ compiles on save, the
container's compile step disappears from the critical path entirely and you are
left with just DevTools' poll and the context restart - around 3s, with no mvnd
involved. The catch is the one in "Things worth knowing" below: two compilers
writing one `target/classes`.

What makes the rest work is that **no container holds a copy of your code**.
`compose.dev.yml` puts every service on `Dockerfile.dev` - a bare JDK, no
application - and bind-mounts its checkout at `/app`. `dev-reload.sh` then runs
two things inside each container:

1. a loop that polls the checkout and compiles, and
2. `mvnw spring-boot:run`, whose DevTools restarts the context when
   `target/classes` changes underneath it.

Resources ride the same path as source, because `mvn compile` runs
`process-resources` - so an edited `application.properties` is copied into
`target/classes` and DevTools treats it like any other classpath change. It is
a genuine context restart, which is what a property change needs in order to
take effect.

So the compile happens inside the container, on the same files your editor is
writing. The image is built once and never again during the loop; `./dev up`
always passes `--build`, so a change to `Dockerfile.dev` is picked up too.

**Both halves poll rather than using inotify, and that is not laziness.** Docker
Desktop's bind mounts on macOS and Windows do not propagate inotify events from
the host, so `inotifywait` and anything built on Java's `WatchService` never
fire - they do not error, they simply see nothing, which is the worst way for a
watcher to fail. `find -newer` against a stamp file costs one stat per file
every two seconds and works everywhere. Spring Boot DevTools has always polled,
which is why the second half works at all.

`spring-boot-devtools` is in all twelve poms as `<optional>true</optional>`. It
is inert in production regardless: DevTools disables itself when it detects it
is running from a fully packaged jar, which is how every deployed image starts.

### Memory

Twelve watched services at `DEV_SERVICE_MEM` (1g by default) plus postgres and
kafka is **13g of ceiling**. Those are limits rather than reservations, so real
usage is more like 400-700m per service, but Docker Desktop's VM defaults to
roughly half your host RAM. On a 16g machine, either raise the VM to 12g in
Docker Desktop's settings or lower the ceiling in `.env`:

    DEV_SERVICE_MEM=768m

Each container is running three JVMs - the Maven that launched the application,
the forked application itself, and an mvnd daemon once it has compiled at least
once - which is why the production figure of 192m is nowhere near enough. The
daemon is capped at `-Xmx320m` and times out after 15 minutes idle, so services
you are not editing settle back down to two.

### Tuning the watcher

`DEV_RELOAD_INTERVAL` in `.env` is how often `dev-reload.sh` checks the mount,
in seconds. The default of 2 picks a single save up within two seconds, and a
burst of saves collapses into one compile: the loop is serial, so it is not
polling while a compile is in flight, and the stamp is taken *before* the
compile rather than after, so nothing saved during one is lost.

Raise it if you save in heavy bursts and would rather have fewer compiles than
faster feedback on a single save:

    DEV_RELOAD_INTERVAL=5

Going below 1 buys nothing - the compile is the slow part, not the polling.

Unlike `DEV_SERVICE_MEM`, this one has to reach the **container** rather than
just compose, so `compose.dev.yml` passes it through in every service's
`environment`. Setting it in `.env` alone would do nothing, which is the same
trap the `DB_USERNAME` comment in `docker-compose.yml` warns about.

### Things worth knowing

- **The first `./dev up` is slow.** Every container resolves its dependency tree
  and compiles from cold, twelve of them at once against one `~/.m2`. Concurrent
  Maven against a shared local repository is not something Maven loves; if a
  service falls over on the very first run, `./dev up` again and it will find
  the cache warm.
- **`service-discovery` and `config-server` get a 240s health `start_period`**
  in the dev override, against 20s in the base file. Everything else is gated
  behind them by `depends_on: service_healthy`, and a cold Maven compile does
  not fit in the production budget - they would be marked unhealthy and the
  other ten would never start.
- **A compile error does not take a service down.** `target/classes` keeps the
  last set that compiled, DevTools sees no change, and the running context is
  untouched. You get an error in `./dev logs`, not an outage. The same is true
  of a `pom.xml` that does not resolve: the restart is skipped rather than
  killing a working application to start a broken one.
- **If the application dies anyway** - a context that fails to refresh, an OOM,
  a port clash - the container stays up and says so. Fix the code and save; the
  loop builds and starts it again. You should not need `docker restart`.
- **Debuggers are on 5005 upwards**, in the order services are listed in
  `compose.dev.yml`. DevTools restarts happen inside the same JVM, so an
  attached debugger survives them.
- **Do not run `./mvnw` in a service repository while the stack is up.** The
  container is compiling into that same `target/` over the mount.
- **On Linux hosts**, the containers' Maven runs as root and will leave
  root-owned files in the mounted `target/` and `~/.m2`. macOS and Windows are
  fine, because Docker Desktop maps the ownership.

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
Create it by hand, or `docker compose down -v` and lose the data.

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
| [home-crew-webapp](https://github.com/HomeCrews/home-crew-webapp) | web frontend, not yet scaffolded | - |

## Licence

MIT. See [LICENSE](LICENSE).
