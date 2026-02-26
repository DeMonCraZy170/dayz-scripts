#!/bin/bash
# Script de inicio mejorado para DayZ Server
# Versión profesional con auto-restart y validaciones
# Si existe start-server-enterprise.sh, lo usa automáticamente

set -euo pipefail

# Si existe la versión enterprise, usarla
if [ -f "/mnt/server/scripts/start-server-enterprise.sh" ]; then
    exec bash /mnt/server/scripts/start-server-enterprise.sh "$@"
fi

MAX_RESTART_ATTEMPTS=${MAX_RESTART_ATTEMPTS:-5}
RESTART_DELAY=${RESTART_DELAY:-10}
RESTART_COUNT=0
AUTO_RESTART=${AUTO_RESTART:-1}

# Rotación de logs
MAX_LOG_SIZE=${MAX_LOG_SIZE:-52428800}
LOG_FILE="/mnt/server/server.log"
LOG_OLD="/mnt/server/server.log.old"

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date -Iseconds)
    
    # Rotar log si es muy grande
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$log_size" -gt "$MAX_LOG_SIZE" ]; then
            mv "$LOG_FILE" "$LOG_OLD" 2>/dev/null || true
            touch "$LOG_FILE"
        fi
    fi
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

preflight_checks() {
    log "INFO" "Running pre-flight checks..."
    
    # Verificar binario del servidor
    if [ ! -f "./${SERVER_BINARY:-DayZServer}" ]; then
        log "ERROR" "Server binary not found: ${SERVER_BINARY:-DayZServer}"
        return 1
    fi
    
    # Verificar archivo de configuración
    if [ ! -f "serverDZ.cfg" ]; then
        log "ERROR" "Configuration file not found: serverDZ.cfg"
        return 1
    fi
    
    # Verificar permisos de ejecución
    if [ ! -x "./${SERVER_BINARY:-DayZServer}" ]; then
        log "WARN" "Server binary is not executable, attempting to fix..."
        chmod +x "./${SERVER_BINARY:-DayZServer}" || {
            log "ERROR" "Failed to make server binary executable"
            return 1
        }
    fi
    
    log "SUCCESS" "Pre-flight checks passed"
    return 0
}

start_server() {
    log "INFO" "Starting DayZ server (Attempt: $((RESTART_COUNT + 1)))"
    
    if ! preflight_checks; then
        return 1
    fi
    
    # Construir comando de inicio
    local start_cmd="./${SERVER_BINARY:-DayZServer} \
        -port=${SERVER_PORT:-2302} \
        -profiles=profiles \
        -bepath=./ \
        -config=serverDZ.cfg \
        -mod=${CLIENT_MODS:-} \
        -serverMod=${SERVERMODS:-} \
        ${STARTUP_PARAMS:--dologs -adminlog -netlog -freezecheck}"
    
    log "INFO" "Executing: $start_cmd"
    
    # Ejecutar servidor
    exec $start_cmd 2>&1 | tee -a /mnt/server/server.log
}

# Manejar señales
trap 'log "INFO" "Server stopped by signal"; exit 0' SIGTERM SIGINT

# Loop de auto-restart
if [ "$AUTO_RESTART" -eq 1 ]; then
    while [ $RESTART_COUNT -lt $MAX_RESTART_ATTEMPTS ]; do
        if start_server; then
            log "INFO" "Server exited normally"
            break
        else
            RESTART_COUNT=$((RESTART_COUNT + 1))
            if [ $RESTART_COUNT -lt $MAX_RESTART_ATTEMPTS ]; then
                log "WARN" "Server crashed, restarting in ${RESTART_DELAY}s (${RESTART_COUNT}/${MAX_RESTART_ATTEMPTS})"
                sleep "$RESTART_DELAY"
            else
                log "ERROR" "Max restart attempts reached. Server will not restart."
                exit 1
            fi
        fi
    done
else
    # Sin auto-restart
    start_server
fi
