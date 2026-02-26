#!/bin/bash
# Script de instalación mejorado para DayZ Server
# Versión profesional con manejo de errores robusto, logging y retry logic

set -euo pipefail  # Exit on error, undefined vars, pipe failures

export HOME=/mnt/server
CONFIG_URL="https://raw.githubusercontent.com/ptero-eggs/game-eggs/main/dayz/config/serverDZ.cfg"
MISSIONS_GITHUB_PACKAGE="BohemiaInteractive/DayZ-Central-Economy"

# Configuración de logging
LOG_FILE="${HOME}/install.log"
log() {
    local level=$1
    shift
    echo "[$(date -Iseconds)] [$level] $*" | tee -a "$LOG_FILE"
}

# Función de retry con backoff exponencial
retry_with_backoff() {
    local max_attempts=${STEAMCMD_ATTEMPTS:-3}
    local attempt=1
    local delay=5
    local cmd="$@"
    
    while [ $attempt -le $max_attempts ]; do
        log "INFO" "SteamCMD attempt $attempt/$max_attempts"
        
        if eval "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
            log "SUCCESS" "SteamCMD operation completed successfully"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log "WARN" "Operation failed, retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))  # Backoff exponencial
        fi
        
        attempt=$((attempt + 1))
    done
    
    log "ERROR" "SteamCMD failed after $max_attempts attempts"
    return 1
}

# Verificación de requisitos previos
check_requirements() {
    log "INFO" "Checking system requirements..."
    
    # Verificar espacio en disco (mínimo 10GB)
    local available_space=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' || echo "0")
    if [ "$available_space" -lt 10 ] 2>/dev/null; then
        log "WARN" "Low disk space. Available: ${available_space}GB (Recommended: 10GB+)"
    fi
    
    # Verificar conectividad
    if ! curl -s --max-time 5 https://steamcdn-a.akamaihd.net > /dev/null 2>&1; then
        log "WARN" "Cannot reach Steam CDN. Check network connectivity."
    fi
    
    # Verificar herramientas necesarias
    for tool in curl tar; do
        if ! command -v $tool > /dev/null 2>&1; then
            log "ERROR" "Required tool not found: $tool"
            exit 1
        fi
    done
    
    log "SUCCESS" "System requirements check completed"
}

# Descargar y verificar SteamCMD
download_steamcmd() {
    log "INFO" "Downloading SteamCMD..."
    cd /tmp
    
    if ! curl -fsSL -o steamcmd.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz; then
        log "ERROR" "Failed to download SteamCMD"
        exit 1
    fi
    
    # Verificar integridad del archivo
    local file_size=$(stat -c%s steamcmd.tar.gz 2>/dev/null || echo "0")
    if [ "$file_size" -lt 1000000 ]; then  # Mínimo 1MB
        log "ERROR" "Downloaded file seems corrupted (size: ${file_size} bytes)"
        exit 1
    fi
    
    log "SUCCESS" "SteamCMD downloaded successfully (${file_size} bytes)"
    
    # Extraer SteamCMD
    mkdir -p "$HOME/steamcmd" "$HOME/steamapps"
    if ! tar -xzf steamcmd.tar.gz -C "$HOME/steamcmd" 2>&1 | tee -a "$LOG_FILE"; then
        log "ERROR" "Failed to extract SteamCMD"
        exit 1
    fi
    
    cd "$HOME/steamcmd"
    chown -R root:root /mnt 2>/dev/null || true
}

# Instalar servidor DayZ
install_server() {
    if [ "${SKIP_INSTALL:-0}" -eq 1 ]; then
        log "INFO" "Skipping game server installation (SKIP_INSTALL=1)"
        "$HOME/steamcmd/steamcmd.sh" +quit
        return 0
    fi
    
    log "INFO" "Installing DayZ Dedicated Server..."
    
    local install_cmd="./steamcmd.sh +force_install_dir \"$HOME\" \"+login \\\"${STEAM_USER}\\\" \\\"${STEAM_PASS}\\\"\" +app_update ${STEAMCMD_APPID:-223350} $( [[ -z ${STEAMCMD_BETAID:-} ]] || printf %s \"-beta ${STEAMCMD_BETAID}\" ) $( [[ -z ${STEAMCMD_BETAPASS:-} ]] || printf %s \"-betapassword ${STEAMCMD_BETAPASS}\" ) ${INSTALL_FLAGS:-} validate +quit"
    
    cd "$HOME/steamcmd"
    retry_with_backoff "$install_cmd"
}

# Configurar librerías Steam
setup_steam_libraries() {
    log "INFO" "Setting up Steam libraries..."
    mkdir -p "$HOME/.steam/sdk32" "$HOME/.steam/sdk64"
    
    if [ -f "$HOME/steamcmd/linux32/steamclient.so" ]; then
        cp -v "$HOME/steamcmd/linux32/steamclient.so" "$HOME/.steam/sdk32/steamclient.so" || log "WARN" "Failed to copy 32-bit library"
    fi
    
    if [ -f "$HOME/steamcmd/linux64/steamclient.so" ]; then
        cp -v "$HOME/steamcmd/linux64/steamclient.so" "$HOME/.steam/sdk64/steamclient.so" || log "WARN" "Failed to copy 64-bit library"
    fi
    
    log "SUCCESS" "Steam libraries configured"
}

# Configurar archivos del servidor
setup_server_files() {
    log "INFO" "Setting up DayZ server files..."
    cd "$HOME"
    
    # Verificar instalación del binario
    if [ ! -f DayZServer ] && [ "${SKIP_INSTALL:-0}" -ne 1 ]; then
        log "ERROR" "SteamCMD failed to install the DayZ Dedicated Server!"
        log "ERROR" "Try reinstalling the server again."
        exit 1
    fi
    
    # Descargar serverDZ.cfg si falta
    if [ ! -f serverDZ.cfg ] || [ ! -s serverDZ.cfg ]; then
        log "INFO" "'serverDZ.cfg' is missing or empty. Downloading default config file..."
        if ! curl -fsSL -o serverDZ.cfg "${CONFIG_URL}"; then
            log "ERROR" "Failed to download default server config file!"
            exit 1
        fi
        chmod 644 serverDZ.cfg
        log "SUCCESS" "Default serverDZ.cfg downloaded"
    fi
    
    # Agregar steamQueryPort si falta
    if ! grep -q "steamQueryPort" serverDZ.cfg 2>/dev/null; then
        log "INFO" "Adding steamQueryPort parameter to serverDZ.cfg..."
        cat >> serverDZ.cfg << EOL


steamQueryPort = ${QUERY_PORT:-27016};
EOL
    fi
    
    # Descargar archivos de misión si faltan
    if { [ ! -d "mpmissions" ] || [ -z "$(ls -A mpmissions 2>/dev/null)" ]; } && [ "${SKIP_INSTALL:-0}" -ne 1 ]; then
        log "WARN" "The Steam account used to install this server does not own the DayZ game!"
        log "WARN" "Vanilla mission files will have to be MANUALLY updated in the future if they update!"
        log "INFO" "Downloading and installing vanilla mission files..."
        
        mkdir -p "$HOME/mpmissions"
        cd "$HOME/mpmissions"
        
        if command -v jq > /dev/null 2>&1; then
            LATEST_JSON=$(curl -fsSL "https://api.github.com/repos/${MISSIONS_GITHUB_PACKAGE}/releases/latest" || echo "")
            if [ -n "$LATEST_JSON" ]; then
                DOWNLOAD_URL=$(echo "$LATEST_JSON" | jq -r .tarball_url 2>/dev/null || echo "")
                if [ -n "$DOWNLOAD_URL" ] && [ "$DOWNLOAD_URL" != "null" ]; then
                    if curl -fsSL -o mpmissions.tar.gz "$DOWNLOAD_URL"; then
                        tar -xzf mpmissions.tar.gz --strip-components=1 --wildcards '*/dayzOffline.chernarusplus/*' '*/dayzOffline.enoch/*' 2>/dev/null || true
                        rm -f mpmissions.tar.gz
                        log "SUCCESS" "Vanilla mission files downloaded"
                    else
                        log "WARN" "Failed to download vanilla mission files"
                    fi
                fi
            fi
        else
            log "WARN" "jq not found, skipping automatic mission file download"
        fi
    fi
    
    # Configurar BattlEye RCon
    mkdir -p "$HOME/battleye"
    cd "$HOME/battleye"
    if [ ! -f beserver_x64.cfg ]; then
        log "INFO" "Creating BattlEye RCon Configuration..."
        cat > beserver_x64.cfg << EOF
RConPort ${RCON_PORT:-2305}
RConPassword ${RCON_PASSWORD:-}
RestrictRCon 0
EOF
        log "SUCCESS" "BattlEye RCon configuration created"
    fi
    
    log "SUCCESS" "Server files configured"
}

# Instalar mods de Steam Workshop automáticamente
install_mods() {
    if [ -z "${MOD_IDS:-}" ]; then
        log "INFO" "No mods specified (MOD_IDS is empty)"
        return 0
    fi
    
    log "INFO" "Installing Steam Workshop mods..."
    cd "$HOME"
    
    # Crear directorio para keys de mods
    mkdir -p "$HOME/keys"
    
    # Separar MOD_IDS por punto y coma
    IFS=';' read -ra MOD_ARRAY <<< "$MOD_IDS"
    local mod_count=${#MOD_ARRAY[@]}
    log "INFO" "Found $mod_count mod(s) to install"
    
    local installed_count=0
    local failed_count=0
    
    for MOD_ID in "${MOD_ARRAY[@]}"; do
        # Limpiar espacios en blanco
        MOD_ID=$(echo "$MOD_ID" | xargs)
        
        if [ -z "$MOD_ID" ]; then
            continue
        fi
        
        log "INFO" "Installing mod: $MOD_ID"
        
        # Instalar mod usando SteamCMD
        local mod_install_cmd="./steamcmd.sh +force_install_dir \"$HOME\" \"+login \\\"${STEAM_USER:-anonymous}\\\" \\\"${STEAM_PASS:-}\\\"\" +workshop_download_item 221100 $MOD_ID validate +quit"
        
        cd "$HOME/steamcmd"
        if retry_with_backoff "$mod_install_cmd"; then
            # Copiar mod a la ubicación correcta
            local workshop_path="$HOME/steamapps/workshop/content/221100/$MOD_ID"
            local mod_target="$HOME/@$MOD_ID"
            
            if [ -d "$workshop_path" ]; then
                mkdir -p "$mod_target"
                
                # Copiar contenido del mod
                if cp -r "$workshop_path"/* "$mod_target/" 2>/dev/null; then
                    log "SUCCESS" "Mod $MOD_ID installed successfully"
                    
                    # Copiar keys automáticamente si existen
                    if [ -d "$mod_target/keys" ]; then
                        cp -v "$mod_target/keys"/* "$HOME/keys/" 2>/dev/null || true
                        log "INFO" "Copied keys for mod $MOD_ID"
                    fi
                    
                    installed_count=$((installed_count + 1))
                else
                    log "WARN" "Failed to copy mod $MOD_ID files"
                    failed_count=$((failed_count + 1))
                fi
            else
                log "WARN" "Mod $MOD_ID download path not found: $workshop_path"
                failed_count=$((failed_count + 1))
            fi
        else
            log "ERROR" "Failed to download mod $MOD_ID"
            failed_count=$((failed_count + 1))
        fi
    done
    
    log "INFO" "Mod installation completed: $installed_count installed, $failed_count failed"
    
    # Construir string de mods para startup
    if [ $installed_count -gt 0 ]; then
        local mod_string=""
        for MOD_ID in "${MOD_ARRAY[@]}"; do
            MOD_ID=$(echo "$MOD_ID" | xargs)
            if [ -d "$HOME/@$MOD_ID" ]; then
                if [ -z "$mod_string" ]; then
                    mod_string="@$MOD_ID"
                else
                    mod_string="$mod_string;@$MOD_ID"
                fi
            fi
        done
        
        # Guardar en variable de entorno para uso posterior
        echo "export CLIENT_MODS=\"$mod_string\"" >> "$HOME/.mods_installed"
        log "SUCCESS" "Mod string generated: $mod_string"
    fi
}

# Aplicar presets de servidor (configura valores reales)
apply_server_preset() {
    local preset=${SERVER_TYPE:-vanilla}
    log "INFO" "Applying server preset: $preset"
    
    cd "$HOME"
    
    if [ ! -f "serverDZ.cfg" ]; then
        log "WARN" "serverDZ.cfg not found, skipping preset application"
        return 0
    fi
    
    case $preset in
        pvp)
            log "INFO" "Configuring PvP preset (60 slots, fast time, optimized for PvP)..."
            # PvP: Optimizado para PvP
            # MAX_PLAYERS=60, TIME_MULT=4, NIGHT_MULT=8
            sed -i "s/^maxPlayers = .*/maxPlayers = 60;/" serverDZ.cfg 2>/dev/null || true
            sed -i "s/^serverTimeAcceleration = .*/serverTimeAcceleration = 4;/" serverDZ.cfg 2>/dev/null || true
            sed -i "s/^serverNightTimeAcceleration = .*/serverNightTimeAcceleration = 8;/" serverDZ.cfg 2>/dev/null || true
            sed -i "s/^disable3rdPerson = .*/disable3rdPerson = 0;/" serverDZ.cfg 2>/dev/null || true
            sed -i "s/^disableCrosshair = .*/disableCrosshair = 0;/" serverDZ.cfg 2>/dev/null || true
            # Actualizar variables de entorno para consistencia
            export MAX_PLAYERS=60
            export TIME_MULT=4
            export NIGHT_MULT=8
            export DISABLE_THIRD=0
            export DISABLE_CROSSHAIR=0
            log "SUCCESS" "PvP preset applied: 60 slots, TIME_MULT=4, NIGHT_MULT=8"
            ;;
        hardcore)
            log "INFO" "Configuring Hardcore preset (40 slots, harder settings)..."
            # Hardcore: Más difícil
            # MAX_PLAYERS=40, DISABLE_THIRD=1
            sed -i "s/^maxPlayers = .*/maxPlayers = 40;/" serverDZ.cfg 2>/dev/null || true
            sed -i "s/^disable3rdPerson = .*/disable3rdPerson = 1;/" serverDZ.cfg 2>/dev/null || true
            sed -i "s/^disableCrosshair = .*/disableCrosshair = 1;/" serverDZ.cfg 2>/dev/null || true
            sed -i "s/^disablePersonalLight = .*/disablePersonalLight = 1;/" serverDZ.cfg 2>/dev/null || true
            sed -i "s/^lightingConfig = .*/lightingConfig = 1;/" serverDZ.cfg 2>/dev/null || true
            # Actualizar variables de entorno
            export MAX_PLAYERS=40
            export DISABLE_THIRD=1
            export DISABLE_CROSSHAIR=1
            export DISABLE_PERSONAL_LIGHT=1
            export LIGHTING_CONFIG=1
            log "SUCCESS" "Hardcore preset applied: 40 slots, third person disabled, harder settings"
            ;;
        vanilla|*)
            log "INFO" "Using Vanilla/default preset (standard settings)..."
            # Vanilla: Configuración por defecto (no cambios)
            ;;
    esac
    
    log "SUCCESS" "Preset $preset applied successfully"
}

# Instalar scripts auxiliares automáticamente
install_auxiliary_scripts() {
    log "INFO" "Installing auxiliary scripts..."
    mkdir -p "$HOME/scripts"
    
    # URL base para scripts (configurable por host)
    local scripts_base_url="${SCRIPTS_BASE_URL:-https://raw.githubusercontent.com/DeMonCraZy170/dayz-scripts/refs/heads/main}"
    
    # Lista de scripts a descargar
    local scripts=(
        "start-server-enterprise.sh"
        "start-server.sh"
        "backup.sh"
        "health-check.sh"
    )
    
    local downloaded=0
    local failed=0
    
    for script in "${scripts[@]}"; do
        log "INFO" "Downloading $script..."
        
        if curl -fsSL "${scripts_base_url}/${script}" -o "$HOME/scripts/${script}" 2>&1 | tee -a "$LOG_FILE"; then
            # Dar permisos de ejecución
            chmod +x "$HOME/scripts/${script}" 2>/dev/null || true
            
            # Verificar que el archivo no esté vacío
            if [ -s "$HOME/scripts/${script}" ]; then
                log "SUCCESS" "$script downloaded and installed"
                downloaded=$((downloaded + 1))
            else
                log "WARN" "$script downloaded but appears empty"
                rm -f "$HOME/scripts/${script}"
                failed=$((failed + 1))
            fi
        else
            log "WARN" "Failed to download $script from ${scripts_base_url}/${script}"
            failed=$((failed + 1))
        fi
    done
    
    if [ $downloaded -gt 0 ]; then
        log "SUCCESS" "Auxiliary scripts installed: $downloaded downloaded, $failed failed"
        
        # Si start-server-enterprise.sh no se descargó, crear un fallback básico
        if [ ! -f "$HOME/scripts/start-server-enterprise.sh" ]; then
            log "WARN" "Enterprise script not found, using basic start-server.sh as fallback"
        fi
    else
        log "WARN" "No auxiliary scripts could be downloaded. Server will use basic startup."
        log "WARN" "You can manually copy scripts later or configure SCRIPTS_BASE_URL variable."
    fi
    
    # Crear script wrapper permanente para startup command
    log "INFO" "Creating startup wrapper script..."
    cat > "$HOME/start-wrapper.sh" << 'EOF'
#!/bin/bash
# Startup wrapper script for DayZ Server
# This script handles fallback logic for server startup

if [ -f /mnt/server/scripts/start-server-enterprise.sh ]; then
    exec bash /mnt/server/scripts/start-server-enterprise.sh
elif [ -f /mnt/server/scripts/start-server.sh ]; then
    exec bash /mnt/server/scripts/start-server.sh
else
    exec ./${SERVER_BINARY} -port=${SERVER_PORT} -profiles=profiles -bepath=./ -config=serverDZ.cfg -mod=${CLIENT_MODS} -serverMod=${SERVERMODS} ${STARTUP_PARAMS}
fi
EOF
    chmod +x "$HOME/start-wrapper.sh"
    log "SUCCESS" "Startup wrapper script created"
}

# Función principal
main() {
    log "INFO" "=========================================="
    log "INFO" "DayZ Server Installation - Enterprise"
    log "INFO" "=========================================="
    
    check_requirements
    download_steamcmd
    install_server
    setup_steam_libraries
    setup_server_files
    apply_server_preset
    install_mods
    install_auxiliary_scripts
    
    log "SUCCESS" "=========================================="
    log "SUCCESS" "DayZ Dedicated Server successfully installed!"
    log "SUCCESS" "=========================================="
}

# Ejecutar con manejo de errores
trap 'log "ERROR" "Installation failed at line $LINENO. Check logs for details."' ERR
main "$@"
