# Aviator Verify preview image for Immich.
#
# This file is pasted into Aviator's UI, which has no build context and rejects
# COPY/ADD. Aviator never runs this container normally, so there is deliberately
# no CMD and no ENTRYPOINT -- it boots a sandbox from the image, cleans /code
# with `git reset --hard && git clean -fd` (note: no -x), and then runs
# .aviator/scripts/preview-setup.sh.
#
# Verify's browser runs on Aviator's servers, not in here, so this image
# contains no Chrome and no Playwright.
#
# Base is the exact digest pinned by server/Dockerfile.dev:2. It already ships
# node 24 + npm, ffmpeg, perl, git and psql -- and, critically, a populated
# /build/geodata. MetadataService.onBootstrap reads
# /build/geodata/geodata-date.txt and rethrows if it is missing
# (server/src/services/metadata.service.ts:139-173), which kills the
# microservices worker, which takes the API worker down with it
# (server/src/main.ts:152-161). Getting that directory for free is the single
# biggest reason to start from this base rather than a plain node image.
FROM ghcr.io/immich-app/base-server-dev@sha256:83c9ff3f7390111596a2dcd24a746c3f8618d58259dbc7aae36618d153462f18

# e2b forces PATH to
#   /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# for every RUN step and at launch. `ENV PATH=` does not override it, so any
# tool outside those six directories is invoked by absolute path below, and the
# few the setup script needs get symlinked into /usr/local/bin.

# git + git-lfs: Aviator shells out to git inside /code.
# postgresql-17 + pgvector 0.8.x: pgvector satisfies immich's
#   VECTOR_VERSION_RANGE '>=0.5 <1' (server/src/constants.ts:25) and postgres 17
#   satisfies POSTGRES_VERSION_RANGE '>=14.0.0', so we can skip building
#   VectorChord entirely. The PGDG apt repo is already configured in the base.
# redis-server: bullmq queues (server/src/repositories/config.repository.ts:203).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git \
      git-lfs \
      curl \
      ca-certificates \
      postgresql-17 \
      postgresql-17-pgvector \
      redis-server && \
    rm -rf /var/lib/apt/lists/*

# Postgres server binaries live in /usr/lib/postgresql/17/bin, which is NOT in
# e2b's forced PATH. Without these symlinks the setup script dies with
# "exit status 127".
RUN for bin in initdb postgres pg_ctl pg_isready; do \
      ln -sf "/usr/lib/postgresql/17/bin/${bin}" "/usr/local/bin/${bin}"; \
    done

# pnpm at the version package.json:11 pins. npm's global prefix is /usr/local,
# so this lands in /usr/local/bin, which IS in the forced PATH.
RUN npm install -g pnpm@11.13.1

# The pnpm content-addressable store lives OUTSIDE /code so the launch clean can
# never touch it, and it can never go stale because it is addressed by integrity
# hash. Configured through the global npmrc rather than ENV, because ENV is not
# a reliable channel into e2b RUN steps.
RUN mkdir -p /pnpm-store && \
    printf 'store-dir=/pnpm-store\nfetch-retries=5\n' >> /usr/local/etc/npmrc

# Database cluster, also outside /code. Only the empty cluster and the immich
# role/database are baked -- NOT the immich schema. Migrations run from branch
# code at every launch, which is what keeps a preview honest.
# fsync=off matches what immich's own e2e compose does for throwaway databases;
# dynamic_shared_memory_type=mmap avoids depending on the sandbox's /dev/shm size.
RUN mkdir -p /var/lib/postgresql/data /var/run/postgresql && \
    chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql && \
    su postgres -c "/usr/lib/postgresql/17/bin/initdb \
      -D /var/lib/postgresql/data \
      --auth-local=trust --auth-host=trust \
      --encoding=UTF8 --locale=C.UTF-8" && \
    printf "listen_addresses='127.0.0.1'\nfsync=off\nfull_page_writes=off\nsynchronous_commit=off\ndynamic_shared_memory_type=mmap\nshared_buffers=256MB\nmax_wal_size=2GB\n" \
      >> /var/lib/postgresql/data/postgresql.conf && \
    su postgres -c "/usr/lib/postgresql/17/bin/pg_ctl -D /var/lib/postgresql/data -w start" && \
    su postgres -c "psql -v ON_ERROR_STOP=1 -c \"ALTER USER postgres WITH PASSWORD 'postgres'\"" && \
    su postgres -c "createdb immich" && \
    su postgres -c "/usr/lib/postgresql/17/bin/pg_ctl -D /var/lib/postgresql/data -m fast -w stop"

# Upload/derivative storage, outside /code so it is not swept by git clean.
RUN mkdir -p /preview-media

# The repo connected to Aviator. --filter=blob:none and NOT --depth 1 /
# --single-branch: a shallow single-branch clone only tracks the default branch,
# so the `git fetch origin <branch>` Aviator runs later never creates the ref and
# checkout fails with "invalid reference". If this URL does not match the
# connected repo, Aviator silently deletes /code and re-clones, throwing away
# everything baked below with nothing in the logs to explain the slowdown.
RUN git clone --filter=blob:none https://github.com/aviator-ag-org/immich.git /code

RUN git config --system --add safe.directory /code

# The expensive step, baked because the destinations survive the launch clean.
#
# The root .gitignore's `**/node_modules/**` ignores the CONTENTS of every
# node_modules directory rather than the directories themselves, which reads like
# a problem for `git clean -fd` (no -x) but is not: git will not remove an
# untracked directory whose entries are all ignored, so node_modules/.pnpm -- the
# pnpm store every other workspace symlink points into -- is left alone.
# Verified directly against this image: `git reset --hard && git clean -fd` in
# /code removes zero paths and leaves the root, packages/sdk and server trees
# byte-for-byte intact.
#
# Deliberately NOT baked: server/dist, web/build, web/.svelte-kit. Those are
# gitignored too, so a baked copy would survive the clean and serve stale code
# for the branch under review. They are rebuilt from branch source at launch.
WORKDIR /code
RUN pnpm install --frozen-lockfile --filter=immich... --filter=immich-web...

# Stamp for the setup script's dependency gate. pnpm is not incremental, so the
# script reinstalls only when the lockfile hash differs from this. Baking it
# means even the very first preview launch skips a redundant install.
RUN sha256sum /code/pnpm-lock.yaml | cut -d' ' -f1 > /preview-deps-stamp

# Recorded outside /code -- inside it this file would be untracked and deleted
# by the first `git clean -fd`.
RUN git -C /code rev-parse HEAD > /preview-image-sha
