#!/bin/bash
# Sistema de backups automático para DayZ Server
# Versión profesional con retención configurable y soporte S3

set -euo pipefail

BACKUP_DIR="/mnt/server/backups"
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}
BACKUP_S3_BUCKET=${BACKUP_S3_BUCKET:-""}
BACKUP_S3_REGION=${BACKUP_S3_REGION:-"us-east-1"}
ENABLE_BACKUPS=${ENABLE_BACKUPS:-1}

log() {
    echo "[$(date -Iseconds)] [$1] $2" | tee -a /mnt/server/backup.log
}

create_backup() {
    if [ "$ENABLE_BACKUPS" -ne 1 ]; then
        log "INFO" "Backups are disabled (ENABLE_BACKUPS=0)"
        return 0
    fi
    
    local backup_name="dayz-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    log "INFO" "Creating backup: $backup_name"
    
    mkdir -p "$BACKUP_DIR"
    
    # Crear backup de archivos críticos
    if tar -czf "$backup_path" \
        --exclude="backups" \
        --exclude="steamcmd" \
        --exclude="steamapps" \
        --exclude="*.log" \
        --exclude="*.tmp" \
        -C /mnt/server \
        serverDZ.cfg \
        battleye/ \
        mpmissions/ \
        profiles/ \
        2>/dev/null; then
        
        # Verificar integridad del backup
        if tar -tzf "$backup_path" > /dev/null 2>&1; then
            local backup_size=$(du -h "$backup_path" | cut -f1)
            log "SUCCESS" "Backup created: $backup_name (Size: $backup_size)"
            
            # Subir a S3 si está configurado
            if [ -n "$BACKUP_S3_BUCKET" ] && command -v aws > /dev/null 2>&1; then
                log "INFO" "Uploading backup to S3..."
                if aws s3 cp "$backup_path" "s3://${BACKUP_S3_BUCKET}/dayz/${backup_name}" \
                    --region "$BACKUP_S3_REGION" 2>&1 | tee -a /mnt/server/backup.log; then
                    log "SUCCESS" "Backup uploaded to S3"
                else
                    log "WARN" "Failed to upload backup to S3"
                fi
            fi
            
            # Limpiar backups antiguos
            cleanup_old_backups
            
            echo "$backup_path"
            return 0
        else
            log "ERROR" "Backup file is corrupted"
            rm -f "$backup_path"
            return 1
        fi
    else
        log "ERROR" "Failed to create backup"
        return 1
    fi
}

cleanup_old_backups() {
    log "INFO" "Cleaning up backups older than $RETENTION_DAYS days..."
    find "$BACKUP_DIR" -name "dayz-backup-*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
    log "SUCCESS" "Old backups cleaned up"
}

restore_backup() {
    local backup_file=$1
    
    if [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi
    
    log "INFO" "Restoring backup: $backup_file"
    
    # Crear backup antes de restaurar
    create_backup > /dev/null 2>&1 || log "WARN" "Failed to create pre-restore backup"
    
    # Restaurar archivos
    if tar -xzf "$backup_file" -C /mnt/server 2>&1 | tee -a /mnt/server/backup.log; then
        log "SUCCESS" "Backup restored successfully"
        return 0
    else
        log "ERROR" "Failed to restore backup"
        return 1
    fi
}

list_backups() {
    log "INFO" "Available backups:"
    if [ -d "$BACKUP_DIR" ]; then
        ls -lh "$BACKUP_DIR"/dayz-backup-*.tar.gz 2>/dev/null | awk '{print $9, "(" $5 ")"}' || log "INFO" "No backups found"
    else
        log "INFO" "No backups found"
    fi
}

# Ejecutar según argumento
case "${1:-backup}" in
    backup)
        create_backup
        ;;
    restore)
        if [ -z "${2:-}" ]; then
            log "ERROR" "Usage: $0 restore <backup_file>"
            exit 1
        fi
        restore_backup "$2"
        ;;
    list)
        list_backups
        ;;
    cleanup)
        cleanup_old_backups
        ;;
    *)
        log "ERROR" "Unknown command: $1"
        log "INFO" "Usage: $0 [backup|restore <file>|list|cleanup]"
        exit 1
        ;;
esac
