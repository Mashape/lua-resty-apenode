"""
Global variables
"""

def _load_vars(ctx):
    # Read env from .requirements
    requirements = ctx.read(Label("@kong//:.requirements"))
    content = ctx.execute(["bash", "-c", "echo '%s' | " % requirements +
                                         """grep -E '^(\\w*)=(.+)$' | sed -E 's/^(.*)=([^# ]+).*$/"\\1": "\\2",/'"""]).stdout
    content = content.replace('""', '"')

    # Workspace path
    workspace_path = "%s" % ctx.path(Label("@//:WORKSPACE")).dirname
    content += '"WORKSPACE_PATH": "%s",\n' % workspace_path

    # Local env
    # Temporarily fix for https://github.com/bazelbuild/bazel/issues/14693#issuecomment-1079006291
    for key in [
        "GITHUB_TOKEN",
        "RPM_SIGNING_KEY_FILE",
        "NFPM_RPM_PASSPHRASE",
    ]:
        value = ctx.os.environ.get(key, "")
        if value:
            content += '"%s": "%s",\n' % (key, value)

    build_name = ctx.os.environ.get("BUILD_NAME", "")
    content += '"BUILD_NAME": "%s",\n' % build_name

    install_destdir = ctx.os.environ.get("INSTALL_DESTDIR", "MANAGED")
    if install_destdir == "MANAGED":
        # this has to be absoluate path to make build scripts happy and artifacts being portable
        install_destdir = workspace_path + "/bazel-bin/build/" + build_name
    content += '"INSTALL_DESTDIR": "%s",\n' % install_destdir

    # Kong Version
    # TODO: this may not change after a bazel clean if cache exists
    kong_version = ctx.execute(["bash", "scripts/grep-kong-version.sh"], working_directory = workspace_path).stdout
    content += '"KONG_VERSION": "%s",' % kong_version.strip()

    if ctx.os.name == "mac os x":
        nproc = ctx.execute(["sysctl", "-n", "hw.ncpu"]).stdout.strip()
    else:  # assume linux
        nproc = ctx.execute(["nproc"]).stdout.strip()

    content += '"%s": "%s",' % ("NPROC", nproc)

    macos_target = ""
    if ctx.os.name == "mac os x":
        macos_target = ctx.execute(["sw_vers", "-productVersion"]).stdout.strip()
    content += '"MACOSX_DEPLOYMENT_TARGET": "%s",' % macos_target

    # convert them into a list of labels relative to the workspace root
    # TODO: this may not change after a bazel clean if cache exists
    patches = sorted([
        '"@kong//:%s"' % str(p).replace(workspace_path, "").lstrip("/")
        for p in ctx.path(workspace_path + "/build/openresty/patches").readdir()
    ])

    content += '"OPENRESTY_PATCHES": [%s],' % (", ".join(patches))

    ngx_wasmx_module_remote = ctx.os.environ.get("NGX_WASM_MODULE_REMOTE", "https://github.com/Kong/ngx_wasm_module.git")
    content += '"NGX_WASM_MODULE_REMOTE": "%s",' % ngx_wasmx_module_remote

    ngx_wasmx_module_branch = ctx.os.environ.get("NGX_WASM_MODULE_BRANCH", "")
    content += '"NGX_WASM_MODULE_BRANCH": "%s",' % ngx_wasmx_module_branch

    ctx.file("BUILD.bazel", "")
    ctx.file("variables.bzl", "KONG_VAR = {\n" + content + "\n}")

def _check_sanity(ctx):
    if ctx.os.name == "mac os x":
        xcode_prefix = ctx.execute(["xcode-select", "-p"]).stdout.strip()
        if "CommandLineTools" in xcode_prefix:
            fail("Command Line Tools is not supported, please install Xcode from App Store.\n" +
                 "If you recently installed Xcode, please run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` to switch to Xcode,\n" +
                 "then do a `bazel clean --expunge` and try again.\n" +
                 "The following command is useful to check if Xcode is picked up by Bazel:\n" +
                 "eval `find /private/var/tmp/_bazel_*/|grep xcode-locator|head -n1`")

    user = ctx.os.environ.get("USER", "")
    if "@" in user:
        fail("Bazel uses $USER in cache and rule_foreign_cc uses `@` in its sed command.\n" +
             "However, your username contains a `@` character, which will cause build failure.\n" +
             "Please rerun this build with:\n" +
             "export USER=" + user.replace("@", "_") + " bazel build <target>")

    for sub_dir in ["kong-gql", "lua-resty-openapi3-deserializer"]:
        mod = ctx.workspace_root.get_child("./distribution/%s" % sub_dir)
        if not mod.exists:
            continue
        if len(mod.readdir()) == 0:
            fail("Please run following commmand to initialize submodules, as 'distribution/" + sub_dir + "' is empty:\n" +
                 "git submodule update --init\n\n" +
                 "If you frequently switch between different branches, consider set git to automatically fetch submodules:\n" +
                 "git config submodule.recurse true")

def _load_bindings_impl(ctx):
    _check_sanity(ctx)

    _load_vars(ctx)

load_bindings = repository_rule(
    implementation = _load_bindings_impl,
    # force "fetch"/invalidation of this repository every time it runs
    # so that environ vars, patches and kong version is up to date
    # see https://blog.bazel.build/2017/02/22/repository-invalidation.html
    local = True,
    environ = [
        "BUILD_NAME",
        "INSTALL_DESTDIR",
        "RPM_SIGNING_KEY_FILE",
        "NFPM_RPM_PASSPHRASE",
        "GITHUB_TOKEN",
        "NGX_WASM_MODULE_BRANCH",
        "NGX_WASM_MODULE_REMOTE",
    ],
)
