# syntax=docker/dockerfile:1
#
# Builds OpenCloud from the LOCAL source checkouts instead of pulling the Docker Hub image:
#   - main build context        -> ../opencloud   (backend, Go)
#   - named context "web-src"    -> ../web         (frontend, embedded into the binary)
# Wired up by local-src/opencloud.yml. Mirrors opencloud/opencloud/docker/Dockerfile.multiarch,
# except that the web UI is built from ../web instead of downloading a released web.tar.gz.
#
# The Windows checkouts have CRLF line endings (git core.autocrlf=true); every source stage strips
# the CRs from text files in its own copy, so Makefiles/scripts/patches work on Linux and the
# repos on disk are left untouched.

ARG NODE_IMAGE=quay.io/opencloudeu/nodejs-ci:24
ARG GO_IMAGE=quay.io/opencloudeu/golang-ci:1.26

# ---------- 1. web frontend (../web) ----------
FROM ${NODE_IMAGE} AS web
WORKDIR /web
COPY --from=web-src . .
RUN rm -rf node_modules dist \
 && (grep -rIlZ "$(printf '\r')" . || true) | xargs -0 -r sed -i 's/\r$//'
RUN --mount=type=cache,id=oc-pnpm-store,target=/pnpm-store \
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
 && pnpm config set store-dir /pnpm-store \
 && pnpm install --frozen-lockfile \
 && pnpm build \
 && cp config/config.json.dist dist/

# ---------- 2. backend node assets (idp login UI) + local web assets ----------
FROM ${NODE_IMAGE} AS generate
WORKDIR /src
COPY . .
RUN (grep -rIlZ "$(printf '\r')" . || true) | xargs -0 -r sed -i 's/\r$//'
RUN --mount=type=cache,id=oc-pnpm-store,target=/pnpm-store \
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
 && pnpm config set store-dir /pnpm-store \
 && make -C services/idp node-generate-prod
# instead of `make -C services/web node-generate-prod` (downloads a released web.tar.gz)
RUN find services/web/assets/core -mindepth 1 ! -name .keep -exec rm -rf {} +
COPY --from=web /web/dist/ services/web/assets/core/

# ---------- 3. Go binary ----------
FROM ${GO_IMAGE} AS build
ARG TARGETARCH
ARG VERSION=""
ARG STRING="local"
ARG EDITION="dev"
COPY --from=generate /src /build
WORKDIR /build
RUN --mount=type=cache,id=oc-gomod,target=/go/pkg/mod \
    --mount=type=cache,id=oc-gocache,target=/root/.cache \
    make -C opencloud release-linux-docker-${TARGETARCH:-amd64} \
        DIST=/dist VERSION="${VERSION}" EDITION="${EDITION}" STRING="${STRING}" \
 && cp /dist/binaries/opencloud-linux-${TARGETARCH:-amd64} /opencloud

# ---------- 4. runtime image (same as the official one) ----------
FROM alpine:3.24

RUN apk add --no-cache attr bash ca-certificates curl imagemagick \
                       inotify-tools libc6-compat mailcap tree patch && \
    echo 'hosts: files dns' >| /etc/nsswitch.conf

RUN addgroup -g 1000 -S opencloud-group && \
  adduser -S --ingroup opencloud-group --uid 1000 opencloud-user --home /var/lib/opencloud

RUN mkdir -p /var/lib/opencloud/web/assets/apps && \
 chown -R opencloud-user:opencloud-group /var/lib/opencloud && \
 chmod -R 751 /var/lib/opencloud && \
 mkdir -p /etc/opencloud && \
 chown -R opencloud-user:opencloud-group /etc/opencloud && \
 chmod -R 751 /etc/opencloud

VOLUME [ "/var/lib/opencloud", "/etc/opencloud" ]
WORKDIR /var/lib/opencloud
USER 1000
EXPOSE 9200/tcp

ENTRYPOINT ["/usr/bin/opencloud"]
CMD ["server"]

COPY --from=build /opencloud /usr/bin/opencloud
