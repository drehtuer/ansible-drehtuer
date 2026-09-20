# Ansible managed - roles/valheim/files/webmap/Dockerfile
#
# Builds the Valheim WebMap plugin. The output is the plugin directory
# and nothing else: this image is never the thing that runs the game,
# it is a compiler that happens to be shipped as a container.
#
# WHY A BUILD AT ALL. Upstream publishes no release and no binary - the
# repository is C# source, and the only committed DLL is the
# websocket-sharp the plugin links against. So "install the mod" means
# "compile the mod", and this file is where that happens. Everything it
# needs is pinned by the caller: the git revision through
# WEBMAP_REVISION, the game through its Steam app id, BepInEx through
# its release number.
#
# WHY STEAMCMD IS IN HERE. A BepInEx plugin compiles against the game's
# own managed assemblies (assembly_valheim.dll and friends), which are
# not redistributable and are therefore not in the mod's repository.
# They come from the dedicated server, which is a free anonymous Steam
# download. The running server container downloads its own copy into
# the data volume, and taking the assemblies from there would save this
# download - but it would also make the build depend on the server
# having already started and finished its first update, which is
# exactly the kind of ordering that turns a from-scratch provision into
# a two-pass affair. The download is roughly a gigabyte, once per
# revision bump, and buildx caches every layer above it.
#
# WHAT IT COSTS TO BE WRONG ABOUT VERSIONS. The assemblies pulled here
# are whatever Steam serves at build time, and the server container
# updates itself on its own schedule. A Valheim update that changes the
# API the plugin patches breaks the plugin, not the server - the game
# keeps running and the map stops. Rebuilding against the new
# assemblies is the fix; see doc/STATUS.adoc.

# hadolint ignore=DL3006
ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:8.0
FROM ${DOTNET_SDK_IMAGE} AS build

# Passed in by roles/valheim so that what is built is decided by the
# inventory rather than by this file.
ARG WEBMAP_REPOSITORY
ARG WEBMAP_REVISION
# Valheim Dedicated Server. Anonymous login, no account needed.
ARG VALHEIM_APPID=896660
# The BepInEx release build.sh downloads to compile against. Its
# default lives here as well as in build.sh so that a bump upstream
# does not silently change what this produces.
ARG BEPINEX_RELEASE=5.4.23.2

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# i386 is for steamcmd itself, which is a 32-bit binary however
# 64-bit the thing it downloads is. zip/unzip/python3 are build.sh's,
# for the BepInEx archive and the version it reads out of manifest.json.
RUN dpkg --add-architecture i386 \
  && apt-get update \
  && apt-get install --no-install-recommends --yes \
       ca-certificates \
       curl \
       git \
       lib32gcc-s1 \
       python3 \
       unzip \
       zip \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/steamcmd \
  && curl -sSLf \
       https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
     | tar -xz -C /opt/steamcmd

# The tarball above ships an old client, and the first invocation of it
# updates itself and then exits 8 - "Restarting steamcmd by request" -
# having done none of the work it was asked to do. That is not an
# error worth failing on, it is the client's installation procedure, so
# it happens here on its own where it cannot be mistaken for one.
RUN /opt/steamcmd/steamcmd.sh +quit || true

# /opt/steam/valheim is not an arbitrary path: build.sh probes exactly
# this location for the assemblies, so the two agree by construction
# rather than by a flag that could drift.
#
# Retried, because `app_update` over a gigabyte from Valve's CDN fails
# transiently often enough that a single attempt makes this image
# flaky. Bounded at three so a real failure still fails, and the check
# after the loop is what decides: steamcmd's exit code is not
# trustworthy - it reports 8 for a self-restart and has been known to
# report 0 for a partial download - so what is tested is whether the
# one file this whole stage exists to produce is actually there.
RUN for attempt in 1 2 3; do \
      /opt/steamcmd/steamcmd.sh \
        +force_install_dir /opt/steam/valheim \
        +login anonymous \
        +app_update "${VALHEIM_APPID}" validate \
        +quit && break; \
      echo "steamcmd attempt ${attempt} failed, retrying"; \
    done; \
    test -f /opt/steam/valheim/valheim_server_Data/Managed/assembly_valheim.dll

# Clone without checkout, then detach onto the pinned revision. A
# branch name here would make this image mean something different every
# time it was built.
RUN git clone --no-checkout "${WEBMAP_REPOSITORY}" /src \
  && git -C /src checkout --detach "${WEBMAP_REVISION}"

WORKDIR /src
ENV BEPINEX_RELEASE=${BEPINEX_RELEASE}
# `bash build.sh` rather than `./build.sh`: upstream does not commit the
# executable bit on it, so invoking it directly fails with
# "Permission denied" and an exit code of 126. Naming the interpreter
# also makes this independent of whether they ever add the bit.
RUN bash build.sh \
      --managed /opt/steam/valheim/valheim_server_Data/Managed \
      --deploy /out

# The shipping stage: the plugin directory, and a shell to copy it out
# with. Everything above - the SDK, the game, BepInEx - stays behind.
FROM busybox:stable AS plugin
COPY --from=build /out/WebMap /out/WebMap
