#!/bin/bash
image=$1
label=$2

container_id=$(docker run -d --entrypoint "/bin/bash" "$image" -c "tail -f /dev/null")

cleanup() {
    docker stop "$container_id" >/dev/null 2>&1
    docker rm "$container_id" >/dev/null 2>&1
}

trap cleanup EXIT

remove_kong_command() {
    local remove_cmd=""

    case "$label" in
        "ubuntu"| "debian")
            remove_cmd="apt-get remove -y kong"
            ;;
        "rhel")
            remove_cmd="yum remove -y kong"
            ;;
        *)
            echo "Unsupported operating system: $label" >&2
            return 1
    esac
    echo "$remove_cmd"
}

if ! remove_cmd=$(remove_kong_command); then
    echo "Failed to get remove command"
    exit 1
fi

docker exec -u root "$container_id" bash -c "$remove_cmd" >/dev/null 2>&1

dir=(
  "/usr/local/kong/include"
  "/usr/local/kong/lib"
  "/usr/local/share/lua/5.1"
  "/usr/local/openresty"
)

for d in "${dir[@]}"
do
  docker exec -u root "$container_id" bash -c "test -d $d"
  result=$?
  if [ $result -eq 0 ]; then
    echo "Failed to uninstall Kong, $d still exists"
    exit 1
  fi
done

exit 0
