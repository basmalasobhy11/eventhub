#!/usr/bin/env bash
set -euo pipefail

NETWORK="eventhub-net"

MYSQL="eventhub-mysql"
POSTGRES="eventhub-postgres"
MONGO="eventhub-mongo"
REDIS="eventhub-redis"
RABBITMQ="eventhub-rabbitmq"

echo "=========================================="
echo " EventHub Phase 2 - Podman"
echo "=========================================="

# --------------------------------------------------
# Helpers
# --------------------------------------------------

remove_container() {
    podman rm -f "$1" >/dev/null 2>&1 || true
}

wait_mysql() {
    echo "Waiting for MySQL..."

    for i in {1..60}; do
        if podman exec "$MYSQL" \
            mysqladmin ping -h 127.0.0.1 -uroot -prootpassword \
            --silent >/dev/null 2>&1; then
            echo "MySQL is ready."
            return 0
        fi
        sleep 2
    done

    echo "ERROR: MySQL did not become ready."
    podman logs "$MYSQL"
    exit 1
}

wait_postgres() {
    echo "Waiting for PostgreSQL..."

    for i in {1..60}; do
        if podman exec "$POSTGRES" \
            pg_isready -U eventhub -d eventhub_auth \
            >/dev/null 2>&1; then
            echo "PostgreSQL is ready."
            return 0
        fi
        sleep 2
    done

    echo "ERROR: PostgreSQL did not become ready."
    podman logs "$POSTGRES"
    exit 1
}

wait_mongo() {
    echo "Waiting for MongoDB..."

    for i in {1..60}; do
        if podman exec "$MONGO" \
            mongosh --quiet --eval "db.adminCommand({ping:1}).ok" \
            2>/dev/null | grep -q "1"; then
            echo "MongoDB is ready."
            return 0
        fi
        sleep 2
    done

    echo "ERROR: MongoDB did not become ready."
    podman logs "$MONGO"
    exit 1
}

wait_redis() {
    echo "Waiting for Redis..."

    for i in {1..60}; do
        if podman exec "$REDIS" redis-cli ping 2>/dev/null | grep -q PONG; then
            echo "Redis is ready."
            return 0
        fi
        sleep 2
    done

    echo "ERROR: Redis did not become ready."
    podman logs "$REDIS"
    exit 1
}

wait_rabbitmq() {
    echo "Waiting for RabbitMQ..."

    for i in {1..60}; do
        if podman exec "$RABBITMQ" \
            rabbitmq-diagnostics -q ping \
            >/dev/null 2>&1; then
            echo "RabbitMQ is ready."
            return 0
        fi
        sleep 2
    done

    echo "ERROR: RabbitMQ did not become ready."
    podman logs "$RABBITMQ"
    exit 1
}

wait_health() {
    local container="$1"

    echo "Waiting for $container..."

    for i in {1..60}; do
        status=$(podman inspect \
            --format '{{.State.Healthcheck.Status}}' \
            "$container" 2>/dev/null || true)

        if [[ "$status" == "healthy" ]]; then
            echo "$container is healthy."
            return 0
        fi

        if [[ "$status" == "unhealthy" ]]; then
            echo "ERROR: $container is unhealthy."
            podman logs "$container"
            exit 1
        fi

        sleep 2
    done

    echo "ERROR: $container did not become healthy."
    podman logs "$container" || true
    exit 1
}

# --------------------------------------------------
# Network
# --------------------------------------------------

echo
echo "==> Creating Podman network..."

if ! podman network inspect "$NETWORK" >/dev/null 2>&1; then
    podman network create "$NETWORK"
else
    echo "Network already exists."
fi

# --------------------------------------------------
# Volumes
# --------------------------------------------------

echo
echo "==> Creating persistent volumes..."

podman volume inspect eventhub-mysql-data >/dev/null 2>&1 || \
    podman volume create eventhub-mysql-data

podman volume inspect eventhub-postgres-data >/dev/null 2>&1 || \
    podman volume create eventhub-postgres-data

podman volume inspect eventhub-mongo-data >/dev/null 2>&1 || \
    podman volume create eventhub-mongo-data

podman volume inspect eventhub-redis-data >/dev/null 2>&1 || \
    podman volume create eventhub-redis-data

podman volume inspect eventhub-rabbitmq-data >/dev/null 2>&1 || \
    podman volume create eventhub-rabbitmq-data

# --------------------------------------------------
# Remove old containers
# --------------------------------------------------

echo
echo "==> Removing old infrastructure containers..."

remove_container "$MYSQL"
remove_container "$POSTGRES"
remove_container "$MONGO"
remove_container "$REDIS"
remove_container "$RABBITMQ"

# --------------------------------------------------
# Infrastructure
# --------------------------------------------------

echo
echo "==> Starting MySQL..."

podman run -d \
    --name "$MYSQL" \
    --network "$NETWORK" \
    -e MYSQL_ROOT_PASSWORD=rootpassword \
    -e MYSQL_DATABASE=eventhub_catalog \
    -v eventhub-mysql-data:/var/lib/mysql \
    docker.io/library/mysql:8.0

wait_mysql

echo
echo "==> Seeding MySQL..."

podman exec -i "$MYSQL" \
    mysql -uroot -prootpassword \
    < db-seed/mysql-seed.sql


echo
echo "==> Starting PostgreSQL..."

podman run -d \
    --name "$POSTGRES" \
    --network "$NETWORK" \
    -e POSTGRES_USER=eventhub \
    -e POSTGRES_PASSWORD=eventhub \
    -e POSTGRES_DB=eventhub_auth \
    -v eventhub-postgres-data:/var/lib/postgresql/data \
    docker.io/library/postgres:16

wait_postgres


echo
echo "==> Starting MongoDB..."

podman run -d \
    --name "$MONGO" \
    --network "$NETWORK" \
    -v eventhub-mongo-data:/data/db \
    docker.io/library/mongo:7

wait_mongo

echo
echo "==> Starting Redis..."

podman run -d \
    --name "$REDIS" \
    --network "$NETWORK" \
    -v eventhub-redis-data:/data \
    docker.io/library/redis:7 \
    redis-server --appendonly yes

wait_redis

echo
echo "==> Starting RabbitMQ..."

podman run -d \
    --name "$RABBITMQ" \
    --network "$NETWORK" \
    -e RABBITMQ_DEFAULT_USER=guest \
    -e RABBITMQ_DEFAULT_PASS=guest \
    -v eventhub-rabbitmq-data:/var/lib/rabbitmq \
    docker.io/library/rabbitmq:3-management

wait_rabbitmq

# --------------------------------------------------
# Build images
# --------------------------------------------------

echo
echo "=========================================="
echo " Building application images"
echo "=========================================="

podman build --format docker \
    -t eventhub-ai-insight \
    -f services/ai-insight-service-python/Containerfile \
    services/ai-insight-service-python

podman build --format docker \
    -t eventhub-analytics \
    -f services/analytics-service-python/Containerfile \
    services/analytics-service-python

podman build --format docker \
    -t eventhub-auth \
    -f services/auth-service-node/Containerfile \
    services/auth-service-node

podman build --format docker \
    -t eventhub-booking \
    -f services/booking-service-python/Containerfile \
    services/booking-service-python

podman build --format docker \
    -t eventhub-catalog \
    -f services/legacy-catalog-java/Containerfile \
    services/legacy-catalog-java

podman build --format docker \
    -t eventhub-notification \
    -f services/notification-worker-go/Containerfile \
    services/notification-worker-go

podman build --format docker \
    -t eventhub-gateway \
    -f gateway/Containerfile \
    gateway

podman build --format docker \
    -t eventhub-frontend \
    -f frontend/Containerfile \
    frontend

# --------------------------------------------------
# Application containers
# --------------------------------------------------

echo
echo "==> Starting AI Insight..."

remove_container eventhub-ai-insight

podman run -d \
    --name eventhub-ai-insight \
    --network "$NETWORK" \
    -e PORT=8084 \
    -e OLLAMA_URL="${OLLAMA_URL:-http://host.containers.internal:11434}" \
    -e OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:1b}" \
    eventhub-ai-insight

wait_health eventhub-ai-insight


echo
echo "==> Starting Auth..."

remove_container eventhub-auth

podman run -d \
    --name eventhub-auth \
    --network "$NETWORK" \
    -e PORT=8082 \
    -e PGHOST="$POSTGRES" \
    -e PGPORT=5432 \
    -e PGUSER=eventhub \
    -e PGPASSWORD=eventhub \
    -e PGDATABASE=eventhub_auth \
    -e JWT_SECRET="${JWT_SECRET:-phase2-local-secret}" \
    eventhub-auth

wait_health eventhub-auth


echo
echo "==> Starting Catalog..."

remove_container eventhub-catalog

podman run -d \
    --name eventhub-catalog \
    --network "$NETWORK" \
    -e SERVER_PORT=8081 \
    -e MYSQL_HOST="$MYSQL" \
    -e MYSQL_PORT=3306 \
    -e MYSQL_DATABASE=eventhub_catalog \
    -e MYSQL_USER=root \
    -e MYSQL_PASSWORD=rootpassword \
    eventhub-catalog

wait_health eventhub-catalog


echo
echo "==> Starting Booking..."

remove_container eventhub-booking

podman run -d \
    --name eventhub-booking \
    --network "$NETWORK" \
    -e PORT=8083 \
    -e MONGO_URI="mongodb://${MONGO}:27017" \
    -e MONGO_DB=eventhub_bookings \
    -e RABBITMQ_URL="amqp://guest:guest@${RABBITMQ}:5672/" \
    -e RABBITMQ_QUEUE=bookings \
    -e AI_INSIGHT_URL="http://eventhub-ai-insight:8084" \
    eventhub-booking

wait_health eventhub-booking


echo
echo "==> Seeding MongoDB..."

podman cp db-seed/mongo-seed.js "$MONGO":/tmp/mongo-seed.js

podman exec "$MONGO" \
    mongosh eventhub_bookings /tmp/mongo-seed.js


echo
echo "==> Starting Notification Worker..."

remove_container eventhub-notification

podman run -d \
    --name eventhub-notification \
    --network "$NETWORK" \
    -e RABBITMQ_URL="amqp://guest:guest@${RABBITMQ}:5672/" \
    -e RABBITMQ_QUEUE=bookings \
    eventhub-notification


echo
echo "==> Starting Analytics API..."

remove_container eventhub-analytics

podman run -d \
    --name eventhub-analytics \
    --network "$NETWORK" \
    -e PORT=8085 \
    -e REDIS_URL="redis://${REDIS}:6379/0" \
    -e BOOKING_SERVICE_URL="http://eventhub-booking:8083" \
    -e CATALOG_SERVICE_URL="http://eventhub-catalog:8081" \
    -e SNAPSHOT_KEY=analytics:snapshot \
    eventhub-analytics

wait_health eventhub-analytics


echo
echo "==> Starting Gateway..."

remove_container eventhub-gateway

podman run -d \
    --name eventhub-gateway \
    --network "$NETWORK" \
    -p 8080:8080 \
    -e PORT=8080 \
    -e AUTH_URL="http://eventhub-auth:8082" \
    -e CATALOG_URL="http://eventhub-catalog:8081" \
    -e BOOKING_URL="http://eventhub-booking:8083" \
    -e AI_INSIGHT_URL="http://eventhub-ai-insight:8084" \
    -e ANALYTICS_URL="http://eventhub-analytics:8085" \
    -e FRONTEND_ORIGIN="http://localhost:3000" \
    eventhub-gateway

wait_health eventhub-gateway


echo
echo "==> Starting Frontend..."

remove_container eventhub-frontend

podman run -d \
    --name eventhub-frontend \
    --network "$NETWORK" \
    -p 3000:80 \
    eventhub-frontend

wait_health eventhub-frontend


# --------------------------------------------------
# Analytics job
# --------------------------------------------------

echo
echo "=========================================="
echo " Running analytics job"
echo "=========================================="

podman run --rm \
    --network "$NETWORK" \
    -e REDIS_URL="redis://${REDIS}:6379/0" \
    -e BOOKING_SERVICE_URL="http://eventhub-booking:8083" \
    -e CATALOG_SERVICE_URL="http://eventhub-catalog:8081" \
    -e SNAPSHOT_KEY=analytics:snapshot \
    eventhub-analytics \
    python job.py


# --------------------------------------------------
# Final status
# --------------------------------------------------

echo
echo "=========================================="
echo " EventHub Phase 2 is READY"
echo "=========================================="

echo
echo "Frontend:"
echo "  http://localhost:3000"

echo
echo "Gateway:"
echo "  http://localhost:8080"

echo
echo "Containers:"
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
