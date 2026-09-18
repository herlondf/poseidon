# Shared base image: Free Pascal 3.3.1 (trunk), built from source.
#
# Why trunk and not the distro package: Poseidon (and this benchmark's
# mORMot2/Horse builds) use Delphi `reference to` procedural types, which need
# -Mfunctionreferences / -Manonymousfunctions. Those modeswitches do not exist
# in FPC 3.2.2 (the current Debian/Ubuntu apt package) - only in 3.3.1/trunk.
# Trunk has no apt package, so it is bootstrapped from source using the apt
# 3.2.2 compiler to build itself.
#
# This is a slow layer (compiling a whole compiler + RTL) but a one-time cost:
# every framework Dockerfile that needs FPC does `FROM poseidon-bench/fpc-trunk`
# and Docker's layer cache skips rebuilding it on every run.
FROM debian:12-slim

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      fpc git make binutils ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://gitlab.com/freepascal.org/fpc/source.git /fpc-source

WORKDIR /fpc-source
RUN make all OS_TARGET=linux CPU_TARGET=x86_64 -j"$(nproc)" \
 && make install OS_TARGET=linux CPU_TARGET=x86_64 INSTALL_PREFIX=/opt/fpc-trunk \
 && rm -rf /fpc-source

# Standard FPC install layout: compiler at lib/fpc/<ver>/ppcx64, RTL units at
# lib/fpc/<ver>/units/<target>/. The exact version directory name depends on
# the trunk checkout, so resolve it once here and record it for downstream
# Dockerfiles instead of hardcoding "3.3.1" (which drifts as trunk advances).
# `ls lib/fpc` also lists unrelated subdirs (e.g. lexyacc) - filter to the
# X.Y.Z version pattern specifically, or FPCVER ends up multi-line and every
# path built from it breaks.
RUN FPCVER="$(ls /opt/fpc-trunk/lib/fpc | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$')" \
 && echo "$FPCVER" > /opt/fpc-trunk/VERSION \
 && test -x "/opt/fpc-trunk/lib/fpc/$FPCVER/ppcx64"
