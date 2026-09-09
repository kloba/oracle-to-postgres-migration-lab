# Disposable PostgreSQL 16 validator image for the Copilot migration team.
#
# Contoso Store -- Oracle to Azure Database for PostgreSQL migration lab.
# This image is the local, offline analogue of the conversion tool's Stage 4
# ("the compiler is the arbiter") and Stage 5 (plpgsql_check deep validation);
# see docs/architecture.md. It is never deployed to Azure and never talks to a
# network -- tools/migration_team/validator.py runs one throwaway container per
# candidate with --network none and no host mounts.
#
# Build it explicitly (validator.py fails closed if the image is absent -- it
# never pulls or builds implicitly):
#
#   docker build -f tools/migration_team/Dockerfile \
#     -t o2p-migration-validator:pg16 tools/migration_team
#
# postgresql-16-plpgsql-check backs the deep-validation phase; it is loaded via
# `-c shared_preload_libraries=plpgsql_check` on `docker run` (validator.py),
# matching the live server's shared_preload_libraries (docs/lab-status.md).
# postgresql-16-orafce is installed when the PGDG repo carries it, so converted
# candidates that call oracle.* compatibility routines compile; a missing orafce
# package is not fatal (the extension is created best-effort at run time).
FROM postgres:16-bookworm

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-16-plpgsql-check; \
    # orafce is best-effort: keep building even if the package is unavailable.
    if apt-get install -y --no-install-recommends postgresql-16-orafce; then \
        echo "orafce: installed"; \
    else \
        echo "orafce: package unavailable, continuing without it"; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Fail fast at build time if the deep-check library never got installed, rather
# than producing an image that silently skips Stage 5 at run time.
RUN test -f "$(pg_config --pkglibdir)/plpgsql_check.so"
