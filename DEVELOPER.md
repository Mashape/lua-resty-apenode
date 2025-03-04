## Development

We encourage community contributions to Kong. To ensure a smooth experience for both you and the Kong team, please read the following documents before you start:
- [CONTRIBUTING.md](CONTRIBUTING.md)
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- [COPYRIGHT](COPYRIGHT)

If you are planning to develop on Kong, you will need a development installation. The `master` branch holds the latest unreleased source code.

To get started with writing custom plugins, you can refer to:
- [Plugin Development Guide](https://docs.konghq.com/gateway/latest/plugin-development/)
- [Plugin Development Kit (PDK) Reference](https://docs.konghq.com/latest/pdk/)

For a quick start with custom plugin development, check out:
- [Pongo](https://github.com/Kong/kong-pongo)
- [Plugin Template](https://github.com/Kong/kong-plugin)

---

## Distributions

Kong is available in several formats. This repository contains the core source code, but other repositories are actively developed:

- [Kubernetes Ingress Controller for Kong](https://github.com/Kong/kubernetes-ingress-controller): Use Kong for Kubernetes Ingress.
- [Binary Packages](https://docs.konghq.com/gateway/latest/install/)
- [Kong Docker](https://github.com/Kong/docker-kong): A Dockerfile for running Kong in Docker.
- [Kong Packages](https://github.com/Kong/kong/releases): Pre-built packages for Debian, Red Hat, and OS X distributions (shipped with each release).
- [Kong Homebrew](https://github.com/Kong/homebrew-kong): Homebrew Formula for Kong.
- [Kong AWS AMI](https://aws.amazon.com/marketplace/pp/B06WP4TNKL): Kong AMI on the AWS Marketplace.
- [Kong on Microsoft Azure](https://github.com/Kong/kong-dist-azure): Run Kong using Azure Resource Manager.
- [Kong on Heroku](https://github.com/heroku/heroku-kong): Deploy Kong on Heroku in one click.
- [Kong on IBM Cloud](https://github.com/andrew40404/installing-kong-IBM-cloud): How to deploy Kong on IBM Cloud.
- [Kong and Instaclustr](https://www.instaclustr.com/solutions/managed-cassandra-for-kong/): Let Instaclustr manage your Cassandra cluster.
- [Master Builds](https://hub.docker.com/r/kong/kong): Docker images for each commit in the `master` branch.

For a full list of supported distributions, visit the [official installation page](https://konghq.com/install/#kong-community).

---

### Kong Pongo

[Pongo](https://github.com/Kong/kong-pongo) is a CLI tool tailored for plugin development. It uses Docker Compose to create local test environments with all dependencies. Core features include running tests, integrated linter, config initialization, CI support, and custom dependencies.

---

### Kong Plugin Template

The [plugin template](https://github.com/Kong/kong-plugin) provides a basic plugin structure and is the recommended starting point for custom plugin development. It follows best practices and integrates seamlessly with [Pongo](https://github.com/Kong/kong-pongo).

---

## Build and Install from Source

This method is ideal for beginners to understand how Kong works and to build a development environment.

Kong is primarily an OpenResty application built from Lua source files, but it also requires additional third-party dependencies. Kong runs on a modified version of OpenResty with specific patches.

To install from source, follow these steps:

---

### Clone the Repository

```shell
git clone https://github.com/Kong/kong

cd kong
# You may want to switch to the development branch. Refer to CONTRIBUTING.md
git checkout master
```

---

### Install Dependencies

#### Ubuntu/Debian:

```shell
sudo apt update \
&& sudo apt install -y \
    automake \
    build-essential \
    curl \
    file \
    git \
    libyaml-dev \
    libprotobuf-dev \
    m4 \
    perl \
    pkg-config \
    procps \
    unzip \
    valgrind \
    zlib1g-dev
```

#### Fedora/RHEL:

```shell
dnf install \
    automake \
    gcc \
    gcc-c++ \
    git \
    libyaml-devel \
    make \
    patch \
    perl \
    perl-IPC-Cmd \
    protobuf-devel \
    unzip \
    valgrind \
    valgrind-devel \
    zlib-devel
```

#### macOS:

```shell
# Install Xcode from the App Store (Command Line Tools not supported)

# Install HomeBrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Build dependencies
brew install libyaml
```

---

### Authenticate with GitHub

To download some essential repositories, authenticate with GitHub using one of the following methods:
- Download and use the [`gh cli`](https://cli.github.com/) and run `gh auth login`.
- Use a [Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token) with the `Public Repositories (read-only)` permission. Set this token as the `GITHUB_TOKEN` environment variable.
- Use the [git credential helper](https://git-scm.com/docs/gitcredentials).

---

Here's the content formatted in markdown for a `README.md` file:

```markdown
# Kong Development Environment Setup

## Authenticate Rust Build System with GitHub

If you are not authenticated using `gh` or `git credential helper`, set the `CARGO_NET_GIT_FETCH_WITH_CLI` environment variable to `true`.

```bash
export CARGO_NET_GIT_FETCH_WITH_CLI=true
```

An alternative is to edit the `~/.cargo/config` file and add the following lines:

```toml
[net]
git-fetch-with-cli = true
```

You also have to make sure the `git` CLI is using the proper protocol to fetch the dependencies if you are authenticated with a [Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token).

```bash
# If you are using the HTTPS protocol to clone the repository
# YOU ONLY NEED TO DO THIS ONLY ONCE FOR THIS DIRECTORY
git config --local url."https://${GITHUB_TOKEN}@github.com/".insteadOf 'git@github.com:'
git config --local url."https://${GITHUB_TOKEN}@github.com".insteadOf 'https://github.com'

# If you are using the SSH protocol to clone the repository
# YOU ONLY NEED TO DO THIS ONLY ONCE FOR THIS DIRECTORY
git config --local url.'git@github.com:'.insteadOf 'https://github.com'
git config --local url.'ssh://git@github.com/'.insteadOf 'https://github.com/'
```

Finally, start the build process:

```bash
# Build the virtual environment for developing Kong
make build-venv
```

[The build guide](https://github.com/Kong/kong/blob/master/build/README.md) contains a troubleshooting section if you face any problems. It also describes the build process in detail, if you want to develop on the build system itself.

## Start Kong

Now you can start Kong:

```bash
# Activate the venv by adding some environment variables and populate helper functions
# into your current shell session, following functions are exported:
# `start_services`, `stop_services`, and `deactivate`
# For Zsh/Bash:
. bazel-bin/build/kong-dev-venv.sh
# For Fish Shell:
. bazel-bin/build/kong-dev-venv.fish

# Use the pre-defined docker-compose file to bring up databases etc
start_services

# Start Kong!
kong start

# Stop Kong
kong stop

# Cleanup
deactivate
```

## Install Development Dependencies

### Running for Development

By default, the development environment adds the current directory to the Lua files search path.

Modifying the [`lua_package_path`](https://github.com/openresty/lua-nginx-module#lua_package_path)
and [`lua_package_cpath`](https://github.com/openresty/lua-nginx-module#lua_package_cpath)
directives will allow Kong to find your custom plugin's source code wherever it might be on your system.

### Tests

Install the development dependencies ([busted](https://lunarmodules.github.io/busted/),
[luacheck](https://github.com/mpeterv/luacheck)) with:

```bash
make dev
```

If Rust/Cargo doesn't work, try setting `export KONG_TEST_USER_CARGO_DISABLED=1` first.

Kong relies on three test suites using the [busted](https://lunarmodules.github.io/busted/) testing library:

- Unit tests
- Integration tests, which require Postgres and Cassandra to be up and running
- Plugins tests, which require Postgres to be running

The first can simply be run after installing busted and running:

```bash
make test
```

However, the integration and plugins tests will spawn a Kong instance and perform their tests against it. Because these test suites perform their tests against the Kong instance, you may need to edit the `spec/kong_tests.conf` configuration file to make your test instance point to your Postgres/Cassandra servers, depending on your needs.

You can run the integration tests (assuming **both** Postgres and Cassandra are running and configured according to `spec/kong_tests.conf`) with:

```bash
make test-integration
```

And the plugins tests with:

```bash
make test-plugins
```

Finally, all suites can be run at once by simply using:

```bash
make test-all
```

Consult the [run_tests.sh](.ci/run_tests.sh) script for more advanced example usage of the test suites and the Makefile.

A very useful tool in Lua development (as with many other dynamic languages) is performing static linting of your code. You can use [luacheck](https://github.com/mpeterv/luacheck) (installed with `make dev`) for this:

```bash
make lint
```

### Upgrade Tests

Kong Gateway supports no-downtime upgrades through its database schema migration mechanism (see [UPGRADE.md](./UPGRADE.md)). Each schema migration needs to be written in a way that allows the previous and the current version of Kong Gateway to run against the same database during upgrades. Once all nodes have been upgraded to the current version of Kong Gateway, additional changes to the database can be made that are incompatible with the previous version. Each migration is split into two parts: an `up` part that can only make backwards-compatible changes, and a `teardown` part that runs after all nodes have been upgraded to the current version.

Each migration that is contained in Kong Gateway needs to be accompanied by a test that verifies the correct operation of both the previous and the current version during an upgrade. These tests are located in the [spec/05-migration/](spec/05-migration/) directory and must be named after the migration they test such that the migration `kong/**/*.lua` has a test in `spec/05-migration/**/*_spec.lua`. The presence of a test is enforced by the [upgrade testing](scripts/upgrade-tests/test-upgrade-path.sh) shell script which is [automatically run](.github/workflows/upgrade-tests.yml) through a GitHub Action.

The [upgrade testing](scripts/upgrade-tests/test-upgrade-path.sh) shell script works as follows:

- A new Kong Gateway installation is brought up using [Gojira](https://github.com/Kong/gojira), consisting of one node containing the previous version of Kong Gateway ("OLD"), one node containing the current version of Kong Gateway ("NEW"), and a shared database server (PostgreSQL or Cassandra).
- NEW: The database is initialized using `kong migrations bootstrap`.
- OLD: The `setup` phase of all applicable migration tests is run.
- NEW: `kong migrations up` is run to run the `up` part of all applicable migrations.
- OLD: The `old_after_up` phase of all applicable migration tests is run.
- NEW: The `new_after_up` phase of all applicable migration tests is run.
- NEW: `kong migrations finish` is run to invoke the `teardown` part of all applicable migrations.
- NEW: The `new_after_finish` phase of all applicable migration tests is run.

Upgrade tests are run using [busted](https://github.com/lunarmodules/busted). To support the specific testing method of upgrade testing, a number of helper functions are defined in the [spec/upgrade_helpers.lua](spec/upgrade_helpers.lua) module. Migration tests use functions from this module to define test cases and associate them with phases of the upgrade testing process. Consequently, they are named `setup`, `old_after_up`, `new_after_up`, and `new_after_finish`. Additionally, the function `all_phases` can be used to run a certain test in the three phases `old_after_up`, `new_after_up`, and `new_after_finish`. These functions replace the use of busted's `it` function and accept a descriptive string and a function as an argument.

It is important to note that upgrade tests need to run on both the old and the new version of Kong. Thus, they can only use features that are available in both versions (i.e. from helpers.lua). The module [spec/upgrade_helpers.lua](spec/upgrade_helpers.lua) is copied from the new version into the container of the old version and it can be used to make new library functionality available to migration tests.

### Makefile

When developing, you can use the `Makefile` for the following operations:

| Name               | Description                                            |
| ------------------:| -------------------------------------------------------|
| `install`          | Install the Kong luarock globally                      |
| `dev`              | Install development dependencies                       |
| `lint`             | Lint Lua files in `kong/` and `spec/`                  |
| `test`             | Run the unit tests suite                               |
| `test-integration` | Run the integration tests suite                        |
| `test-plugins`     | Run the plugins test suite                             |
| `test-all`         | Run all unit + integration + plugins tests at once     |

## Setup Hybrid Mode Development Environment

You can follow the steps below to set up a hybrid mode environment:

1. Activate the venv:

   ```bash
   # . bazel-bin/build/kong-dev-venv.sh
   ```

2. Follow [Deploy Kong Gateway in Hybrid Mode: Generate certificate/key pair](https://docs.konghq.com/gateway/latest/production/deployment-topologies/hybrid-mode/setup/#generate-a-certificatekey-pair) to generate a certificate/key pair.

3. Create CP and DP configuration files, such as `kong-cp.conf` and `kong-dp.conf`.

4. Follow [Deploy Kong Gateway in Hybrid Mode: CP Configuration](https://docs.konghq.com/gateway/latest/production/deployment-topologies/hybrid-mode/setup/#set-up-the-control-plane)

 and [DP Configuration](https://docs.konghq.com/gateway/latest/production/deployment-topologies/hybrid-mode/setup/#set-up-the-data-plane) to complete the setup.

## Support

If you encounter any issues, you can check the [troubleshooting guide](https://github.com/Kong/kong/blob/master/build/README.md) or open a GitHub issue for further assistance.
