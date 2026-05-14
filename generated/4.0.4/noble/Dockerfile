#
# This file was auto-generated. Do not edit. See /src.
#

# Best practices for Dockerfile instructions
#   https://docs.docker.com/develop/develop-images/instructions/

FROM ubuntu:noble

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ENV FIREBIRD_VERSION=4.0.4
ENV FIREBIRD_MAJOR=4

# https://linuxcommand.org/lc3_man_pages/seth.html
#   -e  Exit immediately if a command exits with a non-zero status.
#   -u  Treat unset variables as an error when substituting
#   -x  Print commands and their arguments as they are executed.

# Prerequisites
RUN set -eux; \
    apt-get update; \
    # Install prerequisites + tini + curl/ca-certificates for download
    apt-get install -y --no-install-recommends \
        libatomic1 \
        libicu74 \
        libncurses6 \
        libtomcrypt1 \
        libtommath1 \
        netbase \
        procps \
        tini \
        tzdata \
        ca-certificates \
        curl; \
    \
    # Download
    ARCH=$(dpkg --print-architecture); \
    case "$ARCH" in \
        amd64) \
            FIREBIRD_URL='https://github.com/FirebirdSQL/firebird/releases/download/v4.0.4/Firebird-4.0.4.3010-0.amd64.tar.gz'; \
            FIREBIRD_SHA256='ef589301c5e13a1f8481e1e38c453641ef5082344bf69edb51f8aa9f036bcaca'; \
            ;; \
        *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac; \
    mkdir -p /tmp/firebird_install; \
    echo "Downloading Firebird from $FIREBIRD_URL"; \
    curl -fSL "$FIREBIRD_URL" -o /tmp/firebird_install/firebird-bundle.tar.gz; \
    echo "Verifying checksum: $FIREBIRD_SHA256 for downloaded file"; \
    echo "$FIREBIRD_SHA256 /tmp/firebird_install/firebird-bundle.tar.gz" | sha256sum -c -; \
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
RUN set -eux; \
    ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "$(uname -m)-linux-gnu"); \
    [ $FIREBIRD_MAJOR -eq 3 ] && ln -sf /usr/lib/$ARCH/libtommath.so.1 /usr/lib/$ARCH/libtommath.so.0 || true

# FB 3.0 needs libncurses5/libtinfo5. On Debian Trixie and Ubuntu Noble those
# packages were dropped from apt; pull them from the previous release pool.
# See DECISIONS.md D-017 and https://github.com/FirebirdSQL/firebird-docker/issues/42
RUN set -eux; \
    if [ "$FIREBIRD_MAJOR" = "3" ]; then \
        . /etc/os-release; \
        case "$ID-$VERSION_CODENAME" in \
            debian-bookworm|debian-bullseye|ubuntu-jammy) \
                apt-get update; \
                apt-get install -y --no-install-recommends libtinfo5 libncurses5; \
                rm -rf /var/lib/apt/lists/* \
                ;; \
            debian-trixie) \
                apt-get update; \
                apt-get install -y --no-install-recommends ca-certificates curl; \
                cd /tmp; \
                curl -fSL -O http://deb.debian.org/debian/pool/main/n/ncurses/libtinfo5_6.4-4_amd64.deb; \
                curl -fSL -O http://deb.debian.org/debian/pool/main/n/ncurses/libncurses5_6.4-4_amd64.deb; \
                dpkg -i libtinfo5_6.4-4_amd64.deb libncurses5_6.4-4_amd64.deb; \
                rm -f libtinfo5_6.4-4_amd64.deb libncurses5_6.4-4_amd64.deb; \
                apt-get purge -y --auto-remove curl ca-certificates; \
                apt-get clean; \
                rm -rf /var/lib/apt/lists/* \
                ;; \
            ubuntu-noble) \
                apt-get update; \
                apt-get install -y --no-install-recommends ca-certificates curl; \
                cd /tmp; \
                curl -fSL -O http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb; \
                curl -fSL -O http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2ubuntu0.1_amd64.deb; \
                dpkg -i libtinfo5_6.3-2ubuntu0.1_amd64.deb libncurses5_6.3-2ubuntu0.1_amd64.deb; \
                rm -f libtinfo5_6.3-2ubuntu0.1_amd64.deb libncurses5_6.3-2ubuntu0.1_amd64.deb; \
                apt-get purge -y --auto-remove curl ca-certificates; \
                apt-get clean; \
                rm -rf /var/lib/apt/lists/* \
                ;; \
            *) \
                echo "FB3: no libncurses5 provisioning path for $ID-$VERSION_CODENAME" >&2; \
                exit 1 \
                ;; \
        esac; \
    fi

# System path
ENV PATH=/opt/firebird/bin:$PATH

# Data directory
ENV FIREBIRD_DATA=/var/lib/firebird/data
RUN set -eux; \
    mkdir -p "$FIREBIRD_DATA"; \
    chown -R firebird:firebird "$FIREBIRD_DATA"; \
    chmod 755 "$FIREBIRD_DATA"
VOLUME $FIREBIRD_DATA

# Entrypoint
COPY entrypoint.sh /usr/local/bin/
RUN set -eux; \
    chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["tini", "--", "entrypoint.sh"]

STOPSIGNAL SIGTERM
EXPOSE 3050/tcp

# Fix terminfo location
ENV TERMINFO=/lib/terminfo/

CMD ["firebird"]

