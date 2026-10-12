#!/usr/bin/env bash
#==============================================================================
# verify_mongodb_cdc_target.sh
# Verifica el estado de salud, autenticación, roles de IIDR y Replica Set
# de una instancia de MongoDB 8.0 configurada como Target de CDC.
#
# Autor: Julio César García Hernández (https://www.linkedin.com/in/jcgarciahdz/)
#
# Uso:   chmod +x verify_mongodb_cdc_target.sh && ./verify_mongodb_cdc_target.sh
#==============================================================================
set -Eeuo pipefail

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
APP_USER="${APP_USER:-iidr}"
APP_PASS="${APP_PASS:-iidr}"
DB_NAME="${DB_NAME:-iidr}"
COLLECTION="${COLLECTION:-customers}"
PORT="${PORT:-27017}"
HOST="${HOST:-127.0.0.1}"
RS_NAME="${RS_NAME:-rs0}"

echo "================================================================================"
echo "   Verificación de MongoDB 8.0 Target para IBM InfoSphere CDC / IIDR"
echo "================================================================================"

# 1. Comprobar binario mongosh
if ! command -v mongosh >/dev/null 2>&1; then
  echo "[ERROR] mongosh no está instalado o no se encuentra en el PATH." >&2
  exit 1
fi
echo "[OK] mongosh disponible: $(mongosh --version | head -n 1)"

# 2. Comprobar servicio systemd
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet mongod; then
    echo "[OK] Servicio systemd 'mongod' está activo."
  else
    echo "[WARN] Servicio 'mongod' no está activo o se ejecuta de forma independiente."
  fi
fi

# 3. Comprobar autenticación de administrador
URI_ADMIN="mongodb://${ADMIN_USER}:${ADMIN_PASS}@${HOST}:${PORT}/admin?authSource=admin&directConnection=true"
echo -n "[INFO] Probando autenticación de administrador (${ADMIN_USER})... "
ADMIN_PING="$(mongosh --quiet "$URI_ADMIN" --eval 'db.runCommand({ping: 1}).ok' 2>/dev/null || echo '0')"
if [[ "$ADMIN_PING" == "1" ]]; then
  echo "OK"
else
  echo "FALLO"
  echo "[ERROR] No se pudo autenticar como ${ADMIN_USER} en admin." >&2
  exit 1
fi

# 4. Comprobar Replica Set
echo -n "[INFO] Verificando estado de Replica Set (${RS_NAME})... "
RS_STATE="$(mongosh --quiet "$URI_ADMIN" --eval 'try { db.hello().setName + ":" + (db.hello().isWritablePrimary ? "PRIMARY" : "SECONDARY") } catch(e) { "ERROR" }' 2>/dev/null || echo 'ERROR')"
echo "$RS_STATE"
if [[ "$RS_STATE" != *"PRIMARY"* ]]; then
  echo "[WARN] La instancia no se encuentra en estado PRIMARY del Replica Set."
fi

# 5. Comprobar usuario y roles de aplicación IIDR
URI_APP="mongodb://${APP_USER}:${APP_PASS}@${HOST}:${PORT}/${DB_NAME}?authSource=${DB_NAME}&directConnection=true"
echo -n "[INFO] Probando autenticación del usuario CDC (${APP_USER}) en '${DB_NAME}'... "
APP_PING="$(mongosh --quiet "$URI_APP" --eval 'db.runCommand({ping: 1}).ok' 2>/dev/null || echo '0')"
if [[ "$APP_PING" == "1" ]]; then
  echo "OK"
else
  echo "FALLO"
  echo "[ERROR] No se pudo autenticar como ${APP_USER} en la base ${DB_NAME}." >&2
  exit 1
fi

# 6. Comprobar colecciones y roles requeridos
echo "[INFO] Inspeccionando colecciones en '${DB_NAME}':"
mongosh --quiet "$URI_APP" --eval "print('  Colecciones disponibles: ' + db.getCollectionNames().join(', '))"

echo
echo "================================================================================"
echo "   Resumen de Parámetros de Conexión para IBM InfoSphere CDC Management Console"
echo "================================================================================"
echo "Host / Puerto        : ${HOST}:${PORT}"
echo "Base de datos        : ${DB_NAME}"
echo "Colección destino    : ${COLLECTION}"
echo "Usuario IIDR         : ${APP_USER}"
echo "Replica Set          : ${RS_NAME}"
echo "URI para IIDR (dmconfigurets):"
echo "  mongodb://${HOST}:${PORT}/?authSource=${DB_NAME}&replicaSet=${RS_NAME}"
echo "URI con directConnection (si aplica):"
echo "  mongodb://${HOST}:${PORT}/?authSource=${DB_NAME}&replicaSet=${RS_NAME}&directConnection=true"
echo "================================================================================"
