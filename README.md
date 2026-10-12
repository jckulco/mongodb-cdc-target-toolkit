# MongoDB 8.0 Target Toolkit para IBM InfoSphere Data Replication (CDC) 11.4

[![RHEL 9](https://img.shields.io/badge/OS-RHEL%209-red.svg)](https://www.redhat.com/)
[![MongoDB 8.0](https://img.shields.io/badge/MongoDB-8.0.x-green.svg)](https://www.mongodb.com/)
[![IBM CDC 11.4](https://img.shields.io/badge/IBM%20IIDR%2FCDC-11.4-blue.svg)](https://www.ibm.com/products/infosphere-data-replication)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Author](https://img.shields.io/badge/Author-Julio%20C%C3%A9sar%20Garc%C3%ADa%20Hern%C3%A1ndez-blue?style=flat&logo=linkedin)](https://www.linkedin.com/in/jcgarciahdz/)

Conjunto de herramientas de automatización e infraestructura para aprovisionar, configurar y validar **MongoDB 8.0.x Enterprise/Community** en **Red Hat Enterprise Linux (RHEL) 9** optimizado específicamente como destino (**Target / Apply Engine**) de replicación continua en tiempo real mediante **IBM InfoSphere Data Replication (IIDR) / Change Data Capture (CDC) v11.4**.

---

## 👨‍💻 Autoría y Créditos

Este repositorio y toolkit fueron diseñados, desarrollados y mantenidos por:

* **Autor:** **Julio César García Hernández**
* **Perfil Profesional en LinkedIn:** [https://www.linkedin.com/in/jcgarciahdz/](https://www.linkedin.com/in/jcgarciahdz/)
* **Especialidad:** Soluciones de Arquitectura de Datos, Modernización, CDC, Data Replication e Infraestructura Híbrida.

---

## 📑 Tabla de Contenidos

1. [Resumen Ejecutivo](#-resumen-ejecutivo)
2. [Arquitectura de Integración](#-arquitectura-de-integración)
3. [Consideraciones Críticas para IBM CDC 11.4 Target](#-consideraciones-críticas-para-ibm-cdc-114-target)
4. [Componentes del Toolkit](#-componentes-del-toolkit)
5. [Requisitos Previos](#-requisitos-previos)
6. [Guía de Despliegue Rápido](#-guía-de-despliegue-rápido)
   - [Despliegue Completo Automatizado](#despliegue-completo-automatizado)
   - [Conversión de Standalone a Replica Set](#conversión-de-standalone-a-replica-set)
   - [Verificación de Salud y Roles](#verificación-de-salud-y-roles)
   - [Sembrado de Esquema para Descubrimiento de Metadatos](#sembrado-de-esquema-para-descubrimiento-de-metadatos)
7. [Matriz de Variables y Parametrización](#-matriz-de-variables-y-parametrización)
8. [Configuración en IBM InfoSphere CDC Engine (`dmconfigurets`)](#-configuración-en-ibm-infosphere-cdc-engine-dmconfigurets)
9. [Seguridad y Acceso Remoto vía Túnel SSH](#-seguridad-y-acceso-remoto-vía-túnel-ssh)
10. [Diagnóstico y Troubleshooting](#-diagnóstico-y-troubleshooting)
11. [Licencia](#-licencia)

---

## 📌 Resumen Ejecutivo

**IBM InfoSphere Data Replication (IIDR) Change Data Capture (CDC)** permite capturar cambios de bases de datos de origen (como IBM Db2, Informix, Oracle, PostgreSQL, SQL Server) y aplicarlos en tiempo real y con ultra baja latencia en bases de datos NoSQL y repositorios modernos como **MongoDB**.

A partir de **IIDR 11.4 (Engine para MongoDB Target)**, se incorpora soporte oficial para **MongoDB 8.0.x**. Sin embargo, la integración con MongoDB requiere cumplir estrictas restricciones de topología, seguridad y roles:

* **Topología Obligatoria:** IIDR no soporta instancias en modo `standalone`. Requiere obligatoriamente un **Replica Set** (incluso de un solo nodo en entornos de desarrollo/demo) o un clúster particionado (**Sharded Cluster**).
* **Control de Acceso y RBAC:** El motor de CDC consulta internamente el comando `usersInfo` durante la negociación del handshake de autenticación. Sin el rol administrativo `userAdmin` en la base destino, la conexión falla con error de autorización.
* **Autenticación Interna de Nodos:** Al habilitar Replica Set con autenticación, MongoDB exige un mecanismo de llave compartida (`keyFile`) con permisos estrictos `400` propiedad del usuario de sistema operativo `mongod`.
* **Descubrimiento de Metadatos:** En MongoDB, las colecciones son libres de esquema (schema-less), pero IBM CDC Management Console requiere que exista al menos un documento representativo para mapear las columnas relacionales del origen a campos JSON/BSON.

Este toolkit resuelve y automatiza de forma **idempotente y repetible** todo el ciclo de vida de instalación y preparación de la base de datos destino.

---

## 🏛️ Arquitectura de Integración

```mermaid
flowchart LR
    subgraph Source["Origen de Datos (Source Engine)"]
        DB[("Base de Datos Origen<br/>(Db2 / Informix / Oracle / PG)")]
        CDCS["IBM InfoSphere CDC<br/>Source Engine"]
        DB -->|Log Scraping / CDC| CDCS
    end

    subgraph Transport["Capa de Red Segura"]
        SSH["Túnel SSH / Red Local<br/>(127.0.0.1:27017)"]
    end

    subgraph Target["Destino MongoDB (Target Engine)"]
        CDCT["IBM InfoSphere CDC<br/>Target Engine (dmconfigurets)"]
        
        subgraph MongoEnv["MongoDB 8.0.x (RHEL 9)"]
            RS["Replica Set (rs0 / Single-Node)<br/>KeyFile Auth + SCRAM-SHA-256"]
            DB_TARGET[("Base de Datos Destino<br/>'iidr'")]
            COLL[("Colección Destino<br/>'customers'")]
            
            RS --> DB_TARGET --> COLL
        end
        
        CDCT -->|Apply Operations| RS
    end

    subgraph Management["Gestión y Control"]
        MC["IBM CDC Management Console<br/>(GUI / CLI)"]
    end

    CDCS ==>|TCP Streaming| CDCT
    MC -.->|Monitoreo y Mapeo| CDCS
    MC -.->|Mapeo de Tablas a Docs| CDCT
    CDCT --- SSH
```

---

## 🔑 Consideraciones Críticas para IBM CDC 11.4 Target

| Requisito | Detalle | Comportamiento si no se cumple |
| :--- | :--- | :--- |
| **Versión MongoDB** | Soporta versiones **8.0.x** (no compatible con ramas provisionales o 8.1+ sin fix pack). | El conector CDC rechaza la versión o arroja incompatibilidad de driver. |
| **Topología Replica Set** | Obligatorio `replication.replSetName: rs0` con `keyFile`. | `dmconfigurets` o Management Console rechazan el target indicando que la instancia es `standalone`. |
| **Rol `userAdmin`** | El usuario CDC (`iidr`) debe contar con `readWrite`, `dbAdmin` y `userAdmin` en la base destino. | Error: `com.mongodb.MongoSecurityException: not authorized on <db> to execute command usersInfo`. |
| **Direct Connection** | Para replica sets de un solo nodo registrados en `127.0.0.1`. | Errores de resolución DNS o intento de resolver `localhost` a IPv6 `::1`. |
| **Sembrado de Esquema** | La colección debe contener al menos 1 documento previo al mapeo. | Management Console muestra el error: `Target table/collection does not have columns`. |

---

## 📦 Componentes del Toolkit

| Archivo | Descripción |
| :--- | :--- |
| [`install_mongodb_cdc_target.sh`](install_mongodb_cdc_target.sh) | **Script Principal:** Instala MongoDB 8.0, configura mongosh, habilita autenticación, genera keyfile, inicia replica set, crea usuarios y colecciones. |
| [`mongodb_enable_replicaset.sh`](mongodb_enable_replicaset.sh) | **Conversión Standalone:** Migra una instancia MongoDB ya existente en modo standalone a un Replica Set `rs0` de 1 nodo sin pérdida de datos. |
| [`verify_mongodb_cdc_target.sh`](verify_mongodb_cdc_target.sh) | **Diagnóstico y Salud:** Valida conectividad, autenticación de admin y CDC, roles de IIDR y estado `PRIMARY` del Replica Set. |
| [`seed_sample_document.sh`](seed_sample_document.sh) | **Sembrador de Esquema:** Inserta o limpia un documento prototipo en la colección para permitir el descubrimiento de metadatos en CDC. |

---

## 📋 Requisitos Previos

* **Sistema Operativo:** Red Hat Enterprise Linux (RHEL) 9.x (x86_64).
* **Permisos:** Acceso de usuario `root` o `sudo` en el servidor destino.
* **Paquetería base:** `dnf`, `curl`, `openssl`, `tar`, `python3` (para manipulación de archivos `.conf`).
* **Conectividad:** Acceso a `repo.mongodb.org` (o disponer de los paquetes RPM / TGZ en `/opt`).

---

## 🚀 Guía de Despliegue Rápido

### Despliegue Completo Automatizado

Ejecuta el script principal para realizar la instalación completa desatendida:

```bash
chmod +x install_mongodb_cdc_target.sh
sudo ./install_mongodb_cdc_target.sh
```

O personalizando variables mediante entorno:

```bash
sudo DB_NAME=iidr_ventas \
     COLLECTION=clientes \
     ADMIN_USER=admin \
     ADMIN_PASS="SecretAdmin123!" \
     APP_USER=cdc_user \
     APP_PASS="SecretCdc123!" \
     ./install_mongodb_cdc_target.sh
```

El script ejecuta secuencialmente las 9 fases de aprovisionamiento:
1. **Selección del método de instalación** (`rpm`, `tgz`, o `repo` oficial).
2. **Instalación del servidor MongoDB 8.0.x** y configuración de directorios del sistema.
3. **Instalación del shell interactivo `mongosh`**.
4. **Generación de la configuración `/etc/mongod.conf`**.
5. **Arranque inicial, inicialización del Replica Set (`rs0`) y creación de usuarios/roles**.
6. **Verificación de reglas de SELinux y FirewallD**.
7. **Verificación de reenvío TCP en SSHD (`AllowTcpForwarding`)**.
8. **Validación de listeners TCP y login del usuario CDC**.
9. **Emisión del resumen de configuración y URIs de conexión**.

---

### Conversión de Standalone a Replica Set

Si ya cuentas con una instancia de MongoDB 8.0 instalada en modo *standalone* y deseas habilitarla para IBM CDC sin reinstalar:

```bash
chmod +x mongodb_enable_replicaset.sh
sudo ./mongodb_enable_replicaset.sh
```

Este script:
* Genera `/etc/mongod-keyfile` con permisos `400` y propietario `mongod:mongod`.
* Modifica `/etc/mongod.conf` insertando la directiva `replication.replSetName: rs0` y `security.keyFile`.
* Reinicia el servicio y ejecuta `rs.initiate()`.
* Espera hasta que el nodo alcance el estado `PRIMARY`.

---

### Verificación de Salud y Roles

Para certificar que la instancia cumple con todos los requisitos de IBM InfoSphere CDC:

```bash
chmod +x verify_mongodb_cdc_target.sh
./verify_mongodb_cdc_target.sh
```

**Salida esperada:**
```text
================================================================================
   Verificación de MongoDB 8.0 Target para IBM InfoSphere CDC / IIDR
================================================================================
[OK] mongosh disponible: 2.3.x
[OK] Servicio systemd 'mongod' está activo.
[INFO] Probando autenticación de administrador (admin)... OK
[INFO] Verificando estado de Replica Set (rs0)... rs0:PRIMARY
[INFO] Probando autenticación del usuario CDC (iidr) en 'iidr'... OK
[INFO] Inspeccionando colecciones en 'iidr':
  Colecciones disponibles: customers
```

---

### Sembrado de Esquema para Descubrimiento de Metadatos

Para que **IBM CDC Management Console** descubra las columnas que mapeará en la colección:

```bash
chmod +x seed_sample_document.sh

# 1. Insertar documento prototipo con los campos de la tabla origen
./seed_sample_document.sh insert

# 2. Consultar el documento insertado
./seed_sample_document.sh show

# 3. Tras mapear las tablas en CDC Management Console, limpiar el documento prototipo si se requiere
./seed_sample_document.sh clean
```

---

## ⚙️ Matriz de Variables y Parametrización

| Variable | Valor por Defecto | Descripción |
| :--- | :--- | :--- |
| `SRC_DIR` | `/opt` | Directorio donde buscar RPMs o TGZs locales. |
| `MONGO_VERSION` | `8.0.32` | Versión exacta de MongoDB 8.0 a desplegar. |
| `INSTALL_METHOD` | `auto` | Método de instalación: `auto`, `rpm`, `tgz`, o `repo`. |
| `BIND_IP` | `127.0.0.1` | Dirección IP de escucha (`127.0.0.1` recomendado para acceso por túnel SSH). |
| `PORT` | `27017` | Puerto de escucha de MongoDB. |
| `DB_PATH` | `/var/lib/mongo` | Directorio físico de datos. |
| `LOG_PATH` | `/var/log/mongodb/mongod.log` | Archivo de bitácora de MongoDB. |
| `CONF` | `/etc/mongod.conf` | Ruta del archivo de configuración. |
| `REPLICA_SET` | `yes` | Habilitar Replica Set (`yes` obligatorio para IBM CDC). |
| `RS_NAME` | `rs0` | Nombre del Replica Set. |
| `KEYFILE` | `/etc/mongod-keyfile` | Ruta de la llave criptográfica compartida. |
| `ADMIN_USER` | `admin` | Usuario administrador de MongoDB (rol `root` en `admin`). |
| `ADMIN_PASS` | `admin` | Contraseña del usuario administrador. |
| `DB_NAME` | `iidr` | Base de datos destino donde se replicarán los datos. |
| `APP_USER` | `iidr` | Usuario de replicación que usará el motor CDC. |
| `APP_PASS` | `iidr` | Contraseña del usuario de replicación. |
| `COLLECTION` | `customers` | Nombre de la colección inicial. |

---

## 🔌 Configuración en IBM InfoSphere CDC Engine (`dmconfigurets`)

Al ejecutar la herramienta de configuración de instancias de CDC (`dmconfigurets`) en el servidor donde reside el **IBM CDC Target Engine**:

```mermaid
sequenceDiagram
    autonumber
    participant Admin as Administrador
    participant CDC as dmconfigurets (CDC Engine)
    participant Mongo as MongoDB 8.0 (Target)

    Admin->>CDC: Crear nueva instancia de destino (Target)
    CDC->>Admin: Solicitar DBMS Type -> Seleccionar 'MongoDB'
    Admin->>CDC: Ingresar Database Name -> 'iidr'
    Admin->>CDC: Ingresar Connection URI
    Note over Admin,CDC: mongodb://127.0.0.1:27017/?authSource=iidr&replicaSet=rs0
    Admin->>CDC: Ingresar Usuario -> 'iidr' y Contraseña
    CDC->>Mongo: Autenticación SCRAM-SHA-256 + comando usersInfo
    Mongo-->>CDC: Handshake exitoso (Roles: readWrite, dbAdmin, userAdmin)
    CDC-->>Admin: Instancia configurada y lista para iniciar
```

### Parámetros de Configuración en `dmconfigurets`:

* **Nombre de la base de datos:** `iidr` (o el valor de `$DB_NAME`)
* **Usuario:** `iidr` (o el valor de `$APP_USER`)
* **Contraseña:** `iidr` (o el valor de `$APP_PASS`)
* **Cadena de Conexión (MongoDB URI):**
  ```text
  mongodb://127.0.0.1:27017/?authSource=iidr&replicaSet=rs0
  ```
* **Cadena alternativa con conexión directa (si aplica):**
  ```text
  mongodb://127.0.0.1:27017/?authSource=iidr&replicaSet=rs0&directConnection=true
  ```

---

## 🔒 Seguridad y Acceso Remoto vía Túnel SSH

Por mejores prácticas de seguridad, el listener de MongoDB se enlaza exclusivamente a `127.0.0.1` (`BIND_IP=127.0.0.1`), impidiendo la exposición del puerto 27017 a redes públicas.

Para conectar herramientas de escritorio (como **MongoDB Compass**, **DBeaver** o la **CDC Management Console** desde tu estación de trabajo):

### 1. Establecer el Túnel SSH:
```bash
ssh -N -L 27017:127.0.0.1:27017 <usuario_servidor>@<ip_servidor_mongodb>
```

### 2. Cadena de Conexión Local en tu Estación:
```text
mongodb://iidr:iidr@localhost:27017/iidr?authSource=iidr&directConnection=true
```

---

## 🔍 Diagnóstico y Troubleshooting

### 1. Error: `not authorized on <db> to execute command usersInfo`
* **Causa:** El motor CDC consulta `usersInfo` durante el inicio de la replicación.
* **Solución:** Asignar el rol `userAdmin` al usuario de aplicación sobre la base destino:
  ```bash
  mongosh "mongodb://admin:admin@127.0.0.1:27017/admin?authSource=admin" --eval \
    "db.getSiblingDB('iidr').grantRolesToUser('iidr', [{role: 'userAdmin', db: 'iidr'}])"
  ```

### 2. Error: `Target table does not have columns` en CDC Management Console
* **Causa:** MongoDB no tiene un esquema rígido; CDC requiere examinar la estructura JSON de al menos un documento para inferir los tipos de datos.
* **Solución:** Ejecutar `./seed_sample_document.sh insert`.

### 3. Error: `Node is not PRIMARY` o `Replica set is not initialized`
* **Causa:** El replica set no ha sido inicializado o el nodo no ha ganado la elección.
* **Solución:** Ejecutar `./mongodb_enable_replicaset.sh` o verificar en `mongosh`:
  ```bash
  mongosh "mongodb://admin:admin@127.0.0.1:27017/admin" --eval "rs.status()"
  ```

### 4. Revisión de Bitácoras del Sistema
```bash
# Bitácora de MongoDB:
tail -f /var/log/mongodb/mongod.log

# Bitácora del servicio systemd:
journalctl -u mongod -f --no-pager

# Bitácora del instalador:
cat /var/log/install_mongodb_cdc.log
```

---

## 📄 Licencia

Este proyecto está distribuido bajo los términos de la Licencia **Apache 2.0**. Consulta el archivo [`LICENSE`](LICENSE) para obtener más detalles.

---

<p align="center">
  <b>Desarrollado con dedicación profesional para proyectos de integración y replicación empresarial</b><br>
  <i>Para consultas técnicas o colaboración, contacta a <a href="https://www.linkedin.com/in/jcgarciahdz/">Julio César García Hernández en LinkedIn</a>.</i>
</p>
