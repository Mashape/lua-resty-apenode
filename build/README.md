# Build

This directory contains the build system for the project.
The build system is designed to be used with the [Bazel](https://bazel.build/).
It is designed to be running on Linux without root privileges, and no virtualization technology is required.

The build system is tested on Linux (x86_64 and aarch64) and macOS (Intel chip and AppleSilicon Chip).

## Prerequisites

The following examples should be performed under the Kong source codebase.

The build system requires the following tools to be installed:

- [Bazel/Bazelisk](https://bazel.build/install/bazelisk), Bazelisk is recommended to ensure the correct version of Bazel is used.

  We can install Bazelisk by running the following command:

  ```bash
    # install Bazelisk into $PWD/bin/bazel
    make check-bazel
    # add Bazelisk into your $PATH
    export PATH=bin:$PATH
    # check bazel version
    bazel version
  ```
- [Build dependencies](https://github.com/Kong/kong/blob/master/DEVELOPER.md#build-and-install-from-source)

**Note**: Bazel relies on logged user to create the temporary file system; however if your username contains `@`
it collides with Bazel templating system. Therefore you can set the environment variable `export USER=myname` to fix
this issue.

## Building

### Build dependencies

Run the following command to build dependencies of Kong:

```bash
bazel build //build:kong --verbose_failures
```

This will build luarocks, the OpenResty distribution of Kong, and the `lua-resty-*` libs required by Kong.

During the first run, it will take some time to perform a complete build, which includes downloading dependent files and compiling.

Once the build is complete, you will see four `bazel-*` folders in the current directory. Refer to the [workspace layout diagram](https://bazel.build/remote/output-directories?hl=en#layout-diagram) for their respective definitions.

### Development environment

To use the build as a virtual development environment, build the `//build:venv`
target:

```bash
bazel build //build:venv --verbose_failures
```

This generates files in `./bazel-bin/build` that can be used to initialize your
development environment.

#### bash/fish shell

```sh
# bash
source ./bazel-bin/build/kong-dev-venv.sh

# fish
source ./bazel-bin/build/kong-dev-venv.fish
```

This operation primarily accomplishes the following:

1. Add the Bazel build output folder containing `resty`, `luarocks` and other commands to `$PATH` so that the commands in the build output can be used directly.
2. Set and specify the runtime path for Kong.
3. Provide Bash functions to start and stop the database and other third-party dependency services required for Kong development environment using Docker, read more: [Start Kong](../DEVELOPER#start-kong).

#### direnv

The `//build:venv` target also creates a file at `bazel-bin/build/{{build_name}}-venv-envrc`
which is suitable to include in your [direnv](https://direnv.net) workflow.

Example `.envrc` file:

```sh
BUILD_NAME=kong-dev
source_env_if_exists "bazel-bin/build/${BUILD_NAME}-venv.envrc"
```

Example with a kong checkout at `~/git/kong/kong` and an `.envrc` file:

```
$ direnv reload
direnv: loading ~/git/kong/kong/bazel-bin/build/kong-dev-venv.envrc
LuaRocks: /home/michaelm/git/kong/kong/bazel-bin/build/kong-dev
OpenResty: /home/michaelm/git/kong/kong/bazel-bin/build/kong-dev/openresty
OpenSSL: /home/michaelm/git/kong/kong/bazel-bin/external/openssl/openssl
direnv: export +CRYPTO_DIR +KONG_OPENRESTY_PATH +KONG_TEST_OPENRESTY_PATH +LIBRARY_PREFIX +OPENSSL_DIR +OPENSSL_INCDIR +_KONG_REPO ~LUAROCKS_CONFIG ~LUA_CPATH ~LUA_PATH ~MANPATH ~PATH

$ which kong resty nginx openssl lua luajit luarocks busted luacheck
~/git/kong/kong/bin/kong
~/git/kong/kong/bazel-bin/build/kong-dev/openresty/bin/resty
~/git/kong/kong/bazel-bin/build/kong-dev/openresty/nginx/sbin/nginx
~/git/kong/kong/bazel-bin/external/openssl/openssl/bin/openssl
~/git/kong/kong/bazel-bin/build/kong-dev/openresty/luajit/bin/lua
~/git/kong/kong/bazel-bin/build/kong-dev/openresty/luajit/bin/luajit
~/git/kong/kong/bazel-bin/build/kong-dev/bin/luarocks
~/git/kong/kong/bin/busted
~/git/kong/kong/bazel-bin/build/kong-dev/bin/luacheck
```

The following environment variables will be managed by direnv:
* `CRYPTO_DIR`
* `KONG_OPENRESTY_PATH`
* `KONG_TEST_OPENRESTY_PATH`
* `LIBRARY_PREFIX`
* `LUAROCKS_CONFIG`
* `LUA_CPATH`
* `LUA_PATH`
* `MANPATH`
* `OPENSSL_DIR`
* `OPENSSL_INCDIR`
* `PATH`

**NOTE:** direnv does not support exported shell functions, so `start_services`
and `stop_services` functions are not provided.

###  C module and Nginx development

When we are developing part of the Kong installation, especially some Nginx C modules, installing stuffs like luarocks is not necessary. We can use the following steps:

1. Update the C module to be pointed to point a local path. In `.requirements` update (for example) `LUA_KONG_NGINX_MODULE=/path/to/lua-kong-nginx-module`
2. Do a full build once `bazel build //build:install-openresty`
3. The produced nginx is at `./bazel-bin/build/kong-dev/openresty/nginx/sbin/nginx`
4. Do incremental build using `bazel build //build:dev-make-openresty`

One can also use `make build-openresty` to automatically do a full build or a incremental build.

Other targets developer may found useful to cope with Nginx development:

- Install the lua files come with the C modules: `bazel build //build:install-lualibs`
- Install WasmX related artifacts: `bazel build //build:install-wasmx`

### Debugging

Query list all direct dependencies of the `kong` target

```bash
bazel query 'deps(//build:kong, 1)'

# output
//build:install
//build:kong
@luarocks//:luarocks_make
@luarocks//:luarocks_target
...
```

Each targets under `//build:install` installs an independent component that
composes the Kong runtime environment. We can query `deps(//build:install, 1)`
recursively to find the target that only build and install specific component.
This would be useful if one is debugging the issue of a specific target without
the need to build whole Kong runtime environment.

We can use the target labels to build the dependency directly, for example:

- `bazel build //build:install-openresty`: builds openresty
- `bazel build //build:install-atc_router-luaclib`: builds the ATC router shared library
- `bazel build @luarocks//:luarocks_make`: builds luarocks for Kong dependencies

#### Debugging variables in *.bzl files

Use `print` function to print the value of the variable in the `*.bzl` file. For example, we can print the value of the `WORKSPACE_PATH` variable in the `_load_bindings_impl` function in [kong_bindings.bzl](../build/kong_bindings.bzl) by adding the following code:

```python
content += '"WORKSPACE_PATH": "%s",\n' % workspace_path
# add the following line
print("WORKSPACE_PATH: %s" % workspace_path)
```

Since `load_bindings` is called in the `WORKSPACE` file, and `_load_bindings_impl` is the implementation of `load_bindings`, we can just run the following command to print the value of the `WORKSPACE_PATH` variable:

```bash
bazel build //build:kong

# output
DEBUG: path/to/kong-dev/kong/build/kong_bindings.bzl:16:10: WORKSPACE_PATH: path/to/kong-dev/kong
```

### Some useful Bazel query commands

- `bazel query 'deps(//build:kong)'`: list all dependencies of the `kong` target.
- `bazel query 'kind("cc_library", deps(//build:kong))'`: list all C/C++ dependencies of the `kong` target.
- `bin/bazel query 'deps(//build:kong)' --output graph` > kong_dependency_graph.dot: generate a dependency graph of the `kong` target in the DOT format, we can use [Graphviz](https://graphviz.org/) to visualize the graph.

We can learn more about Bazel query from [Bazel query](https://bazel.build/versions/6.0.0/query/quickstart).

### Build Options

Following build options can be used to set specific features:

- **`--//:debug=true`**
  - Default to true.
  - Turn on debug options and debugging symbols for OpenResty, LuaJIT and OpenSSL, which useful for debug with GDB and SystemTap.

- **`--action_env=BUILD_NAME=`**
  - Default to `kong-dev`.
  - Set the `build_name`, multiple build can exist at same time to allow you
switch between different Kong versions or branches. Don't set this when you are
building a building an binary package.

- **`--action_env=INSTALL_DESTDIR=`**
  - Default to `bazel-bin/build/<BUILD_NAME>`.
  - Set the directory when the build is intended to be installed. Bazel won't
actually install files into this directory, but this will make sure certain hard coded paths and RPATH is correctly set when building a package.

Command example:

```bash
build:release --//:debug=false
build:release --action_env=BUILD_NAME=kong-dev
build:release --action_env=INSTALL_DESTDIR=/usr/local
```

### Official build

`--config release` specifies the build configuration to use for release.

For the official release behavior, some build options are fixed, so they are defined in the `Release flags` in [.bazelrc](../.bazelrc). Read [bazlerc](https://bazel.build/run/bazelrc) for more information.

To build an official release, use:

```bash
bazel build --config release //build:kong --verbose_failures
```

Supported build targets for binary packages:

- `:kong_deb`
- `:kong_el8`
- `:kong_aws2`
- `:kong_aws2023`

For example, to build the deb package:

```bash
bazel build --verbose_failures --config release :kong_deb
```

and we can find the package which named `kong.amd64.deb` in `bazel-bin/pkg`.

#### GPG Signing

GPG singing is supported for the rpm packages (`el*` and `aws*`).

```bash
bazel build //:kong_el8 --action_env=RPM_SIGNING_KEY_FILE --action_env=NFPM_RPM_PASSPHRASE
```

- `RPM_SIGNING_KEY_FILE`: the path to the GPG private key file.
- `NFPM_RPM_PASSPHRASE`: the passphrase of the GPG private key.

#### ngx_wasm_module options

Building of [ngx_wasm_module](https://github.com/Kong/ngx_wasm_module) can be
controlled with a few CLI flags:

* `--//:wasmx=(true|false)` (default: `true`) - enable/disable wasmx
* `--//:wasmx_module_flag=(dynamic|static)` (default: `dynamic`) - switch
    between static or dynamic nginx module build configuration
* `--//:wasm_runtime=(wasmtime|wasmer|v8)` (default: `wasmtime`) select the wasm
    runtime to build

Additionally, there are a couple environment variables that can be set at build
time to control how the ngx_wasm_module repository is sourced:

* `NGX_WASM_MODULE_REMOTE` (default: `https://github.com/Kong/ngx_wasm_module.git`) -
    this can be set to a local filesystem path to avoid pulling the repo from github
* `NGX_WASM_MODULE_BRANCH` (default: none) - Setting this environment variable
    tells bazel to build from a branch rather than using the tag found in our
    `.requirements` file

## Cross compiling

Cross compiling is currently only tested on Ubuntu 22.04/24.04 x86_64 with following targeting platforms:

- **//:generic-crossbuild-aarch64** Use the system installed aarch64 toolchain.
  - Requires user to manually install `crossbuild-essential-arm64` on Debian/Ubuntu.
- **//:vendor_name-crossbuild-aarch64** Target to Redhat based Linux aarch64; bazel manages the build toolchain, `vendor_name`
can be any of `rhel8`, `rhel9`, `aws2` or `aws2023`.
- **//:aws2-crossbuild-x86_64** Target to AmazonLinux 2 x86_64; bazel manages the build toolchain.

Make sure platforms are selected both in building Kong and packaging kong:

```bash
bazel build --config release //build:kong --platforms=//:generic-crossbuild-aarch64
bazel build --config release :kong_deb --platforms=//:generic-crossbuild-aarch64
```

## Troubleshooting

Run `bazel build` with `--sandbox_debug --verbose_failures` to get more information about the error.

The `.log` files in `bazel-bin` contain the build logs.

## FAQ

### Cleanup

In some cases where the build fails or the build is interrupted, the build system may leave behind some temporary files. To clean up the build system, run the following command or simply rerun the build:

```bash
bazel clean
```

Bazel utilizes a cache to speed up the build process. You might want to clear the cache actively
if you recently changed `BUILD_NAME` or `INSTALL_DESTDIR`.

To completely remove the entire working tree created by a Bazel instance, run:

```bash
bazel clean --expunge
```

### Bazel Loading Order

Bazel's file loading order primarily depends on the order of `load()` statements in the `WORKSPACE` and `BUILD` files.

1. Bazel first loads the `WORKSPACE` file. In the `WORKSPACE` file, `load()` statements are executed in order from top to bottom. These `load()` statements load external dependencies and other `.bzl` files.
2. Next, when building a target, Bazel loads the corresponding BUILD file according to the package where the target is located. In the `BUILD` file, `load()` statements are also executed in order from top to bottom. These `load()` statements are usually used to import macro and rule definitions.

Note:

1. In Bazel's dependency tree, the parent target's `BUILD` file is loaded before the child target's `BUILD` file.
2. Bazel caches loaded files during the build process. This means that when multiple targets reference the same file, that file is only loaded once.

### Known Issues

- On macOS, the build may not work with only Command Line Tools installed, you will typically see errors like `../libtool: line 154: -s: command not found`. In such case, installing Xcode should fix the issue.
- If you have configure `git` to use SSH protocol to replace HTTPS protocol, but haven't setup SSH agent, you might see errors like `error: Unable to update registry crates-io`. In such case, set `export CARGO_NET_GIT_FETCH_WITH_CLI=true` to use `git` command line to fetch the repository.
