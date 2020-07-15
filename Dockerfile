
FROM ubuntu:18.04 as projer

MAINTAINER Howard Butler <howard@hobu.co>

ARG DESTDIR="/build"

# Setup build env
RUN apt-get update -y \
    && apt-get install -y --fix-missing --no-install-recommends \
            software-properties-common build-essential ca-certificates \
            make cmake wget unzip libtool automake \
            zlib1g-dev libsqlite3-dev pkg-config sqlite3 libcurl4-gnutls-dev \
            libtiff5-dev

COPY ./PROJ /PROJ

RUN cd /PROJ \
    && ./autogen.sh \
    && ./configure --prefix=/usr \
    && make -j$(nproc) \
    && make install


FROM osgeo/gdal:ubuntu-small-3.1.1 as builder
LABEL maintainer="info@camptocamp.com"

RUN apt update && \
    apt upgrade --assume-yes && \
    LC_ALL=C DEBIAN_FRONTEND=noninteractive apt install -y bison flex python-lxml libfribidi-dev swig \
    cmake librsvg2-dev colordiff libpq-dev libpng-dev libjpeg-dev libgif-dev libgeos-dev libgd-dev \
    libfreetype6-dev libfcgi-dev libcurl4-gnutls-dev libcairo2-dev libxml2-dev \
    libxslt1-dev python-dev php-dev libexempi-dev lcov lftp ninja-build git curl \
    clang libprotobuf-c-dev protobuf-c-compiler libharfbuzz-dev libcairo2-dev librsvg2-dev && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/local/lib/libproj.so.* /usr/local/lib/libproj.so

ARG MAPSERVER_BRANCH
ARG MAPSERVER_REPO=https://github.com/mapserver/mapserver

RUN git clone ${MAPSERVER_REPO}  --depth=100 /src

RUN cd /src; 

WORKDIR /src/build
RUN cmake .. \
    -GNinja \
    -DCMAKE_C_FLAGS="-O2 -DPROJ_RENAME_SYMBOLS" \
    -DCMAKE_CXX_FLAGS="-O2 -DPROJ_RENAME_SYMBOLS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DWITH_CLIENT_WMS=1 \
    -DWITH_CLIENT_WFS=1 \
    -DWITH_KML=1 \
    -DWITH_SOS=1 \
    -DWITH_XMLMAPFILE=1 \
    -DWITH_POINT_Z_M=1 \
    -DWITH_CAIRO=1 \
    -DWITH_RSVG=1

RUN ninja install


FROM osgeo/gdal:ubuntu-small-3.1.1 as runner
LABEL maintainer="info@camptocamp.com"

RUN apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        libsqlite3-0 libtiff5 libcurl4 libcurl3-gnutls \
        wget ca-certificates
# Put this first as this is rarely changing
RUN \
    mkdir -p /usr/share/proj; \
    wget --no-verbose --mirror https://cdn.proj.org/; \
    rm -f cdn.proj.org/*.js; \
    rm -f cdn.proj.org/*.css; \
    mv cdn.proj.org/* /usr/share/proj/; \
    rmdir cdn.proj.org

    COPY --from=projer  /build/usr/share/proj/ /usr/share/proj/
    COPY --from=projer  /build/usr/include/ /usr/include/
    COPY --from=projer  /build/usr/bin/ /usr/bin/
    COPY --from=projer  /build/usr/lib/ /usr/lib/


# Let's copy a few of the settings from /etc/init.d/apache2
ENV APACHE_CONFDIR=/etc/apache2 \
    APACHE_ENVVARS=/etc/apache2/envvars \
    # And then a few more from $APACHE_CONFDIR/envvars itself
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    APACHE_RUN_DIR=/var/run/apache2 \
    APACHE_PID_FILE=/var/run/apache2/apache2.pid \
    APACHE_LOCK_DIR=/var/lock/apache2 \
    APACHE_LOG_DIR=/var/log/apache2 \
    LANG=C \
    TERM=linux \
    MS_MAPFILE=/etc/mapserver/mapserver.map

RUN apt update && \
    apt upgrade --assume-yes && \
    apt install --assume-yes --no-install-recommends ca-certificates apache2 libapache2-mod-fcgid curl \
    libfribidi0 librsvg2-2 libpng16-16 libgif7 libfcgi0ldbl \
    libxslt1.1 libprotobuf-c1 libcap2-bin && \
    apt clean && \
    rm -rf /var/lib/apt/lists/* && \
    echo 'Allow apache2 to bind to port <1024 for any user' && \
    curl -L https://github.com/kelseyhightower/confd/releases/download/v0.14.0/confd-0.14.0-linux-amd64 > /bin/confd && \
    setcap cap_net_bind_service=+ep /usr/sbin/apache2 && \
    apt --purge autoremove -y curl libcap2-bin

RUN a2enmod fcgid headers status && \
    a2dismod -f auth_basic authn_file authn_core authz_user autoindex dir && \
    rm /etc/apache2/mods-enabled/alias.conf && \
    mkdir --parent ${APACHE_RUN_DIR} ${APACHE_LOCK_DIR} ${APACHE_LOG_DIR} /etc/confd/templates/ /etc/mapserver /etc/confd/conf.d && \
    find "$APACHE_CONFDIR" -type f -exec sed -ri ' \
    s!^(\s*CustomLog)\s+\S+!\1 /proc/self/fd/1!g; \
    s!^(\s*ErrorLog)\s+\S+!\1 /proc/self/fd/2!g; \
    ' '{}' ';' && \
    sed -ri 's!LogFormat "(.*)" combined!LogFormat "%{us}T %{X-Request-Id}i \1" combined!g' /etc/apache2/apache2.conf && \
    echo 'ErrorLogFormat "%{X-Request-Id}i [%l] [pid %P] %M"' >> /etc/apache2/apache2.conf && \
    chmod a+rx /bin/confd && \
    mkdir --parent /etc/confd/conf.d /etc/confd/templates /etc/mapserver /docker-entrypoint.d

EXPOSE 80

COPY --from=builder /usr/local/bin /usr/local/bin/
COPY --from=builder /usr/local/lib /usr/local/lib/
COPY runtime /

ENV MS_DEBUGLEVEL=0 \
    MS_ERRORFILE=stderr \
    MAX_REQUESTS_PER_PROCESS=1000 \
    MIN_PROCESSES=1 \
    MAX_PROCESSES=5 \
    BUSY_TIMEOUT=300 \
    IDLE_TIMEOUT=300 \
    IO_TIMEOUT=40

RUN adduser www-data root && \
    chmod -R g+w ${APACHE_CONFDIR} ${APACHE_RUN_DIR} ${APACHE_LOCK_DIR} ${APACHE_LOG_DIR} /etc/confd /etc/mapserver /var/lib/apache2/fcgid /var/log && \
    chgrp -R root ${APACHE_LOG_DIR} /var/lib/apache2/fcgid

ENTRYPOINT ["/docker-entrypoint"]

CMD ["/usr/local/bin/start-server"]

WORKDIR /etc/mapserver