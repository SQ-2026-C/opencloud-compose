# Split deployment: OpenCloud as 6 components

By default OpenCloud runs all of its ~40 services inside **one container / one process**
(`opencloud server`). This overlay deploys the same image as **6 containers**, each running
a subset of the services selected with `OC_RUN_SERVICES`.

| Container     | Role                         | Services |
|---------------|------------------------------|----------|
| `oc-nats`     | Messaging backbone           | nats (service registry, event bus, KV/cache stores) |
| `oc-identity` | Identity & user management   | idm, idp, users, groups, auth-basic, auth-machine, auth-app, auth-service, auth-guest¹, graph |
| `oc-core`     | CS3/reva core                | gateway, app-registry, app-provider, sharing, ocm, settings |
| `oc-storage`  | Storage providers            | storage-users, storage-system, storage-shares, storage-publiclink |
| `oc-async`    | Event-driven workers         | postprocessing, search, thumbnails, activitylog, clientlog, eventhistory, userlog (+ `START_ADDITIONAL_SERVICES`) |
| `opencloud`   | Edge / API layer             | proxy, web, frontend, ocs, webdav, webfinger, sse |

¹ only started when `OC_ENABLE_GUEST_LINKS=true`.

```
            Traefik :443
                 │
          ┌──────▼──────┐
          │  opencloud  │  proxy → web, frontend, ocs, webdav, ...
          └──┬───┬───┬──┘
     gRPC/HTTP via registry lookups
   ┌─────────┼───┼───┼──────────┐
┌──▼───────┐ ┌▼───▼─┐ ┌▼────────┐ ┌──────────┐
│oc-identity│ │oc-core│ │oc-storage│ │ oc-async │
└──┬────────┘ └──┬───┘ └───┬─────┘ └────┬─────┘
   └─────────────┴─────────┴────────────┘
          registry · events · stores
               ┌────▼────┐
               │ oc-nats │
               └─────────┘
```

## How it works

- **Service discovery**: every service registers itself in the NATS-JS-KV registry on
  `oc-nats:9233` (`MICRO_REGISTRY_ADDRESS`) and looks others up by name
  (e.g. `eu.opencloud.api.gateway`), so callers don't need hard-coded hosts.
- **Bind addresses**: services default to `127.0.0.1`; the overlay sets every
  `*_GRPC_ADDR` / `*_HTTP_ADDR` to `0.0.0.0:<port>`, so the registry advertises the
  container IP.
- **Events and caches**: `OC_EVENTS_ENDPOINT`, `OC_CACHE_STORE_NODES` and
  `OC_PERSISTENT_STORE_NODES` all point to `oc-nats:9233`.
- **A few URLs that default to localhost** are set explicitly: storage data servers
  (`oc-storage`), the OCM data server (`oc-core`) and the thumbnail generator (`oc-async`).
- **Shared config and data**: `oc-nats` runs `opencloud init` once, and every container
  mounts the same `/etc/opencloud` (shared secrets) and `/var/lib/opencloud`.
  Each service writes to its own subfolder.
- **Startup order**: `oc-nats` has a healthcheck, and the other containers wait for it. The
  runtime in each container also waits for NATS and the gateway before starting its services.
- **idm and LDAP**: idm's plain LDAP listener may only bind to loopback, so all LDAP
  clients (users, groups, auth-basic, idp, graph) run in `oc-identity` next to it.

## Usage

`.env` (`COMPOSE_PATH_SEPARATOR=;`):

```
# built from local sources
COMPOSE_FILE=docker-compose.yml;traefik/opencloud.yml;local-src/opencloud.yml;split/split.yml;split/local-src.yml
# or with the published image
COMPOSE_FILE=docker-compose.yml;traefik/opencloud.yml;split/split.yml
```

```
docker compose up -d                                   # (--build after source changes)
docker compose ps
docker compose exec oc-core opencloud list             # services running in a container
docker compose logs -f oc-storage
```

Going back to a single container: restore the old `COMPOSE_FILE` line and run
`docker compose up -d --remove-orphans`.

## Limitations

- The `collaboration` service (Collabora/Euro-Office) is not included; use
  `weboffice/*.yml` as before.
- Each container is a full Go process, so the split uses more memory than the
  single container.
