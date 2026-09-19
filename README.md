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

`./dev` wraps the compose invocations for the cases that come up daily. It
needs nothing but this repository unless you ask it to build from source.

| Command | What it does |
|---|---|
| `./dev infra` | postgres, service-discovery, config-server only |
| `./dev up` | the whole stack, from the published `:dev` images |
| `./dev up --build` | the whole stack, from your local checkouts |
| `./dev build [svc...]` | package and image a service without starting it |
| `./dev down` | stop everything, keep the volumes |
| `./dev reset` | stop everything and delete the volumes |
| `./dev ps` / `logs` / `status` | inspect what is running |

The inner loop is `./dev infra`, then run the one service you are editing from
its own repository on the **default** profile:

    ./dev infra
    cd ../home-crew-user-service && ./mvnw spring-boot:run

config-server (8888), Eureka (8761) and Postgres (5432) are all published to
localhost, which is exactly what the default profile in
[home-crew-config](https://github.com/HomeCrews/home-crew-config) points at. Do
not set `SPRING_PROFILES_ACTIVE=docker` for a service run this way - the docker
profile points at compose hostnames, which do not resolve from your machine.

`./dev infra` deliberately leaves **kafka** out: no service has `spring-kafka`
on its classpath yet, so the broker costs 512m and a 40s start period and
nothing consumes it. Add it with `./dev infra kafka` when that changes - and
note that `KAFKA_ADVERTISED_LISTENERS` is `kafka:9092`, so a client on the host
is told to connect to a name only containers can resolve. Fixing that properly
means a second listener advertised as `localhost`, which touches both this file
and `application-docker.yml` in home-crew-config.

`./dev up --build` compiles first, because the Dockerfiles are single-stage and
begin at `COPY target/*.jar` - `docker compose build` alone would match nothing.
It expects the sibling repositories at `../home-crew-<service>`.

The raw commands still work, and are what the deploy uses:

    docker compose up -d
    docker compose ps

`.env` is gitignored and is **required**, not optional: `POSTGRES_PASSWORD` is
declared `${VAR:?}` in the compose file, so `docker compose config` exits
non-zero without one. That is deliberate - the deploy runs
`docker compose config --quiet`, and until this was a hard failure it passed
happily against a host with no `.env` at all.

`CONFIG_GIT_USERNAME` and `CONFIG_GIT_TOKEN` are **required**:
[home-crew-config](https://github.com/HomeCrews/home-crew-config) is private, and
JGit registers no CredentialsProvider when the username is empty - the clone
then fails with "Authentication is required but no CredentialsProvider has been
registered", which reads like a missing library rather than a missing password.
A read-only token is enough.

They are declared `${VAR?...}` in the compose file, so they may be empty (if the
config repo is ever made public) but may not be absent.

Startup is ordered by healthchecks, not by `depends_on` alone: postgres and
kafka come up first, then service-discovery, then config-server, then
everything else. Wait for `healthy` rather than `running` - a container that
is running but not yet healthy will refuse connections.

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
