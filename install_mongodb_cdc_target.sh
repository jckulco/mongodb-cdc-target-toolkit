#!/usr/bin/env bash
#==============================================================================
# install_mongodb_cdc_target.sh
# Instala MongoDB 8.0.x (RHEL 9) y lo deja listo como TARGET de
# IBM InfoSphere Data Replication (CDC) 11.4:
#   - Instalación (RPM por defecto, TGZ como alternativa, o repositorio oficial) + mongosh
#   - Autenticación habilitada, usuario admin y usuario de aplicación (IIDR)
#   - Base de datos y colección destino creadas
#   - Escucha en 127.0.0.1 (acceso seguro por túnel SSH)
#   - Servicio systemd habilitado y persistente
#   - Replica Set de 1 nodo inicializado con autenticación keyFile (requerido por IIDR)
#
# Autor: Julio César García Hernández (https://www.linkedin.com/in/jcgarciahdz/)
#
# Uso:   chmod +x install_mongodb_cdc_target.sh && ./install_mongodb_cdc_target.sh
# Todas las variables se pueden sobreescribir por entorno, ej.:
#   DB_NAME=cdc REPLICA_SET=yes INSTALL_METHOD=tgz ./install_mongodb_cdc_target.sh
#
# Es repetible e idempotente: si ya está configurado, solo verifica y completa lo que falte.
#==============================================================================
set -Eeuo pipefail

#------------------------------ VARIABLES -------------------------------------
SRC_DIR="${SRC_DIR:-/opt}"
MONGO_VERSION="${MONGO_VERSION:-8.0.32}"           # IIDR 11.4 soporta MongoDB 8.0 y sus fix packs (8.0.x); NO 8.1+
INSTALL_METHOD="${INSTALL_METHOD:-auto}"             # auto | rpm | tgz | repo  (auto: rpm local, luego tgz local, luego repo oficial de MongoDB)
RPM_FILE="${RPM_FILE:-$SRC_DIR/mongodb-org-server-${MONGO_VERSION}-1.el9.x86_64.rpm}"
TGZ_FILE="${TGZ_FILE:-$SRC_DIR/mongodb-linux-x86_64-rhel93-${MONGO_VERSION}.tgz}"
MONGOSH_RPM="${MONGOSH_RPM:-}"                       # ruta a un rpm de mongosh (si no, se busca en $SRC_DIR o se descarga)
STAGE_DIR="${STAGE_DIR:-/opt/stage_mongodb}"
MONGO_HOME="${MONGO_HOME:-/opt/mongodb-${MONGO_VERSION}}"   # solo para el metodo tgz
MONGO_MAJOR="${MONGO_VERSION%.*}"                    # 8.0 (para el repositorio oficial)

BIND_IP="${BIND_IP:-127.0.0.1}"                      # 127.0.0.1 = solo local (tunel SSH). 0.0.0.0 para exponerlo
PORT="${PORT:-27017}"
DB_PATH="${DB_PATH:-/var/lib/mongo}"
LOG_PATH="${LOG_PATH:-/var/log/mongodb/mongod.log}"
CONF="/etc/mongod.conf"
MONGO_OSUSER="mongod"

REPLICA_SET="${REPLICA_SET:-yes}"                    # IIDR solo soporta MongoDB como REPLICA_SET o SHARDED: replica set de 1 nodo (keyFile generado solo). "no" = standalone (IIDR lo rechaza)
RS_NAME="${RS_NAME:-rs0}"
KEYFILE="${KEYFILE:-/etc/mongod-keyfile}"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
DB_NAME="${DB_NAME:-iidr}"                           # base destino de la replicacion
APP_USER="${APP_USER:-iidr}"                         # usuario que usara IIDR (readWrite + dbAdmin sobre DB_NAME)
APP_PASS="${APP_PASS:-iidr}"
COLLECTION="${COLLECTION:-customers}"

LOG="/var/log/install_mongodb_cdc.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

#------------------------------ HELPERS ---------------------------------------
info() { echo -e "\n[$(date +%H:%M:%S)] ==> $*"; }
warn() { echo -e "[$(date +%H:%M:%S)] [WARN] $*"; }
die()  { echo -e "[$(date +%H:%M:%S)] [ERROR] $*" >&2; exit 1; }
trap 'die "Fallo en la linea $LINENO (comando: $BASH_COMMAND). Revisa $LOG"' ERR

CONNECT_HOST="$BIND_IP"
[[ "$BIND_IP" == "0.0.0.0" || "$BIND_IP" == "::" ]] && CONNECT_HOST="127.0.0.1"
URI_NOAUTH="mongodb://${CONNECT_HOST}:${PORT}/admin?directConnection=true"
URI_ADMIN="mongodb://${ADMIN_USER}:${ADMIN_PASS}@${CONNECT_HOST}:${PORT}/admin?authSource=admin&directConnection=true"
URI_APP="mongodb://${APP_USER}:${APP_PASS}@${CONNECT_HOST}:${PORT}/${DB_NAME}?authSource=${DB_NAME}&directConnection=true"

msh()       { mongosh --quiet "$URI_NOAUTH" "$@"; }
msh_admin() { mongosh --quiet "$URI_ADMIN" "$@"; }

# Las salidas se capturan en variables (sin 'cmd | grep -q') para que pipefail no de falsos negativos.
wait_mongod() {   # wait_mongod noauth|auth
  local mode="$1" i out
  for i in $(seq 1 60); do
    if [[ "$mode" == "auth" ]]; then
      out="$(msh_admin --eval 'db.runCommand({ping:1}).ok' 2>&1 || true)"
    else
      out="$(msh --eval 'db.runCommand({ping:1}).ok' 2>&1 || true)"
    fi
    if [[ "${out//[[:space:]]/}" == "1" ]]; then return 0; fi
    sleep 2
  done
  return 1
}

wait_primary() {  # wait_primary msh|msh_admin
  local fn="$1" i out
  for i in $(seq 1 60); do
    out="$($fn --eval 'db.hello().isWritablePrimary' 2>&1 || true)"
    if [[ "$out" == *true* ]]; then return 0; fi
    sleep 2
  done
  return 1
}

diag_mongod() {
  echo "------ journalctl -u mongod (ultimas lineas) ------"
  journalctl -u mongod -n 40 --no-pager 2>/dev/null || true
  echo "------ $LOG_PATH (ultimas lineas) ------"
  tail -n 40 "$LOG_PATH" 2>/dev/null || true
  echo "----------------------------------------------------"
}

[[ $EUID -eq 0 ]] || die "Ejecuta como root."
command -v dnf >/dev/null 2>&1 || die "Este script esta pensado para RHEL 9 (requiere dnf)."

#------------------------------ 1. METODO DE INSTALACION ----------------------
info "1/9 Seleccionando metodo de instalacion"
METHOD="$INSTALL_METHOD"
if [[ "$METHOD" == "auto" ]]; then
  if   [[ -f "$RPM_FILE" ]]; then METHOD="rpm"
  elif [[ -f "$TGZ_FILE" ]]; then METHOD="tgz"
  else METHOD="repo"; echo "No hay rpm ni tgz locales de $MONGO_VERSION; se usara el repositorio oficial de MongoDB."; fi
fi
case "$METHOD" in
  rpm) [[ -f "$RPM_FILE" ]] || die "No existe $RPM_FILE" ;;
  tgz) [[ -f "$TGZ_FILE" ]] || die "No existe $TGZ_FILE" ;;
  repo) ;;
  *)   die "INSTALL_METHOD invalido: $METHOD (usa auto, rpm, tgz o repo)" ;;
esac
echo "Metodo: $METHOD"

#------------------------------ 2. INSTALAR MONGOD ----------------------------
info "2/9 Instalando MongoDB $MONGO_VERSION ($METHOD)"
install_rpm() {
  local cur=""
  cur="$(rpm -q --qf '%{VERSION}' mongodb-org-server 2>/dev/null || true)"
  if [[ "$cur" == "$MONGO_VERSION" ]]; then
    echo "mongodb-org-server $cur ya esta instalado, se omite."
  else
    dnf -y install "$RPM_FILE" || die "dnf no pudo instalar $RPM_FILE (revisa dependencias/repositorios)."
  fi
}

setup_repo() {
  cat > "/etc/yum.repos.d/mongodb-org-${MONGO_MAJOR}.repo" <<EOF
[mongodb-org-${MONGO_MAJOR}]
name=MongoDB Repository ${MONGO_MAJOR}
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/${MONGO_MAJOR}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc
EOF
}

install_repo() {
  local cur=""
  cur="$(rpm -q --qf '%{VERSION}' mongodb-org-server 2>/dev/null || true)"
  if [[ "$cur" == "$MONGO_VERSION" ]]; then
    echo "mongodb-org-server $cur ya esta instalado, se omite."
  else
    setup_repo
    dnf -y install "mongodb-org-server-${MONGO_VERSION}" || die "dnf no pudo instalar mongodb-org-server-${MONGO_VERSION} desde el repositorio oficial (revisa acceso a repo.mongodb.org y que la version exista)."
  fi
}

install_tgz() {
  if [[ -x "$MONGO_HOME/bin/mongod" ]]; then
    echo "$MONGO_HOME ya existe, se omite la extraccion."
  else
    dnf -y install openssl-libs libcurl xz-libs krb5-libs cyrus-sasl-lib ca-certificates >/dev/null 2>&1 \
      || warn "No se pudieron instalar algunas dependencias (se continua)."
    rm -rf "$STAGE_DIR/tgz"; mkdir -p "$STAGE_DIR/tgz" "$MONGO_HOME"
    tar -xzf "$TGZ_FILE" -C "$STAGE_DIR/tgz"
    local mongod_bin
    mongod_bin="$(find "$STAGE_DIR/tgz" -maxdepth 3 -type f -name mongod | head -n 1 || true)"
    [[ -n "$mongod_bin" ]] || die "No se encontro 'mongod' dentro de $TGZ_FILE (revisa: find $STAGE_DIR/tgz -maxdepth 3)"
    cp -a "$(dirname "$(dirname "$mongod_bin")")/." "$MONGO_HOME/"
  fi
  local b
  for b in "$MONGO_HOME"/bin/*; do ln -sf "$b" "/usr/local/bin/$(basename "$b")"; done

  id "$MONGO_OSUSER" >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d "$DB_PATH" "$MONGO_OSUSER"

  cat > /etc/systemd/system/mongod.service <<EOF
[Unit]
Description=MongoDB Database Server
After=network-online.target
Wants=network-online.target

[Service]
User=$MONGO_OSUSER
Group=$MONGO_OSUSER
ExecStart=/usr/local/bin/mongod --config $CONF
LimitNOFILE=64000
LimitNPROC=64000
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

case "$METHOD" in rpm) install_rpm ;; repo) install_repo ;; tgz) install_tgz ;; esac

# Directorios de datos y log (los crea el rpm; en tgz los crea esto). Siempre propiedad de mongod.
install -d -o "$MONGO_OSUSER" -g "$MONGO_OSUSER" -m 755 "$DB_PATH" "$(dirname "$LOG_PATH")"
[[ -f "$LOG_PATH" ]] && chown "$MONGO_OSUSER:$MONGO_OSUSER" "$LOG_PATH"
# mongod debe poder recorrer toda la ruta de datos y log
for _p in "$DB_PATH" "$(dirname "$LOG_PATH")"; do
  _d="$(dirname "$_p")"
  while [[ "$_d" != "/" && "$_d" != "." ]]; do chmod o+x "$_d" 2>/dev/null || true; _d="$(dirname "$_d")"; done
done

command -v mongod >/dev/null 2>&1 || die "mongod no quedo en el PATH."
echo "Version instalada: $(mongod --version | head -n 1)"

#------------------------------ 3. MONGOSH ------------------------------------
info "3/9 Instalando mongosh (shell de MongoDB)"
install_mongosh() {
  if command -v mongosh >/dev/null 2>&1; then
    echo "mongosh ya instalado: $(mongosh --version 2>/dev/null | head -n 1)"
    return 0
  fi
  local rpmf="" cand=() idx url
  if [[ -n "$MONGOSH_RPM" ]]; then
    rpmf="$MONGOSH_RPM"
  else
    cand=( "$SRC_DIR"/mongodb-mongosh*.rpm )
    [[ -f "${cand[0]}" ]] && rpmf="${cand[0]}"
  fi
  if [[ -z "$rpmf" ]]; then
    echo "No hay rpm local de mongosh; intentando instalarlo desde el repositorio oficial de MongoDB ${MONGO_MAJOR} ..."
    setup_repo
    if dnf -y install mongodb-mongosh >/dev/null 2>&1 && command -v mongosh >/dev/null 2>&1; then
      echo "mongosh instalado desde el repositorio: $(mongosh --version 2>/dev/null | head -n 1)"
      return 0
    fi
    echo "El repositorio no pudo proveer mongosh; buscando la ultima version en downloads.mongodb.com ..."
    mkdir -p "$STAGE_DIR/mongosh"
    idx="$(curl -fsSL --max-time 60 https://downloads.mongodb.com/compass/mongosh.json 2>/dev/null || true)"
    url="$(grep -oE 'https://downloads\.mongodb\.com/compass/mongodb-mongosh-[0-9]+\.[0-9]+\.[0-9]+\.x86_64\.rpm' <<<"$idx" | sort -uV | tail -n 1 || true)"
    if [[ -n "$url" ]]; then
      echo "Descargando $url"
      curl -fSL --max-time 300 -o "$STAGE_DIR/mongosh/$(basename "$url")" "$url" && rpmf="$STAGE_DIR/mongosh/$(basename "$url")"
    fi
  fi
  [[ -n "$rpmf" && -f "$rpmf" ]] || die "No se pudo obtener mongosh. Descarga el rpm desde https://www.mongodb.com/try/download/shell (RPM, x86_64), copialo a $SRC_DIR (o usa MONGOSH_RPM=/ruta/archivo.rpm) y vuelve a ejecutar."
  dnf -y install "$rpmf" || die "No se pudo instalar $rpmf"
}
install_mongosh
command -v mongosh >/dev/null 2>&1 || die "mongosh no quedo en el PATH."

#------------------------------ 4. CONFIGURACION ------------------------------
info "4/9 Escribiendo $CONF"
[[ -f "$CONF" && ! -f "$CONF.orig" ]] && cp -a "$CONF" "$CONF.orig"

write_conf() {   # write_conf yes|no  (yes = autenticacion habilitada)
  local auth="$1" forking="no"
  [[ -f /usr/lib/systemd/system/mongod.service ]] && grep -q 'Type=forking' /usr/lib/systemd/system/mongod.service && forking="yes"
  {
    cat <<EOF
storage:
  dbPath: $DB_PATH
systemLog:
  destination: file
  logAppend: true
  path: $LOG_PATH
net:
  port: $PORT
  bindIp: $BIND_IP
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF
    if [[ "$forking" == "yes" ]]; then
      printf '  fork: true\n  pidFilePath: /var/run/mongodb/mongod.pid\n'
    fi
    if [[ "$REPLICA_SET" == "yes" ]]; then
      printf 'replication:\n  replSetName: %s\n' "$RS_NAME"
    fi
    if [[ "$auth" == "yes" ]]; then
      printf 'security:\n  authorization: enabled\n'
      if [[ "$REPLICA_SET" == "yes" ]]; then printf '  keyFile: %s\n' "$KEYFILE"; fi
    fi
  } > "$CONF"
  chmod 644 "$CONF"
}

setup_js() {   # idempotente: crea admin, usuario de aplicacion y coleccion solo si faltan
  cat <<EOF
let adm = db.getSiblingDB('admin');
if (!adm.getUser('${ADMIN_USER}')) {
  adm.createUser({user: '${ADMIN_USER}', pwd: '${ADMIN_PASS}', roles: [{role: 'root', db: 'admin'}]});
  print('usuario ${ADMIN_USER} creado');
}
let app = db.getSiblingDB('${DB_NAME}');
if (!app.getUser('${APP_USER}')) {
  app.createUser({user: '${APP_USER}', pwd: '${APP_PASS}', roles: [{role: 'readWrite', db: '${DB_NAME}'}, {role: 'dbAdmin', db: '${DB_NAME}'}, {role: 'userAdmin', db: '${DB_NAME}'}]});
  print('usuario ${APP_USER} creado en ${DB_NAME}');
}
// userAdmin: el engine de IIDR consulta usersInfo; sin este rol falla con "not authorized ... usersInfo"
app.grantRolesToUser('${APP_USER}', [{role: 'userAdmin', db: '${DB_NAME}'}]);
if (!app.getCollectionNames().includes('${COLLECTION}')) {
  app.createCollection('${COLLECTION}');
  print('coleccion ${DB_NAME}.${COLLECTION} creada');
}
EOF
}

#------------------------------ 5. ARRANQUE Y USUARIOS ------------------------
info "5/9 Arrancando mongod y creando usuarios/base"
systemctl enable mongod >/dev/null 2>&1 || true

ALREADY="no"
if systemctl is-active --quiet mongod; then
  out="$(msh_admin --eval 'db.runCommand({ping:1}).ok' 2>&1 || true)"
  [[ "${out//[[:space:]]/}" == "1" ]] && ALREADY="yes"
fi

if [[ "$ALREADY" == "yes" ]]; then
  info "MongoDB ya esta en ejecucion con autenticacion y el usuario '$ADMIN_USER'; solo se completan los objetos faltantes."
else
  # Fase A: sin autenticacion para crear los usuarios
  write_conf no
  systemctl restart mongod
  if ! wait_mongod noauth; then diag_mongod; die "mongod no respondio al arrancar. Revisa el diagnostico anterior."; fi

  if [[ "$REPLICA_SET" == "yes" ]]; then
    echo "Inicializando replica set $RS_NAME ..."
    msh --eval "try { rs.status().ok } catch (e) { printjson(rs.initiate({_id: '${RS_NAME}', members: [{_id: 0, host: '${CONNECT_HOST}:${PORT}'}]})) }" >/dev/null
    wait_primary msh || { diag_mongod; die "El nodo no llego a PRIMARY."; }
  fi

  msh --eval "$(setup_js)"

  # Fase B: habilitar autenticacion (y keyFile si hay replica set) y reiniciar
  if [[ "$REPLICA_SET" == "yes" && ! -f "$KEYFILE" ]]; then
    openssl rand -base64 756 > "$KEYFILE"
  fi
  if [[ "$REPLICA_SET" == "yes" ]]; then
    chown "$MONGO_OSUSER:$MONGO_OSUSER" "$KEYFILE"; chmod 400 "$KEYFILE"
  fi
  write_conf yes
  systemctl restart mongod
  if ! wait_mongod auth; then
    diag_mongod
    die "No se pudo autenticar como '$ADMIN_USER' tras habilitar autenticacion (si la instancia ya tenia usuarios con otra password, usa ADMIN_PASS=...)."
  fi
  if [[ "$REPLICA_SET" == "yes" ]]; then wait_primary msh_admin || { diag_mongod; die "El nodo no llego a PRIMARY."; }; fi
fi

# Pasada final idempotente con autenticacion (completa lo que falte)
msh_admin --eval "$(setup_js)"

#------------------------------ 6. SELINUX / FIREWALL -------------------------
info "6/9 SELinux y firewall"
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  warn "SELinux esta en Enforcing. Si mongod falla, revisa: ausearch -m avc -ts recent"
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if [[ "$BIND_IP" != "127.0.0.1" ]]; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" && firewall-cmd --reload
    echo "Puerto ${PORT}/tcp abierto en firewalld"
  else
    echo "firewalld activo y mongod solo escucha en loopback: no se abre el puerto (acceso por tunel SSH)."
  fi
else
  echo "firewalld inactivo (modo demo)."
fi

#------------------------------ 7. SSHD ---------------------------------------
info "7/9 Verificando port forwarding en sshd (necesario para el tunel)"
if command -v sshd >/dev/null 2>&1; then
  FWD="$(sshd -T 2>/dev/null | awk '/^allowtcpforwarding/ {print $2}' || true)"
  if [[ "$FWD" == "no" || "$FWD" == "remote" ]]; then
    warn "sshd tiene AllowTcpForwarding=$FWD; el tunel fallara. Cambialo a 'yes' en /etc/ssh/sshd_config y ejecuta: systemctl reload sshd"
  else
    echo "OK: sshd permite port forwarding (AllowTcpForwarding=${FWD:-yes})"
  fi
fi

#------------------------------ 8. VERIFICACION -------------------------------
info "8/9 Verificando el servicio, el listener y el login del usuario de aplicacion"
SS_OUT="$(ss -ltn 2>/dev/null || true)"
if grep -qE "[:.]${PORT}[[:space:]]" <<<"$SS_OUT"; then
  echo "OK: puerto $PORT en escucha:"; grep -E "[:.]${PORT}[[:space:]]" <<<"$SS_OUT" || true
else
  warn "No se ve el puerto $PORT en escucha. Revisa $LOG_PATH"
fi
if (exec 3<>/dev/tcp/"$CONNECT_HOST"/"$PORT") 2>/dev/null; then
  echo "OK: conexion TCP a $CONNECT_HOST:$PORT exitosa"
else
  warn "No se pudo abrir conexion TCP a $CONNECT_HOST:$PORT"
fi

APP_OUT="$(mongosh --quiet "$URI_APP" --eval "db.getName() + ' -> colecciones: ' + db.getCollectionNames().join(', ')" 2>&1 || true)"
if [[ "$APP_OUT" == *"$DB_NAME"* && "$APP_OUT" != *"rror"* ]]; then
  echo "OK: login de '$APP_USER' en '$DB_NAME': $APP_OUT"
else
  warn "El login de '$APP_USER' en '$DB_NAME' no se pudo verificar: $APP_OUT"
fi

#------------------------------ 9. RESUMEN ------------------------------------
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"; HOST_IP="${HOST_IP:-127.0.0.1}"
info "9/9 Resumen"
echo
echo "=============================== RESUMEN ================================="
echo "MongoDB       : $(mongod --version | head -n 1)"
echo "mongosh       : $(mongosh --version 2>/dev/null | head -n 1)"
echo "Servicio      : $(systemctl is-active mongod) (enabled: $(systemctl is-enabled mongod 2>/dev/null || echo '?'))"
echo "Escucha en    : $BIND_IP:$PORT   (host $HOST_IP)"
echo "Replica set   : $REPLICA_SET$([[ "$REPLICA_SET" == "yes" ]] && echo " ($RS_NAME)")"
echo "Metodo        : $METHOD"
echo "Admin         : $ADMIN_USER / $ADMIN_PASS   (authSource=admin)"
echo "Usuario IIDR  : $APP_USER / $APP_PASS   (readWrite + dbAdmin + userAdmin sobre $DB_NAME, authSource=$DB_NAME)"
echo "Destino       : base '$DB_NAME', coleccion '$COLLECTION'"
echo "Log instalador: $LOG"
echo
echo "---- Conexion desde tu maquina local (tunel SSH) ----"
echo "Tunel (terminal):  ssh -N -L ${PORT}:127.0.0.1:${PORT} <usuario_ssh>@${HOST_IP}"
echo "Cadena de conexion (con el tunel abierto):"
echo "   mongodb://${APP_USER}:${APP_PASS}@localhost:${PORT}/${DB_NAME}?authSource=${DB_NAME}&directConnection=true"
echo "   mongodb://${ADMIN_USER}:${ADMIN_PASS}@localhost:${PORT}/admin?authSource=admin&directConnection=true"
echo "URL para IIDR (dmconfigurets, usuario/password $APP_USER/$APP_PASS, usa 127.0.0.1 y no localhost):"
echo "   mongodb://127.0.0.1:${PORT}/?authSource=${DB_NAME}&replicaSet=${RS_NAME}"
echo "AVISO: IIDR necesita ver al menos un documento en la coleccion para descubrir sus campos; si el mapeo dice"
echo "        'does not have columns', inserta un documento de ejemplo con los campos de la tabla y borralo despues."
echo "En el servidor:    mongosh \"mongodb://${APP_USER}:${APP_PASS}@127.0.0.1:${PORT}/${DB_NAME}?authSource=${DB_NAME}\""
echo "========================================================================="
