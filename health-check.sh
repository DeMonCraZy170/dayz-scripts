#!/bin/bash
# Sistema de monitoreo y health checks para DayZ Server
# Versión profesional con métricas y alertas

set -euo pipefail

HEALTH_CHECK_INTERVAL=${HEALTH_CHECK_INTERVAL:-60}
METRICS_FILE="/mnt/server/metrics.json"
ALERT_WEBHOOK=${ALERT_WEBHOOK_URL:-""}
ENABLE_MONITORING=${ENABLE_MONITORING:-1}
MAX_MEMORY=${MAX_MEMORY:-4096}

log() {
    echo "[$(date -Iseconds)] [$1] $2" | tee -a /mnt/server/health.log
}

log_metric() {
    if [ "$ENABLE_MONITORING" -ne 1 ]; then
        return 0
    fi
    
    local metric=$1
    local value=$2
    local timestamp=$(date +%s)
    
    # Crear archivo de métricas si no existe
    if [ ! -f "$METRICS_FILE" ]; then
        echo "{}" > "$METRICS_FILE"
    fi
    
    # Actualizar métrica usando jq si está disponible, sino usar sed
    if command -v jq > /dev/null 2>&1; then
        jq --arg key "$metric" --arg value "$value" --arg ts "$timestamp" \
            '. + {($key): {value: $value, timestamp: $ts}}' \
            "$METRICS_FILE" > "${METRICS_FILE}.tmp" && \
            mv "${METRICS_FILE}.tmp" "$METRICS_FILE" 2>/dev/null || true
    else
        # Fallback simple sin jq
        echo "{\"$metric\": {\"value\": \"$value\", \"timestamp\": $timestamp}}" >> /mnt/server/metrics_simple.log
    fi
}

check_server_process() {
    if pgrep -f "DayZServer" > /dev/null 2>&1; then
        log_metric "server_running" "1"
        return 0
    else
        log_metric "server_running" "0"
        send_alert "Server process is not running!"
        return 1
    fi
}

check_server_resources() {
    local pid=$(pgrep -f "DayZServer" | head -1)
    if [ -z "$pid" ]; then
        return 1
    fi
    
    # CPU usage
    if command -v ps > /dev/null 2>&1; then
        local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        log_metric "cpu_usage" "${cpu:-0}"
        
        # Memory usage (MB)
        local memory=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{print $1/1024}' || echo "0")
        log_metric "memory_usage" "${memory:-0}"
        
        # Verificar límites de memoria
        if command -v bc > /dev/null 2>&1; then
            if [ -n "$memory" ] && [ -n "$MAX_MEMORY" ] && [ "$memory" != "0" ] && [ "$MAX_MEMORY" != "0" ]; then
                if (( $(echo "$memory > $MAX_MEMORY" | bc -l 2>/dev/null || echo "0") )); then
                    send_alert "Memory usage exceeded limit: ${memory}MB > ${MAX_MEMORY}MB"
                fi
            fi
        fi
    fi
}

check_disk_space() {
    if command -v df > /dev/null 2>&1; then
        local usage=$(df -h /mnt/server 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//' || echo "0")
        log_metric "disk_usage" "${usage:-0}"
        
        if [ -n "$usage" ] && [ "$usage" != "0" ] && [ "$usage" -gt 90 ]; then
            send_alert "Disk usage critical: ${usage}%"
        fi
    fi
}

check_server_port() {
    local port=${SERVER_PORT:-2302}
    if command -v netstat > /dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            log_metric "port_listening" "1"
            return 0
        else
            log_metric "port_listening" "0"
            send_alert "Server port $port is not listening!"
            return 1
        fi
    elif command -v ss > /dev/null 2>&1; then
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            log_metric "port_listening" "1"
            return 0
        else
            log_metric "port_listening" "0"
            return 1
        fi
    fi
}

send_alert() {
    local message=$1
    log "ALERT" "$message"
    
    if [ -n "$ALERT_WEBHOOK" ]; then
        curl -X POST "$ALERT_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"text\": \"DayZ Server Alert: $message\"}" \
            --max-time 5 \
            --silent \
            --fail \
            2>/dev/null || true
    fi
}

# Loop principal de health check (solo si se ejecuta como daemon)
main() {
    if [ "${1:-}" = "once" ]; then
        # Ejecutar una vez
        check_server_process
        check_server_resources
        check_disk_space
        check_server_port
    else
        # Loop continuo
        log "INFO" "Starting health monitoring (interval: ${HEALTH_CHECK_INTERVAL}s)"
        while true; do
            check_server_process
            check_server_resources
            check_disk_space
            check_server_port
            
            sleep "$HEALTH_CHECK_INTERVAL"
        done
    fi
}

main "$@"
