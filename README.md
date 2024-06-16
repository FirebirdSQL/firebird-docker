# firebird-docker

Docker images for Firebird Database.



# Quick reference

  - [Quick Start Guide](https://firebirdsql.org/file/documentation/html/en/firebirddocs/qsg5/firebird-5-quickstartguide.html)
  - [Language Reference](https://firebirdsql.org/file/documentation/html/en/refdocs/fblangref50/firebird-50-language-reference.html)
  - [Release Notes](https://firebirdsql.org/file/documentation/release_notes/html/en/5_0/rlsnotes50.html)



# Supported tags

|`ghcr.io/fdcastel/firebird`|Dockerfile|OS|Last modified|
|:-|:-:|:-:|:-:|
|`5`, `5-bookworm`, `bookworm`, `latest`|[amd64](./generated/5/linux/amd64/bookworm/Dockerfile), [arm64](./generated/5/linux/arm64/bookworm/Dockerfile)|Debian 12.5|2024-06-16|
|`5-jammy`, `jammy`|[amd64](./generated/5/linux/amd64/jammy/Dockerfile), [arm64](./generated/5/linux/arm64/jammy/Dockerfile)|Ubuntu 22.04|2024-06-16|
|`4`, `4-bookworm`|[amd64](./generated/4/linux/amd64/bookworm/Dockerfile)|Debian 12.5|2024-06-16|
|`4-jammy`|[amd64](./generated/4/linux/amd64/jammy/Dockerfile)|Ubuntu 22.04|2024-06-16|
|`3`, `3-bookworm`|[amd64](./generated/3/linux/amd64/bookworm/Dockerfile)|Debian 12.5|2024-06-16|
|`3-jammy`|[amd64](./generated/3/linux/amd64/jammy/Dockerfile)|Ubuntu 22.04|2024-06-16|



# How to use this image

Image defaults:
  - `EXPOSE 3050/tcp`
  - `VOLUME /run/firebird/data`

## Start a Firebird server instance

```bash
docker run \
    -e FIREBIRD_ROOT_PASSWORD=************ \
    -e FIREBIRD_USER=alice \
    -e FIREBIRD_PASSWORD=************ \
    -e FIREBIRD_DATABASE=mirror.fdb \
    -e FIREBIRD_DATABASE_DEFAULT_CHARSET=UTF8 \
    -v ./data:/run/firebird/data
    --detach ghcr.io/fdcastel/firebird
```



## Using [`Docker Compose`](https://github.com/docker/compose)

```yaml
services:
  firebird:
    image: ghcr.io/fdcastel/firebird
    restart: always
    environment:
      - FIREBIRD_ROOT_PASSWORD=************
      - FIREBIRD_USER=alice
      - FIREBIRD_PASSWORD=************
      - FIREBIRD_DATABASE=mirror.fdb
      - FIREBIRD_DATABASE_DEFAULT_CHARSET=UTF8
    volumes:
      - ./data:/run/firebird/data
```



## Connect to an existing instance using `isql`

```bash
docker run -it --rm ghcr.io/fdcastel/firebird isql -u SYSDBA -p ************ SERVER:/path/to/file.fdb
```



## Environment variables

The following environment variables can be used to customize the container.



### `FIREBIRD_ROOT_PASSWORD`
  - _alternate name_: `ISC_PASSWORD`

If present sets the password for `SYSDBA` user.

If not present a random password will be generated and stored into `/opt/firebird/SYSDBA.password`.



### `FIREBIRD_USER`

Creates an user in Firebird security database.

You must inform a password in `FIREBIRD_PASSWORD` variable. Otherwise the container initialization will fail.



### `FIREBIRD_DATABASE`

Creates a new database. Ignored if the database already exists.

Database location is `/run/firebird/data`. Absolute paths (outside this folder) are allowed.

You may use `FIREBIRD_DATABASE_PAGE_SIZE` to set the database page size. And `FIREBIRD_DATABASE_DEFAULT_CHARSET` to set the default character set.



### `FIREBIRD_USE_LEGACY_AUTH`

Enables [legacy authentication](https://firebirdsql.org/file/documentation/release_notes/html/en/3_0/rlsnotes30.html#rnfb30-compat-legacyauth) (not recommended).



### `FIREBIRD_CONF_*`

Any variable starting with `FIREBIRD_CONF_` can be used to set values in Firebird configuration file (`firebird.conf`).

E.g. You can use `FIREBIRD_CONF_DataTypeCompatibility=3.0` to set the value of key `DataTypeCompatibility` to `3.0` in `firebird.conf`.

Please note that keys are case sensitive. And any key not present in `firebird.conf` will be ignored.



### `*_FILE`

Any of the previously listed environment variables may be loaded from file by appending the `_FILE` suffix to the variable name.

E.g. `FIREBIRD_PASSWORD_FILE=/run/secrets/firebird-passwd` will load `FIREBIRD_PASSWORD` with the content from `/run/secrets/firebird-passwd` file.

Note that both the original variable and its `_FILE` variant are mutually exclusive. Trying to use both will cause the container initialization to fail.



## Initializing the database contents

When creating a new database with `FIREBIRD_DATABASE` environment variable you can initialize it running one or more shell or SQL scripts.

Any file with extensions `.sh`, `.sql`, `.sql.gz`, `.sql.xz` and `.sql.zst` found in `/docker-entrypoint-initdb.d/` will be executed in _alphabetical_ order. `.sh` files without file execute permission (`+x`) will be _sourced_ rather than executed.

**IMPORTANT:** Scripts will only run if you start the container with a data directory that is empty. Any pre-existing database will be left untouched on container startup.



## Setting container time zone

The container runs in the `UTC` time zone by default. To change this, you can set the `TZ` environment variable:

```yaml
    environment:
      - TZ=America/New_York
```

Alternatively, you can use the same time zone as your host system by mapping the `/etc/localtime` and `/etc/timezone` system files:

```yaml
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
```

# Development notes

## Prerequisites

  - [Docker](https://docs.docker.com/engine/install/)
  - [Powershell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux)
  - [Invoke-Build](https://github.com/nightroman/Invoke-Build#install-as-module)



## Build

To generate the source files and build each image from [`assets.json`](assets.json) configuration file, run:

```bash
Invoke-Build
```

You can then check all created images with:

```bash
docker image ls ghcr.io/fdcastel/firebird
```



## Tests

To run the test suite for each image, use:

```bash
Invoke-Build Test
```
