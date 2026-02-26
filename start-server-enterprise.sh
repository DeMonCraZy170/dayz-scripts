#!/bin/bash
# Script de inicio Enterprise para DayZ Server
# Versión nivel hosting comercial (Nitrado/GTX)
# Incluye: auto-update, backups automáticos, healthcheck, anti-crash, logging rotativo

set -euo pipefail

# Variables de configuración
MAX_RESTART_ATTEMPTS=${MAX_RESTART_ATTEMPTS:-5}
RESTART_DELAY=${RESTART_DELAY:-10}
RESTART_COUNT=0
AUTO_RESTART=${AUTO_RESTART:-1}
AUTO_UPDATE=${AUTO_UPDATE:-1}
AUTO_BACKUP=${AUTO_BACKUP:-1}
BACKUP_INTERVAL=${BACKUP_INTERVAL:-3600}
MAX_BACKUPS=${MAX_BACKUPS:-3}
MAX_LOG_SIZE=${MAX_LOG_SIZE:-52428800}
HEALTH_CHECK_INTERVAL=${HEALTH_CHECK_INTERVAL:-30}

# Archivos de log
LOG_FILE="/mnt/server/server.log"
LOG_OLD="/mnt/server/server.log.old"
BACKUP_LOG="/mnt/server/backup.log"
HEALTH_LOG="/mnt/server/health.log"

# Función de logging con rotación
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date -Iseconds)
    
    # Rotar log si es muy grande
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
        if [ "$log_size" -gt "$MAX_LOG_SIZE" ]; then
            log "INFO" "Rotating log file (size: ${log_size} bytes)"
            mv "$LOG_FILE" "$LOG_OLD" 2>/dev/null || true
            touch "$LOG_FILE"
        fi
    fi
    
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Función de backup automático
backup_server() {
    if [ "$AUTO_BACKUP" -ne 1 ]; then
        return 0
    fi
    
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local backup_dir="/mnt/server/backups"
    local backup_file="$backup_dir/backup_$timestamp.tar.gz"
    
    mkdir -p "$backup_dir"
    
    log "INFO" "Creating automatic backup: backup_$timestamp.tar.gz"
    
    # Crear backup excluyendo archivos innecesarios
    if tar -czf "$backup_file" \
        --exclude="backups" \
        --exclude="steamcmd" \
        --exclude="steamapps" \
        --exclude="*.log" \
        --exclude="*.log.old" \
        --exclude="*.tmp" \
        -C /mnt/server \
        serverDZ.cfg \
        battleye/ \
        mpmissions/ \
        profiles/ \
        keys/ \
        @*/ \
        2>>"$BACKUP_LOG"; then
        
        local backup_size=$(du -h "$backup_file" 2>/dev/null | cut -f1 || echo "unknown")
        log "SUCCESS" "Backup created: backup_$timestamp.tar.gz (Size: $backup_size)"
        
        # Limpiar backups antiguos (mantener solo los últimos MAX_BACKUPS)
        local backup_count=$(ls -1 "$backup_dir"/backup_*.tar.gz 2>/dev/null | wc -l)
        if [ "$backup_count" -gt "$MAX_BACKUPS" ]; then
            local to_delete=$((backup_count - MAX_BACKUPS))
            ls -t "$backup_dir"/backup_*.tar.gz 2>/dev/null | tail -n "$to_delete" | xargs -r rm -f
            log "INFO" "Cleaned up $to_delete old backup(s)"
        fi
        
        # Subir a S3 si está configurado
        if [ -n "${BACKUP_S3_BUCKET:-}" ] && command -v aws > /dev/null 2>&1; then
            log "INFO" "Uploading backup to S3..."
            if aws s3 cp "$backup_file" "s3://${BACKUP_S3_BUCKET}/dayz/backup_$timestamp.tar.gz" \
                --region "${BACKUP_S3_REGION:-us-east-1}" 2>>"$BACKUP_LOG"; then
                log "SUCCESS" "Backup uploaded to S3"
            else
                log "WARN" "Failed to upload backup to S3"
            fi
        fi
    else
        log "ERROR" "Failed to create backup"
    fi
}

# Función de healthcheck mejorado
check_server_health() {
    # Verificar si el proceso está corriendo
    if ! pgrep -f "DayZServer" > /dev/null 2>&1; then
        log "ALERT" "Server process not found - possible crash"
        return 1
    fi
    
    # Verificar si el puerto está escuchando
    local port=${SERVER_PORT:-2302}
    if command -v netstat > /dev/null 2>&1; then
        if ! netstat -tuln 2>/dev/null | grep -q ":$port "; then
            log "ALERT" "Server port $port is not listening"
            return 1
        fi
    elif command -v ss > /dev/null 2>&1; then
        if ! ss -tuln 2>/dev/null | grep -q ":$port "; then
            log "ALERT" "Server port $port is not listening"
            return 1
        fi
    fi
    
    # Verificar uso de memoria
    local pid=$(pgrep -f "DayZServer" | head -1)
    if [ -n "$pid" ] && [ -n "${MAX_MEMORY:-}" ]; then
        local memory=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{print $1/1024}' || echo "0")
        if command -v bc > /dev/null 2>&1 && [ "$memory" != "0" ] && [ "$MAX_MEMORY" != "0" ]; then
            if (( $(echo "$memory > $MAX_MEMORY" | bc -l 2>/dev/null || echo "0") )); then
                log "WARN" "Memory usage high: ${memory}MB > ${MAX_MEMORY}MB"
            fi
        fi
    fi
    
    return 0
}

# Función de auto-update
update_server() {
    if [ "$AUTO_UPDATE" -ne 1 ]; then
        return 0
    fi
    
    log "INFO" "Checking for server updates..."
    
    cd /mnt/server/steamcmd || return 1
    
    local update_cmd="./steamcmd.sh +force_install_dir \"/mnt/server\" \"+login \\\"${STEAM_USER:-anonymous}\\\" \\\"${STEAM_PASS:-}\\\"\" +app_update ${STEAMCMD_APPID:-223350} $( [[ -z ${STEAMCMD_BETAID} ]] || printf %s \"-beta ${STEAMCMD_BETAID}\" ) $( [[ -z ${STEAMCMD_BETAPASS} ]] || printf %s \"-betapassword ${STEAMCMD_BETAPASS}\" ) ${INSTALL_FLAGS:-} +quit"
    
    if eval "$update_cmd" 2>&1 | tee -a "$LOG_FILE" | grep -q "Success"; then
        log "SUCCESS" "Server updated successfully"
        return 0
    else
        log "INFO" "Server is up to date or update failed"
        return 1
    fi
}

# Función de actualización de mods
update_mods() {
    if [ -z "${MOD_IDS:-}" ] || [ "$AUTO_UPDATE" -ne 1 ]; then
        return 0
    fi
    
    log "INFO" "Checking for mod updates..."
    cd /mnt/server/steamcmd || return 1
    
    IFS=';' read -ra MOD_ARRAY <<< "$MOD_IDS"
    local updated=0
    
    for MOD_ID in "${MOD_ARRAY[@]}"; do
        MOD_ID=$(echo "$MOD_ID" | xargs)
        if [ -z "$MOD_ID" ]; then
            continue
        fi
        
        log "INFO" "Updating mod: $MOD_ID"
        
        local mod_update_cmd="./steamcmd.sh +force_install_dir \"/mnt/server\" \"+login \\\"${STEAM_USER:-anonymous}\\\" \\\"${STEAM_PASS:-}\\\"\" +workshop_download_item 221100 $MOD_ID validate +quit"
        
        if eval "$mod_update_cmd" 2>&1 | tee -a "$LOG_FILE"; then
            # Copiar mod actualizado
            local workshop_path="/mnt/server/steamapps/workshop/content/221100/$MOD_ID"
            local mod_target="/mnt/server/@$MOD_ID"
            
            if [ -d "$workshop_path" ]; then
                rm -rf "$mod_target"
                mkdir -p "$mod_target"
                cp -r "$workshop_path"/* "$mod_target/" 2>/dev/null && updated=$((updated + 1))
            fi
        fi
    done
    
    if [ $updated -gt 0 ]; then
        log "SUCCESS" "Updated $updated mod(s)"
    fi
}

# Pre-flight checks mejorados
preflight_checks() {
    log "INFO" "Running pre-flight checks..."
    
    # Verificar binario
    if [ ! -f "./${SERVER_BINARY:-DayZServer}" ]; then
        log "ERROR" "Server binary not found: ${SERVER_BINARY:-DayZServer}"
        return 1
    fi
    
    # Verificar configuración
    if [ ! -f "serverDZ.cfg" ]; then
        log "ERROR" "Configuration file not found: serverDZ.cfg"
        return 1
    fi
    
    # Verificar permisos
    if [ ! -x "./${SERVER_BINARY:-DayZServer}" ]; then
        log "WARN" "Server binary is not executable, fixing..."
        chmod +x "./${SERVER_BINARY:-DayZServer}" || {
            log "ERROR" "Failed to make server binary executable"
            return 1
        }
    fi
    
    # Verificar espacio en disco
    local disk_usage=$(df -h /mnt/server 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//' || echo "0")
    if [ "$disk_usage" -gt 90 ]; then
        log "WARN" "Disk usage critical: ${disk_usage}%"
    fi
    
    log "SUCCESS" "Pre-flight checks passed"
    return 0
}

# Construir string de mods dinámicamente
build_mod_string() {
    local mod_string=""
    
    # Cargar mods instalados si existe
    if [ -f "/mnt/server/.mods_installed" ]; then
        source /mnt/server/.mods_installed 2>/dev/null || true
    fi
    
    # Usar CLIENT_MODS si está definido
    if [ -n "${CLIENT_MODS:-}" ]; then
        mod_string="$CLIENT_MODS"
    elif [ -n "${MOD_IDS:-}" ]; then
        # Construir desde MOD_IDS
        IFS=';' read -ra MOD_ARRAY <<< "$MOD_IDS"
        for MOD_ID in "${MOD_ARRAY[@]}"; do
            MOD_ID=$(echo "$MOD_ID" | xargs)
            if [ -d "/mnt/server/@$MOD_ID" ]; then
                if [ -z "$mod_string" ]; then
                    mod_string="@$MOD_ID"
                else
                    mod_string="$mod_string;@$MOD_ID"
                fi
            fi
        done
    fi
    
    echo "$mod_string"
}

# Iniciar servidor
start_server() {
    log "INFO" "Starting DayZ server (Attempt: $((RESTART_COUNT + 1))/${MAX_RESTART_ATTEMPTS})"
    
    if ! preflight_checks; then
        return 1
    fi
    
    # Backup antes de iniciar (solo en primer intento)
    if [ "$RESTART_COUNT" -eq 0 ] && [ "$AUTO_BACKUP" -eq 1 ]; then
        backup_server
    fi
    
    # Construir string de mods
    local mod_string=$(build_mod_string)
    
    # Construir comando de inicio
    local start_cmd="./${SERVER_BINARY:-DayZServer} \
        -port=${SERVER_PORT:-2302} \
        -profiles=profiles \
        -bepath=./ \
        -config=serverDZ.cfg"
    
    # Agregar mods si existen
    if [ -n "$mod_string" ]; then
        start_cmd="$start_cmd -mod=$mod_string"
    fi
    
    # Agregar server mods
    if [ -n "${SERVERMODS:-}" ]; then
        start_cmd="$start_cmd -serverMod=${SERVERMODS}"
    fi
    
    # Agregar parámetros adicionales
    start_cmd="$start_cmd ${STARTUP_PARAMS:--dologs -adminlog -netlog -freezecheck}"
    
    log "INFO" "Executing: $start_cmd"
    
    # Ejecutar servidor
    eval "$start_cmd" 2>&1 | while IFS= read -r line; do
        echo "$line" | tee -a "$LOG_FILE"
    done
}

# Loop de healthcheck en background
healthcheck_loop() {
    while true; do
        sleep "$HEALTH_CHECK_INTERVAL"
        
        if ! check_server_health; then
            log "ALERT" "Health check failed - server may have crashed"
            # Enviar alerta por webhook si está configurado
            if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
                curl -X POST "$ALERT_WEBHOOK_URL" \
                    -H "Content-Type: application/json" \
                    -d "{\"text\": \"DayZ Server Alert: Health check failed - server may have crashed\"}" \
                    --max-time 5 \
                    --silent \
                    --fail \
                    2>/dev/null || true
            fi
        fi
    done
}

# Loop de backups en background
backup_loop() {
    while true; do
        sleep "$BACKUP_INTERVAL"
        backup_server
    done
}

# Manejar señales
trap 'log "INFO" "Server stopped by signal"; kill $(jobs -p) 2>/dev/null; exit 0' SIGTERM SIGINT

# Función principal
main() {
    log "INFO" "=========================================="
    log "INFO" "DayZ Server - Enterprise Edition"
    log "INFO" "=========================================="
    
    # Auto-update antes de iniciar
    if [ "$AUTO_UPDATE" -eq 1 ]; then
        update_server
        update_mods
    fi
    
    # Iniciar loops en background
    if [ "$AUTO_BACKUP" -eq 1 ]; then
        backup_loop &
        log "INFO" "Automatic backup loop started (interval: ${BACKUP_INTERVAL}s)"
    fi
    
    healthcheck_loop &
    log "INFO" "Health check loop started (interval: ${HEALTH_CHECK_INTERVAL}s)"
    
    # Loop principal de servidor con anti-crash
    if [ "$AUTO_RESTART" -eq 1 ]; then
        while [ $RESTART_COUNT -lt $MAX_RESTART_ATTEMPTS ]; do
            if start_server; then
                log "INFO" "Server exited normally"
                break
            else
                RESTART_COUNT=$((RESTART_COUNT + 1))
                
                if [ $RESTART_COUNT -lt $MAX_RESTART_ATTEMPTS ]; then
                    log "WARN" "Server crashed, restarting in ${RESTART_DELAY}s (${RESTART_COUNT}/${MAX_RESTART_ATTEMPTS})"
                    
                    # Backup antes de reiniciar
                    if [ "$AUTO_BACKUP" -eq 1 ]; then
                        backup_server
                    fi
                    
                    sleep "$RESTART_DELAY"
                else
                    log "ERROR" "Max restart attempts (${MAX_RESTART_ATTEMPTS}) reached. Server will not restart."
                    
                    # Enviar alerta crítica
                    if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
                        curl -X POST "$ALERT_WEBHOOK_URL" \
                            -H "Content-Type: application/json" \
                            -d "{\"text\": \"🚨 DayZ Server CRITICAL: Max restart attempts reached. Server stopped.\"}" \
                            --max-time 5 \
                            --silent \
                            --fail \
                            2>/dev/null || true
                    fi
                    
                    exit 1
                fi
            fi
        done
    else
        start_server
    fi
}

main "$@"
