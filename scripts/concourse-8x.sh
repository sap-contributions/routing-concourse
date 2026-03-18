#!/bin/bash -e

NEW_VERSION="${1:-8.1.0}"

pushd /concourse

  CURRENT_VERSION=$(grep '^export concourse_version=' docker-versions.sh | cut -d'"' -f2)
  if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
    echo "Concourse is already at version $NEW_VERSION in docker-versions.sh."
    echo "Continuing anyway to ensure the VM is in sync..."
  fi

  NEW_MAJOR=$(echo "$NEW_VERSION" | cut -d. -f1)
  CUR_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
  if [ "$NEW_MAJOR" -gt "$CUR_MAJOR" ]; then
    echo "### NOTICE: Major version bump $CURRENT_VERSION → $NEW_VERSION"
    echo "    Concourse will run DB schema migrations automatically on first startup."
    echo "    Pipeline history and build logs will be preserved."
    echo "    Make sure you have a recent DB backup before continuing."
    echo ""
  fi

  read -r -p "### Upgrade Concourse $CURRENT_VERSION → $NEW_VERSION? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "### Upgrade cancelled."
    popd
    exit 0
  fi
  source .concourse.env

  BACKUP_DIR=/concourse/db-backups
  BACKUP_FILE="$BACKUP_DIR/concourse_${CURRENT_VERSION}_$(date +%Y%m%d_%H%M%S).sql.gz"
  mkdir -p "$BACKUP_DIR"
  echo "### Backing up Postgres database to $BACKUP_FILE ..."
  docker compose exec -T db \
    pg_dump -U concourse_user concourse | gzip > "$BACKUP_FILE"
  echo "### Backup complete: $BACKUP_FILE ($(du -sh "$BACKUP_FILE" | cut -f1))"
  echo ""

  echo "### Updating concourse_version: $CURRENT_VERSION → $NEW_VERSION in docker-versions.sh ..."
  sed -i.bak "s/^export concourse_version=.*/export concourse_version=\"$NEW_VERSION\"/" docker-versions.sh
  rm -f docker-versions.sh.bak
  source docker-versions.sh

  echo "### Gracefully retiring Concourse worker (SIGUSR2) ..."
  docker compose kill -s SIGUSR2 worker || true

  echo -n "### Waiting for worker to finish in-flight builds ..."
  TIMEOUT=300
  ELAPSED=0
  while true; do
    STATUS=$(docker compose ps --status running worker 2>/dev/null | tail -n +2 | wc -l || echo "0")
    [ "$STATUS" = "0" ] && break
    echo -n '.'
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $ELAPSED -ge $TIMEOUT ]; then
      echo ""
      echo "WARNING: Worker did not stop within ${TIMEOUT}s — forcing stop."
      docker compose stop worker
      break
    fi
  done
  echo ""

  echo "### Pulling Concourse $NEW_VERSION images ..."
  docker compose pull web worker

  # db and nginx are intentionally left running.
  # web must start first so it can run DB migrations; worker connects after web is ready.
  echo "### Restarting web with Concourse $NEW_VERSION (DB migrations will run now) ..."
  docker compose up -d --no-deps web

  echo -n "### Waiting for Concourse to become healthy (includes DB migration) ..."
  TIMEOUT=600
  ELAPSED=0
  while ! curl -fso /dev/null http://localhost/api/v1/info 2>/dev/null; do
    echo -n '.'
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $ELAPSED -ge $TIMEOUT ]; then
      echo ""
      echo "ERROR: Concourse did not become healthy within ${TIMEOUT}s." >&2
      echo "       Check logs with: docker compose logs --tail=80 web" >&2
      exit 1
    fi
  done
  echo ""

  echo "### Starting worker with Concourse $NEW_VERSION ..."
  docker compose up -d --no-deps worker

  echo "### Updating fly CLI to $NEW_VERSION ..."
  curl -fso /usr/local/bin/fly 'http://localhost/api/v1/cli?arch=amd64&platform=linux'
  chmod +x /usr/local/bin/fly

  echo "### Pruning old Docker images ..."
  docker image prune -f

  echo ""
  echo "### Upgrade complete: Concourse $CURRENT_VERSION → $NEW_VERSION"

popd
