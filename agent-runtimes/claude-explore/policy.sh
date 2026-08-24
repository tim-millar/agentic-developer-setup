#!/bin/bash
# Framework-owned policy for claude-explore. Loaded only by trusted Bash.

CLAUDE_EXPLORE_RUNTIME_ID=claude-explore
CLAUDE_EXPLORE_RUNTIME_VERSION=1
CLAUDE_EXPLORE_POLICY_SCHEMA_VERSION=1
CLAUDE_EXPLORE_POLICY_VERSION=1
CLAUDE_EXPLORE_MINIMUM_CLIENT_VERSION=2.1.224
CLAUDE_EXPLORE_RUNTIME_FAILURE_STATUS=1
CLAUDE_EXPLORE_MALFORMED_STATUS=2
CLAUDE_EXPLORE_GUARD_FAILURE_STATUS=125
CLAUDE_EXPLORE_BLOCKED_STATUS=126
CLAUDE_EXPLORE_BLOCKED_PREFIX=CLAUDE_EXPLORE_BLOCKED
CLAUDE_EXPLORE_CLASSIFICATION_PREFIX=CLAUDE_EXPLORE_CLASSIFICATION

CLAUDE_EXPLORE_NATIVE_CONTROLS='sandbox.enabled=true
sandbox.failIfUnavailable=true
sandbox.allowUnsandboxedCommands=false
sandbox.filesystem.disabled=false
disableAllHooks=true
disableArtifact=true
strictMcpConfig=true
chrome=false'

CLAUDE_EXPLORE_ENV_SET='GIT_TERMINAL_PROMPT=0
GCM_INTERACTIVE=never
AWS_EC2_METADATA_DISABLED=true
CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1
CLAUDE_CODE_DISABLE_ARTIFACT=1
GH_CONFIG_DIR=<private-session-directory>
GIT_ASKPASS=<refusal-helper>'

CLAUDE_EXPLORE_BLOCKED_EXECUTABLES='gh
aws
gcloud
az
kubectl
helm
terraform
tofu
pulumi
packer
vault
nomad
consul
heroku
vercel
netlify
fly
flyctl
ssh
scp
sftp
docker
docker-compose
podman
podman-compose
mysql
mariadb
redis-cli
mongo
mongosh'

CLAUDE_EXPLORE_GUARDED_EXECUTABLES="git
psql
$CLAUDE_EXPLORE_BLOCKED_EXECUTABLES"

CLAUDE_EXPLORE_ENV_UNSET='GITHUB_TOKEN
GH_TOKEN
GH_ENTERPRISE_TOKEN
GITHUB_ENTERPRISE_TOKEN
GITHUB_PAT
SSH_AUTH_SOCK
SSH_AGENT_PID
GIT_SSH
GIT_SSH_COMMAND
SSH_ASKPASS
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
AWS_SECURITY_TOKEN
AWS_PROFILE
AWS_DEFAULT_PROFILE
AWS_SHARED_CREDENTIALS_FILE
AWS_CONFIG_FILE
AWS_WEB_IDENTITY_TOKEN_FILE
AWS_ROLE_ARN
AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
AWS_CONTAINER_CREDENTIALS_FULL_URI
GOOGLE_APPLICATION_CREDENTIALS
CLOUDSDK_AUTH_ACCESS_TOKEN
AZURE_CLIENT_ID
AZURE_CLIENT_SECRET
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
ARM_CLIENT_ID
ARM_CLIENT_SECRET
ARM_TENANT_ID
ARM_SUBSCRIPTION_ID
KUBECONFIG
TF_CLI_CONFIG_FILE
VERCEL_TOKEN
NETLIFY_AUTH_TOKEN
HEROKU_API_KEY
FLY_API_TOKEN
DOCKER_HOST
DOCKER_CONTEXT
DOCKER_CONFIG
DATABASE_URL
REDIS_URL
PGHOST
PGHOSTADDR
PGPORT
PGDATABASE
PGUSER
PGPASSWORD
PGPASSFILE
PGSERVICE
PGSERVICEFILE
MYSQL_PWD
MONGODB_URI
NPM_TOKEN
NODE_AUTH_TOKEN
GEM_HOST_API_KEY
PYPI_TOKEN
CLAUDE_EXPLORE_POLICY
CLAUDE_EXPLORE_GIT_BIN
CLAUDE_EXPLORE_PSQL_BIN'

CLAUDE_EXPLORE_PG_ENV='PGHOST
PGHOSTADDR
PGPORT
PGDATABASE
PGUSER
PGPASSWORD
PGPASSFILE
PGSERVICE
PGSERVICEFILE'

CLAUDE_EXPLORE_CREDENTIAL_PATHS='~/.ssh
~/.aws
~/.azure
~/.config/gcloud
~/.kube
~/.config/gh
~/.git-credentials
~/.netrc
~/.docker/config.json
~/.npmrc
~/.pypirc
~/.gem/credentials'

CLAUDE_EXPLORE_ALLOWED_GIT='add apply bisect blame cat-file checkout cherry-pick commit describe diff diff-tree for-each-ref grep init log merge merge-base mv name-rev rebase reflog reset restore rev-list rev-parse rm shortlog show show-ref stash status switch worktree'
CLAUDE_EXPLORE_BLOCKED_GIT='push fetch pull clone ls-remote credential credential-cache credential-store send-email imap-send submodule'
CLAUDE_EXPLORE_GIT_SPECIAL='branch remote config tag'

CLAUDE_EXPLORE_ALLOWED_PERMISSION_MODES='default manual acceptEdits plan auto dontAsk'
CLAUDE_EXPLORE_CLAUDE_VALUE_FLAGS='--model --effort --fallback-model --autocompact --name -n --resume -r --session-id --permission-mode'
CLAUDE_EXPLORE_CLAUDE_BOOLEAN_FLAGS='--help --version -v --continue -c --fork-session --verbose --debug --ax-screen-reader --disable-slash-commands --no-chrome'
CLAUDE_EXPLORE_CLAUDE_BLOCKED_FLAGS='--dangerously-skip-permissions --allow-dangerously-skip-permissions --settings --setting-sources --mcp-config --strict-mcp-config --permission-prompt-tool --plugin-dir --plugin-url --agent --agents --channels --dangerously-load-development-channels --chrome --cloud --remote --environment --remote-control --rc --teleport --add-dir --worktree -w --tmux --from-pr --bg --background --exec --print -p --safe-mode --bare --system-prompt --system-prompt-file --append-system-prompt --append-system-prompt-file --append-subagent-system-prompt --allowedTools --allowed-tools --disallowedTools --disallowed-tools --tools --init --init-only --maintenance --debug-file'
CLAUDE_EXPLORE_CLAUDE_BLOCKED_SUBCOMMANDS='update gateway install auth agents attach auto-mode daemon doctor import logs mcp plugin plugins project remote-control respawn rm self-hosted-runner setup-token stop kill ultrareview'

CLAUDE_EXPLORE_GUIDANCE='claude-explore is a supervised reduced-authority runtime. CLAUDE_EXPLORE_BLOCKED results are intentional: report them and suggest a safe local alternative. Do not bypass guards, launch unrestricted Claude, restore stripped credentials, invoke alternate binaries to evade policy, or edit installed runtime, policy, metadata, or session controls.'
