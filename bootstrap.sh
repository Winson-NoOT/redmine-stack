#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# 1. Generate .env with random secrets if missing
if [[ ! -f .env ]]; then
  echo "==> Generating .env with random DB_PASSWORD + SECRET_KEY_BASE"
  DB_PASS=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 32)
  SKB=$(openssl rand -hex 64)
  cat > .env <<EOF
DB_PASSWORD=${DB_PASS}
SECRET_KEY_BASE=${SKB}
REDMINE_PORT=3000
EOF
fi

# 2. Clone the two plugin forks if not already present
clone_plugin() {
  local name="$1" repo="$2"
  if [[ -d "plugins/${name}/.git" ]]; then
    echo "==> plugins/${name} present, skipping clone"
  else
    echo "==> Cloning ${repo} -> plugins/${name}"
    git clone --depth 1 "${repo}" "plugins/${name}"
  fi
}
clone_plugin redmine_mcp                       https://github.com/Winson-NoOT/redmine_mcp.git
clone_plugin redmine_issue_update_statistics   https://github.com/Winson-NoOT/redmine_issue_update_statistics.git

# 3. Boot the stack
echo "==> docker compose up -d"
docker compose up -d

# 4. Wait for Redmine container to have the Gemfile mounted and Rails available
echo "==> Waiting for Redmine container to be ready"
for i in $(seq 1 60); do
  if docker compose exec -T redmine test -f /usr/src/redmine/Gemfile 2>/dev/null; then
    break
  fi
  sleep 2
done

# 5. Install plugin gems (run as root because some plugins bundle native extensions)
echo "==> bundle install (covers plugins with their own Gemfile)"
docker compose exec -T -u root redmine bundle install

# 6. Run plugin migrations
echo "==> rake redmine:plugins:migrate"
docker compose exec -T -u root -e RAILS_ENV=production redmine \
  bundle exec rake redmine:plugins:migrate

# 7. Restart so the running Rails process picks up the freshly migrated plugins
echo "==> Restarting Redmine"
docker compose restart redmine

PORT=$(grep -E '^REDMINE_PORT=' .env | cut -d= -f2)
PORT=${PORT:-3000}

cat <<EOF

Redmine is up: http://localhost:${PORT}
  First login: admin / admin  (you'll be forced to change it)

Configure plugins after first login:
  - Administration -> MCP Authorizations            (for redmine_mcp)
  - Administration -> Plugins -> Redmine Issue Update Statistics -> Configure

To stop:    docker compose down
To wipe:    docker compose down -v   (deletes pgdata + uploaded files)
EOF
