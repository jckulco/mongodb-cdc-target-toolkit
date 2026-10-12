#!/usr/bin/env bash
#==============================================================================
# seed_sample_document.sh
# Inserta o elimina un documento prototipo en la colección destino de MongoDB.
#
# Propósito:
#   IBM InfoSphere Data Replication (IIDR) CDC requiere que exista al menos
#   un documento en la colección para descubrir las columnas/campos en la
#   Management Console al configurar el mapeo de replicación.
#
# Autor: Julio César García Hernández (https://www.linkedin.com/in/jcgarciahdz/)
#
# Uso:
#   ./seed_sample_document.sh insert   # Inserta documento prototipo
#   ./seed_sample_document.sh clean    # Elimina el documento prototipo
#   ./seed_sample_document.sh show     # Muestra los documentos existentes
#==============================================================================
set -Eeuo pipefail

APP_USER="${APP_USER:-iidr}"
APP_PASS="${APP_PASS:-iidr}"
DB_NAME="${DB_NAME:-iidr}"
COLLECTION="${COLLECTION:-customers}"
PORT="${PORT:-27017}"
HOST="${HOST:-127.0.0.1}"

ACTION="${1:-insert}"
URI_APP="mongodb://${APP_USER}:${APP_PASS}@${HOST}:${PORT}/${DB_NAME}?authSource=${DB_NAME}&directConnection=true"

case "$ACTION" in
  insert)
    echo "[INFO] Insertando documento de prueba/esquema en '${DB_NAME}.${COLLECTION}'..."
    mongosh --quiet "$URI_APP" --eval "
      const res = db.${COLLECTION}.updateOne(
        { _id: '__iidr_schema_seed__' },
        {
          \$set: {
            customer_id: 1001,
            first_name: 'John',
            last_name: 'Doe',
            email: 'john.doe@example.com',
            status: 'ACTIVE',
            balance: 1500.50,
            updated_at: new Date()
          }
        },
        { upsert: true }
      );
      print('Documento insertado con éxito: ' + JSON.stringify(res));
    "
    echo "[OK] Ahora puedes realizar el descubrimiento de columnas en IBM CDC Management Console."
    ;;

  clean)
    echo "[INFO] Eliminando documento prototipo de '${DB_NAME}.${COLLECTION}'..."
    mongosh --quiet "$URI_APP" --eval "
      const res = db.${COLLECTION}.deleteOne({ _id: '__iidr_schema_seed__' });
      print('Resultado de eliminación: ' + JSON.stringify(res));
    "
    echo "[OK] Documento prototipo eliminado."
    ;;

  show)
    echo "[INFO] Documentos en '${DB_NAME}.${COLLECTION}':"
    mongosh --quiet "$URI_APP" --eval "
      printjson(db.${COLLECTION}.find().limit(5).toArray());
    "
    ;;

  *)
    echo "Uso: $0 [insert|clean|show]" >&2
    exit 1
    ;;
esac
