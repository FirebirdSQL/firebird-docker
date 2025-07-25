#
# This file was auto-generated. Do not edit. See /src.
#

# Best practices for Dockerfile instructions
#   https://docs.docker.com/develop/develop-images/instructions/

FROM ubuntu:noble

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ARG ARCH_ARM64

# ARM64 arch
ENV FIREBIRD_RELEASE_URL=${ARCH_ARM64:+https://github.com/FirebirdSQL/firebird/releases/download/v5.0.3/Firebird-5.0.3.1683-0-linux-arm64.tar.gz}
ENV FIREBIRD_RELEASE_SHA256=${ARCH_ARM64:+e375341466e625bf17e4416723c1465a646d44903011ac4b89f84afe1df3633e}

# AMD64 arch
ENV FIREBIRD_RELEASE_URL=${FIREBIRD_RELEASE_URL:-https://github.com/FirebirdSQL/firebird/releases/download/v5.0.3/Firebird-5.0.3.1683-0-linux-x64.tar.gz}
ENV FIREBIRD_RELEASE_SHA256=${FIREBIRD_RELEASE_SHA256:-ef281c53f85756288151a86831375c9ae668caaeccd1b18103d523ba8f444779}

ENV FIREBIRD_VERSION=5.0.3
ENV FIREBIRD_MAJOR=5

# https://linuxcommand.org/lc3_man_pages/seth.html
#   -e  Exit immediately if a command exits with a non-zero status.
#   -u  Treat unset variables as an error when substituting
#   -x  Print commands and their arguments as they are executed.

# Prerequisites
#   FB 3.0 uses libncurses5: https://github.com/FirebirdSQL/firebird/issues/6418#issuecomment-826245785
RUN set -eux; \
    apt-get update; \
    # Install prerequisites + curl, ca-certificates for download
    apt-get install -y --no-install-recommends \
        libatomic1 \
        libicu74 \
        $([ $FIREBIRD_MAJOR -eq 3 ] && echo 'libncurses5' || echo 'libncurses6') \
        libtomcrypt1 \
        libtommath1 \
        netbase \
        procps \
        ca-certificates \
        curl; \
    \
    # Download
    mkdir -p /tmp/firebird_install; \
    echo "Downloading Firebird from $FIREBIRD_RELEASE_URL"; \
    curl -fSL "$FIREBIRD_RELEASE_URL" -o /tmp/firebird_install/firebird-bundle.tar.gz; \
    echo "Verifying checksum: $FIREBIRD_RELEASE_SHA256 for downloaded file"; \
    echo "$FIREBIRD_RELEASE_SHA256 /tmp/firebird_install/firebird-bundle.tar.gz" | sha256sum -c -; \
    \
    # Extract, install, clean
    cd /tmp/firebird_install; \
    tar --extract --file=firebird-bundle.tar.gz --gunzip --verbose --strip-components=1; \
    ./install.sh -silent; \
    rm -rf /tmp/firebird_install; \
    # Remove unnecessary files
    rm -rf /opt/firebird/doc \
           /opt/firebird/examples \
           /opt/firebird/help \
           /opt/firebird/include; \
    # Remove 'employee' sample database from 'databases.conf'
    sed -i '/^employee/d' /opt/firebird/databases.conf; \
    \
    # Clean up temporary packages (curl, ca-certificates) and apt lists
    apt-get purge -y --auto-remove curl ca-certificates; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Fix libtommath for FB 3.0 -- https://github.com/FirebirdSQL/firebird/issues/5716#issuecomment-826239174
RUN [ $FIREBIRD_MAJOR -eq 3 ] && ln -sf /usr/lib/x86_64-linux-gnu/libtommath.so.1 /usr/lib/x86_64-linux-gnu/libtommath.so.0 || true

# System path
ENV PATH=/opt/firebird/bin:$PATH

# Data directory
ENV FIREBIRD_DATA=/var/lib/firebird/data
RUN set -eux; \
    mkdir -p "$FIREBIRD_DATA"; \
    chown -R firebird:firebird "$FIREBIRD_DATA"; \
    chmod 644 "$FIREBIRD_DATA"
VOLUME $FIREBIRD_DATA

# Entrypoint
COPY entrypoint.sh /usr/local/bin/
RUN set -eux; \
    chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]

EXPOSE 3050/tcp

# Fix terminfo location
ENV TERMINFO=/lib/terminfo/

CMD ["firebird"]

