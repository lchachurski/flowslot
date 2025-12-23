#!/bin/bash
# flowslot-ports.sh - Project-specific port definitions for flowslot
# Place this file in your project root alongside docker-compose files
#
# Available variables from flowslot:
#   SLOT            - Slot number (1, 2, 3, ...)
#   SLOT_PORT_BASE  - Base port for this slot (7200, 7300, 7400, ...)
#   SLOT_REMOTE_IP  - Tailscale IP of the remote server
#   COMPOSE_PROJECT_NAME - Unique Docker Compose project name

# ============================================================
# PORT DEFINITIONS
# ============================================================
# Convention: SLOT_PORT_BASE + offset
#   +1 = web/frontend
#   +2 = secondary service
#   +3 = api/backend
#   +4 = database
#   +5-99 = additional services

export SLOT_PORT_WEB=$((SLOT_PORT_BASE + 1))
export SLOT_PORT_API=$((SLOT_PORT_BASE + 3))
export SLOT_PORT_DB=$((SLOT_PORT_BASE + 4))

# Add your project-specific ports below:
# export SLOT_PORT_CACHE=$((SLOT_PORT_BASE + 5))
# export SLOT_PORT_WORKER=$((SLOT_PORT_BASE + 6))
# export SLOT_PORT_QUEUE=$((SLOT_PORT_BASE + 7))

# ============================================================
# UNIQUE NAMES (for stateful services)
# ============================================================
# Container names and volumes must be unique per slot to avoid conflicts

export POSTGRES_CONTAINER_NAME="myapp-postgres-${SLOT}"
export POSTGRES_VOLUME="postgres-data-${SLOT}"

# Add more as needed:
# export REDIS_CONTAINER_NAME="myapp-redis-${SLOT}"
# export REDIS_VOLUME="redis-data-${SLOT}"

