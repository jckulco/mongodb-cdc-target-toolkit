#!/usr/bin/env bash
#==============================================================================
# mongodb_enable_replicaset.sh
# Convierte una instancia de MongoDB ya instalada (standalone con autenticación)
# en un Replica Set de 1 nodo (rs0) con autenticación keyFile.
# Conserva intactos los usuarios y datos existentes.
#
# Requisito clave: IBM InfoSphere Data Replication (IIDR) solo soporta
# MongoDB configurado como REPLICA_SET o SHARDED cluster.
#
# Autor: Julio César García Hernández (https://www.linkedin.com/in/jcgarciahdz/)
#
# Ejecutar como root en el servidor. Es idempotente.
# Variables de entorno soportadas: RS_NAME ADMIN_USER ADMIN_PASS PORT KEYFILE CONF
#==============================================================================
set -Eeuo pipefail

RS_NAME="${RS_NAME:-rs0}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
PORT="${PORT:-27017}"
KEYFILE="${KEYFILE:-/etc/mongod-keyfile}"
CONF="${CONF:-/etc/mongod.conf}"
HOST="127.0.0.1"          # el miembro se registra con IPv4 (localhost resuelve a ::1 en este servidor)

[[ "${EUID}" -eq 0 ]] || { echo "[ERROR] Ejecuta como root." >&2; exit 1; }
[[ -f "$CONF" ]] || { echo "[ERROR] No existe $CONF" >&2; exit 1; }

URI_ADMIN="mongodb://${ADMIN_USER}:${ADMIN_PASS}@${HOST}:${PORT}/admin?authSource=admin&directConnection=true"
msh_admin() { mongosh --quiet "$URI_ADMIN" "$@"; }

echo "[INFO] Respaldo de $CONF -> ${CONF}.bak.pre-rs"
[[ -f "${CONF}.bak.pre-rs" ]] || cp -p "$CONF" "${CONF}.bak.pre-rs"

echo "[INFO] 1/4 keyFile"
if [[ ! -f "$KEYFILE" ]]; then
  openssl rand -base64 756 > "$KEYFILE"
fi
chown mongod:mongod "$KEYFILE"
chmod 400 "$KEYFILE"

echo "[INFO] 2/4 Editando $CONF"
python3 - "$CONF" "$RS_NAME" "$KEYFILE" <<'PY'
import sys, re
path, rs, key = sys.argv[1:4]
lines = open(path).read().splitlines()
text = "\n".join(lines)

if not re.search(r'^replication:\s*$', text, re.M):
    text += f"\nreplication:\n  replSetName: {rs}\n"
elif not re.search(r'^\s+replSetName:', text, re.M):
    text = re.sub(r'^replication:\s*$', f"replication:\n  replSetName: {rs}", text, flags=re.M)

if not re.search(r'^\s+keyFile:', text, re.M):
    if re.search(r'^security:\s*$', text, re.M):
        text = re.sub(r'^security:\s*$', f"security:\n  keyFile: {key}", text, flags=re.M)
    else:
        text += f"\nsecurity:\n  keyFile: {key}\n  authorization: enabled\n"

open(path, "w").write(text.rstrip("\n") + "\n")
PY
echo "----- $CONF -----"; cat "$CONF"; echo "-----------------"

echo "[INFO] 3/4 Reiniciando mongod"
systemctl restart mongod
for i in $(seq 1 30); do
  out="$(msh_admin --eval 'db.runCommand({ping:1}).ok' 2>&1 || true)"
  [[ "${out//[[:space:]]/}" == "1" ]] && break
  sleep 2
done
[[ "${out//[[:space:]]/}" == "1" ]] || { echo "[ERROR] mongod no responde tras el reinicio:"; echo "$out"; tail -20 /var/log/mongodb/mongod.log 2>/dev/null; exit 1; }

echo "[INFO] 4/4 rs.initiate (si hace falta) y espera de PRIMARY"
msh_admin --eval "
try { printjson({ok: rs.status().ok, set: rs.status().set}) }
catch (e) { printjson(rs.initiate({_id: '${RS_NAME}', members: [{_id: 0, host: '${HOST}:${PORT}'}]})) }
"
for i in $(seq 1 30); do
  st="$(msh_admin --eval 'try { rs.status().myState } catch (e) { -1 }' 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$st" == "1" ]] && break
  sleep 2
done
[[ "$st" == "1" ]] || { echo "[ERROR] El nodo no llego a PRIMARY (myState=$st)."; exit 1; }

echo "[OK] Replica set ${RS_NAME} activo, nodo PRIMARY en ${HOST}:${PORT}"
msh_admin --eval "printjson(rs.status().members.map(m => ({name: m.name, state: m.stateStr})))"
echo
echo "URL para IIDR (prueba en este orden):"
echo "  mongodb://${HOST}:${PORT}/?authSource=iidr&replicaSet=${RS_NAME}"
echo "  mongodb://${HOST}:${PORT}/?authSource=iidr&replicaSet=${RS_NAME}&directConnection=true"
