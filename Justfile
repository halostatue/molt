_default:
    just --list

@test:
    gleam test --target erlang
    gleam test --target javascript

@build:
    gleam build

@lint:
    gleam run -m glinter

@format:
    gleam format

@format-check:
    gleam format --check src test

@docs:
    gleam docs build

@docs-open: docs
    open build/dev/docs/molt/index.html

# Update toml-test fixtures from the latest upstream release tag
update-toml-fixtures:
    #!/usr/bin/env bash
    set -euo pipefail

    repo=https://github.com/toml-lang/toml-test.git

    tag=$(git ls-remote --tags --sort=-v:refname "$repo" \
        | grep -oE 'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
        | head -n1 | sed 's@refs/tags/@@')

    if [[ -z "${tag}" ]]; then
        echo "Could not determine latest toml-test tag" >&2
        exit 1
    fi

    echo "Latest toml-test release: ${tag}"
    rm -rf /tmp/toml-test
    git clone --depth 1 --branch "${tag}" "$repo" /tmp/toml-test
    rm -rf test/toml-fixtures
    cp -r /tmp/toml-test/tests test/toml-fixtures
    cp /tmp/toml-test/LICENSE licences/MIT.txt
    echo "${tag}" > test/toml-fixtures/VERSION
    rm -rf /tmp/toml-test
    echo "Updated fixtures to toml-test ${tag}"

# Create the agent sandbox VM
agent-create branch="agent-work":
    #!/usr/bin/env bash
    target=~/oss/agent/molt

    if ! [[ -d "$target" ]]; then
        if git rev-parse --verify "{{ branch }}" >/dev/null 2>&1; then
            git clone --branch "{{ branch }}" . "$target"
        else
            git clone . "$target"
            git -C "$target" checkout -b "{{ branch }}"
        fi
    fi

    limactl create --tty=false --name=molt-agent <(sed "s!WORKSPACE_LOCATION!${target}!" ./molt-agent.yaml)

# Start and shell into the agent sandbox
@agent-run:
    limactl start molt-agent >/dev/null 2>&1
    limactl shell molt-agent

# Stop the agent sandbox VM
@agent-stop:
    limactl stop molt-agent

# Delete the agent sandbox VM entirely
@agent-destroy:
    limactl delete --force molt-agent
