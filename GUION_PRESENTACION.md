# GUION DE PRESENTACION - PROYECTO MEDISTOCK
## Evaluacion "Taller de Base de Datos" - MongoDB como base principal + Oracle como replica PL/SQL

**Duracion objetivo:** 10 a 12 minutos.
**Carpeta de trabajo:** `C:\Users\pazMa\Downloads\Medistock_Oracle\evaluacion_plsql`
**Archivos que se usan:**

| Archivo | Para que sirve |
|---|---|
| `evaluacion_medistock.sql` | Todo el PL/SQL de la rubrica (RECORD, funcion, VARRAY, cursores anidados, excepcion, trigger, paquete) + datos de prueba |
| `demo_conexion.js` | Demostracion fisica MongoDB -> Oracle desde Node.js |
| `salida_esperada_sqlplus.txt` | Salida exacta que debe aparecer (captura real, para comparar) |
| `.env.example` | Plantilla de credenciales para el script de Node |
| `package.json` | Declara los drivers `mongodb` y `oracledb` ya instalados |

**Estado ya verificado en este equipo (no hay que instalarlo):**

- MongoDB corriendo como servicio `MongoDB` en `localhost:27017`, base `medistock` con la coleccion `products`.
- Oracle XE 21c corriendo como servicio `OracleServiceXE` + listener `OracleOraDB21Home1TNSListener`.
- Esquema `C##MEDISTOCK` con las 8 tablas `MED_*`, el paquete `MEDISTOCK_SINCRONIZACION` y el trigger de auditoria.
- El esquema vive en el contenedor raiz: la cadena de conexion es **`localhost:1521/XE`** (NO `XEPDB1`).
- Drivers de Node ya instalados en esta carpeta (`npm install` hecho).

---

## 1. Levantar las bases de datos (2 minutos)

Abrir **una terminal** (Git Bash o la terminal de VS Code) y ejecutar:

```bash
# 1.1 Ver si los servicios ya estan arriba
net start | grep -i -E "mongo|oracle"

# 1.2 Si falta MongoDB, arrancarlo (pide permisos de administrador)
net start "MongoDB"

# 1.3 Si falta Oracle, arrancar el motor y luego el listener
net start OracleServiceXE
net start OracleOraDB21Home1TNSListener
```

Verificacion rapida de que ambos puertos escuchan (debe aparecer `1521` y `27017`):

```bash
netstat -ano | grep -E ":1521|:27017" | grep LISTENING
```

Que decir mientras se ejecuta:
> "MongoDB es la base principal del proyecto y escucha en el puerto 27017. Oracle XE es la replica que guarda la logica PL/SQL y escucha en el 1521. Los dos corren como servicios de Windows, por eso los levanto desde la terminal."

**Opcional (si el profesor quiere ver las colecciones):** abrir MongoDB Compass -> `mongodb://localhost:27017` -> base `medistock` -> coleccion `products`.

---

## 2. Ejecutar el PL/SQL de la rubrica (4 minutos)

### Opcion A - SQL*Plus en la terminal (la mas segura para la demo)

```bash
cd /c/Users/pazMa/Downloads/Medistock_Oracle/evaluacion_plsql

# Acentos correctos en la salida
export NLS_LANG='SPANISH_SPAIN.AL32UTF8'

# Conectarse al esquema (pide la contrasena de C##MEDISTOCK de forma interactiva)
sqlplus 'C##MEDISTOCK@//localhost:1521/XE'

# Ya dentro de SQL*Plus:
@evaluacion_medistock.sql
```

Para salir: `exit`.

### Opcion B - Oracle SQL Developer

1. Nueva conexion: usuario `C##MEDISTOCK`, contrasena la del esquema, **Nombre del servicio** `XE`, host `localhost`, puerto `1521`.
2. Abrir `evaluacion_medistock.sql`.
3. Ejecutar con **Run Script (F5)**, nunca con "Run Statement": el archivo usa `/` como separador de bloques PL/SQL.
4. La salida de `DBMS_OUTPUT` aparece en el panel **Script Output** (el archivo ya trae `SET SERVEROUTPUT ON`).

### Opcion C - DBeaver (esta instalado en el equipo)

1. Conexion Oracle -> host `localhost`, puerto `1521`, base de datos/SID `XE`, usuario `C##MEDISTOCK`.
2. Abrir el archivo y ejecutar con **Execute SQL Script (Alt+X)**.
3. Activar el panel **Output / Server Output** del editor para ver `DBMS_OUTPUT`.
4. **Importante:** las lineas `SET ...` y `COLUMN ...` son comandos de SQL*Plus; DBeaver las marca como no soportadas y las ignora. No afectan al resultado. Si prefieres una ejecucion limpia, usa la Opcion A.

### Que debe aparecer en pantalla (resumen de la captura real)

Orden de la salida y su significado:

1. `Tipo T_IDS_PEDIDO ya existia` / `creado` -> preparacion del VARRAY de nivel de esquema.
2. `5 filas fusionadas`, `3 filas fusionadas`, `6 filas fusionadas` -> carga de los datos de prueba (productos, pedidos, detalle).
3. **PARTE 2 - RECORD:**
   ```
   === PRODUCTOS CON STOCK BAJO (RECORD + cursor) ===
   SKU         PRODUCTO                          CATEGORIA       STOCK / MIN
   --------------------------------------------------------------------------------
   GUA-001     Guantes de Nitrilo M (caja 100)   Insumos         4 / 20  (faltan 16)
   ALG-001     Alcohol Gel 500 ml                Insumos         8 / 10  (faltan 2)
   --------------------------------------------------------------------------------
   Productos criticos: 2 | Unidades faltantes: 18
   ```
4. **PARTE 3 - funcion:** `VALOR_TOTAL_INVENTARIO = 821200`.
5. **PARTE 4 - VARRAY:**
   ```
   === MARCAR PEDIDOS COMO ENVIADOS (VARRAY de 3 IDs) ===
     Pedido PED-1001 -> shipped
     Pedido PED-1003 -> shipped
     Pedido PED-9999 -> no existe, se omite
   Actualizados: 2 | No encontrados: 1
   ```
6. **PARTE 5 - cursores anidados:** cada producto de la categoria `Insumos` con sus pedidos debajo (ALG-001, GAS-001, GUA-001, MSK-001).
7. **PARTE 6 - excepcion de precio:**
   ```
   === VALIDACION DE PRECIO (excepcion definida por el usuario) ===
     Rechazado  -> ORA-20010: Precio invalido para DEM-001: -1500. El precio debe ser mayor o igual a cero.
   Producto prod-demostracion-01 registrado correctamente.
   ```
8. **PARTE 7 - trigger:**
   ```
   === VALIDACION DE STOCK EN EL TRIGGER ===
     Bloqueado  -> ORA-20003: Stock invalido (-5) para el producto GAS-001. El stock no puede ser negativo.
   ORA-06512: en "C##MEDISTOCK.MED_PRODUCTOS_STOCK_VALIDA_TRG", linea 3
     Stock valido aceptado para prod-gasas-01.
   ```
9. **PARTE 8-9 - paquete:** `Valor total inventario : 821.200,00`, `Productos bajo minimo : 2`, el reporte anidado y las 3 consultas de control finales.

> Los unicos errores que deben verse son **ORA-20010** y **ORA-20003**: son las validaciones funcionando (estan capturadas dentro del bloque para que el script continue). Cualquier otro `ORA-` es un problema real.

---

## 3. Demostracion de la conexion MongoDB -> Oracle (3 minutos)

### Preparacion (una sola vez, antes de la presentacion)

```bash
cd /c/Users/pazMa/Downloads/Medistock_Oracle/evaluacion_plsql
cp .env.example .env
# Editar .env y poner la contrasena real de C##MEDISTOCK en ORACLE_PASSWORD
```

Si no quieres crear `.env`, puedes pasar la clave por variable de entorno:

```bash
ORACLE_PASSWORD='tu_clave' node demo_conexion.js
```

### Ejecucion (el comando que se muestra al profesor)

```bash
cd /c/Users/pazMa/Downloads/Medistock_Oracle/evaluacion_plsql
node demo_conexion.js
```

### Que hace el script, paso por paso, y que dice en pantalla

| Paso | Accion real | Salida visible |
|---|---|---|
| 1 | Conecta a MongoDB y cuenta documentos | `Documentos en products 1` |
| 2 | Busca el producto `demo-sync-01`; si no existe lo inserta, si existe le suma 10 al stock | `producto no existia: insertado en MongoDB` (1a vez) / `producto encontrado y actualizado (+10 stock)` (2a vez) |
| 3 | Conecta a Oracle y muestra la version y el usuario | `Oracle Database 21c Express Edition`, `C##MEDISTOCK @ CDB$ROOT` |
| 4 | Invoca `MEDISTOCK_SINCRONIZACION.APLICAR_CAMBIO('products','UPSERT', json)` | `Tiempo PL/SQL 21 ms`, `Commit realizado` |
| 5 | `SELECT` en `MED_PRODUCTOS` | tabla con `demo-sync-01 / SYNC-DEMO-01 / 19990 / 25` |
| 6 | Compara el stock de Mongo con el de Oracle | `RESULTADO: OK - la sincronizacion MongoDB -> Oracle quedo demostrada.` |

**Truco para la presentacion:** ejecutarlo dos veces seguidas. La primera inserta (`stock 25`), la segunda actualiza (`stock 35`). Asi se demuestra que el `MERGE` del paquete cubre los dos caminos del UPSERT sin cambiar una linea de codigo.

### Si quieres verlo tambien "por el otro lado"

Con la terminal de Node todavia abierta, en otra ventana corre la consulta en Oracle:

```bash
sqlplus 'C##MEDISTOCK@//localhost:1521/XE'
```

```sql
SET LINESIZE 200
SELECT ID_PRODUCTO, SKU, NOMBRE, PRECIO, STOCK, STOCK_MINIMO
  FROM MED_PRODUCTOS
 WHERE ID_PRODUCTO = 'demo-sync-01';
```

La fila existe con el mismo stock que muestra la salida de Node.

---

## 4. Guion oral, minuto por minuto

**0:00 - 0:40 | Contexto**
> "Medistock es un inventario para insumos clinicos. MongoDB es la base principal: ahi viven los documentos de productos, pedidos y usuarios. Oracle es una replica unidireccional que mantiene las mismas entidades en tablas relacionales, y sobre esa replica corre la logica PL/SQL del taller: reportes de stock, actualizaciones masivas, validaciones y auditoria."

**0:40 - 1:30 | Levanto las bases**
> "MongoDB corre como servicio en el puerto 27017 y Oracle XE en el 1521. Verifico que los dos esten escuchando antes de conectarme, para no perder tiempo en vivo."

**1:30 - 5:00 | Ejecuto el PL/SQL (aqui va la rubrica)**
Ir mostrando cada bloque de `evaluacion_medistock.sql` y su salida, en el mismo orden del archivo:

1. "Primero un bloque anonimo con un **RECORD**: defino un tipo con los campos que necesito del producto y cargo cada fila del cursor ahi dentro. Detecta 2 productos bajo el minimo y 18 unidades faltantes."
2. "Segundo, una **funcion** que calcula el valor del inventario con `SUM(PRECIO * STOCK)`; hoy son 821.200 pesos."
3. "Tercero, un **procedimiento con VARRAY**: recibe hasta 100 IDs de pedidos y los pasa a `shipped`. Le mando dos IDs reales y uno inventado (`PED-9999`) para mostrar que informa lo que no encontro."
4. "Cuarto, un **cursor explicito parametrizado con loops anidados**: el cursor externo recibe la categoria `Insumos` y por cada producto abro el cursor interno con su ID para listar los pedidos donde aparece."
5. "Quinto, un **procedimiento con excepcion definida por el usuario**: si el precio es negativo, lanzo `E_PRECIO_NEGATIVO` y lo traduzco con `RAISE_APPLICATION_ERROR` a `ORA-20010`. Se ve el rechazo y luego el alta correcta."
6. "Sexto, el **trigger `BEFORE INSERT OR UPDATE OF STOCK`**: cualquier cliente que intente dejar el stock negativo recibe `ORA-20003`. Ojo: salta antes que el `CHECK` de la tabla, por eso el mensaje es el del trigger y no `ORA-02290`."
7. "Septimo, el **paquete `MEDISTOCK_GESTION`** agrupa todo con una interfaz unica; no duplica logica: delega en la funcion y los procedimientos ya probados."

**5:00 - 8:00 | La conexion fisica MongoDB -> Oracle**
> "Ahora la parte que conecta las dos bases. El backend Node usa dos drivers: `mongodb` y `oracledb`. El script hace cuatro cosas: lee el producto desde MongoDB, abre la conexion a Oracle, invoca `MEDISTOCK_SINCRONIZACION.APLICAR_CAMBIO` pasandole la entidad, la accion y el documento serializado como JSON, y finalmente hace un `SELECT` en `MED_PRODUCTOS` para comprobar que la fila existe."

Ejecutar `node demo_conexion.js` y narrar la salida:
> "Paso 2: el producto no existia en MongoDB, se inserto. Paso 4: la llamada PL/SQL tardo milisegundos y el commit quedo hecho. Paso 5: aqui esta la fila en Oracle, con el mismo precio y el mismo stock. Paso 6: la verificacion automatica compara las dos bases y confirma que coinciden."

Segunda ejecucion:
> "Lo corro otra vez: ahora el producto ya existe, se actualizo el stock en MongoDB y el `MERGE` del paquete hizo un UPDATE en Oracle. Es el mismo procedimiento cubriendo altas y modificaciones."

**8:00 - 10:00 | Cierre tecnico**
> "La logica de negocio vive una sola vez, en PL/SQL, y se ejecuta sobre la replica. MongoDB manda; Oracle valida, calcula y audita. El resultado de la sincronizacion se verifica leyendo la tabla, no confiando en la respuesta de la API."

---

## 5. Como explicar RECORD, VARRAY, cursores y triggers (la pregunta del profesor)

**La idea que hay que dejar clara:** los cuatro son mecanismos distintos del mismo lenguaje PL/SQL, y cada uno resuelve un problema distinto sobre las filas que llegan desde MongoDB.

```
   MongoDB (documento JSON)
            |
            |  demo_conexion.js  (driver oracledb)
            v
   MEDISTOCK_SINCRONIZACION.APLICAR_CAMBIO(entidad, accion, CLOB json)
            |
            |  JSON_VALUE / JSON_TABLE  ->  MERGE
            v
   Tablas MED_*  (MED_PRODUCTOS, MED_PEDIDOS, MED_DETALLE_PEDIDOS ...)
            |
            +--> TRIGGER      valida y audita cada fila (stock >= 0, historial)
            +--> CURSOR       recorre y filtra filas para los reportes
            +--> RECORD       guarda en memoria una fila del reporte
            +--> VARRAY       viaja desde Node/SQL con una lista de IDs
            +--> PACKAGE      agrupa y expone todo lo anterior
```

Frase para decirlo en una sola respiracion:
> "El JSON entra por el paquete de sincronizacion y se convierte en filas. Sobre esas filas, el trigger controla la integridad, el cursor las recorre, el RECORD las representa en memoria y el VARRAY transporta listas de claves. El paquete es la puerta de entrada ordenada a todo eso."

**RECORD** (bloque anonimo de la PARTE 2)
- Que es: una variable compuesta, definida por el programador, con campos de tipos distintos.
- Por que: en vez de declarar 6 variables sueltas para el reporte, se declara un tipo y se reutiliza.
- Detalle tecnico que impresiona: use `%TYPE` en cada campo, asi si cambia el tipo de la columna el bloque se adapta solo. Y agregue un campo calculado (`FALTANTE`) que no viene de la tabla.
- Aclaracion honesta: `FETCH ... INTO V_PRODUCTO` exige que el RECORD tenga exactamente la misma cantidad de campos que la lista del `SELECT`; por eso en el paquete se hace FETCH campo por campo (ese fue un error real de compilacion, PLS-00394, que corregi).
- Alternativa: `%ROWTYPE` cuando se quiere la fila completa de la tabla sin elegir columnas.

**VARRAY** (PARTE 4)
- Que es: un arreglo de tamano fijo y ordenado; aqui, hasta 100 IDs de pedido.
- Por que VARRAY y no una tabla temporal: es una coleccion acotada y ordenada, viaja entera en un solo parametro y no necesita TCL.
- Detalle tecnico: el tipo `T_IDS_PEDIDO` se crea **a nivel de esquema** (`CREATE TYPE ... AS VARRAY(100) OF VARCHAR2(100)`) porque un parametro de un procedimiento almacenado no puede declararse con un tipo definido dentro de otro bloque. Ese es el motivo de la PARTE 0 del archivo.
- Ventaja practica: pasar 50 IDs = 1 llamada al procedimiento en vez de 50 viajes de red.
- Recorrido: `FOR I IN 1 .. P_IDS_PEDIDO.COUNT` accede por indice; se controla `SQL%ROWCOUNT` para saber si el UPDATE afecto una fila y se distinguen los IDs inexistentes.

**Cursores con parametros y loops anidados** (PARTE 5)
- Que es: un cursor explicito declarado con un parametro; el parametro se evalua al abrir el cursor.
- Por que dos: el externo recibe la **categoria** y devuelve sus productos; el interno recibe **el ID del producto actual** del loop externo y devuelve sus pedidos. Es una relacion 1:N resuelta sin traer el producto cartesiano a memoria.
- Ventaja: se abre y cierra una vez por producto, no se repite la consulta escrita a mano.
- Alternativa que tambien esta en el archivo: el cursor de la PARTE 2 no tiene parametros y se recorre con `OPEN`/`FETCH`/`EXIT WHEN %NOTFOUND`/`CLOSE`, para mostrar el ciclo de vida explicito del cursor.

**Trigger** (PARTE 7)
- Que es: codigo que Oracle ejecuta automaticamente en el evento, una vez por fila (`FOR EACH ROW`).
- Por que se necesita si la tabla ya tiene `CHECK (STOCK >= 0)`: el `CHECK` protege la fila pero con un mensaje tecnico `ORA-02290`; el trigger entrega un mensaje de negocio con el SKU y el valor recibido, y sirve de punto unico de validacion sin importar el cliente que escriba (Node, SQL Developer, backend o SQL directo).
- Dato fino para el profesor: un `BEFORE ... FOR EACH ROW` se ejecuta **antes** de validar las restricciones, por eso en vivo se ve `ORA-20003` y no `ORA-02290`.
- El proyecto ademas tiene `MED_PRODUCTOS_STOCK_AUD_TRG`, que es `AFTER INSERT OR UPDATE OF STOCK` y escribe en `MED_HISTORIAL_STOCK`; mi trigger valida, el otro audita. La ultima consulta del archivo cuenta esas filas del historial.

**Paquete** (PARTE 8)
- Que es: una unidad con especificacion (contrato publico) y cuerpo (implementacion).
- Por que: agrupa la funcion y los procedimientos bajo un solo nombre, permite sobrecarga y evita recompilar consumidores si cambia solo el cuerpo.
- Decision de diseno que conviene declarar: el cuerpo **no copia** la logica; llama a `FN_VALOR_INVENTARIO`, `PR_MARCAR_PEDIDOS_ENVIADOS` y `PR_REGISTRAR_PRODUCTO`. Asi no hay dos versiones de la misma regla de negocio.

---

## 6. Preguntas probables y respuestas cortas

| Pregunta del profesor | Respuesta |
|---|---|
| "Por que Oracle si ya tienes MongoDB?" | "MongoDB resuelve el documento flexible de la tienda; Oracle aporta el modelo relacional, las restricciones, la transaccionalidad y el PL/SQL que evalua el taller. La sincronizacion es unidireccional: MongoDB -> Oracle." |
| "Que pasa si MongoDB cambia y Oracle no?" | "El backend deja cada evento en la coleccion `oracle_sync_outbox`; un proceso los aplica y solo los borra cuando Oracle confirma. Si falla, el evento queda pendiente para el siguiente ciclo." |
| "Se puede escribir en Oracle y que se refleje en MongoDB?" | "No. La replica es de solo lectura desde el punto de vista del negocio; cualquier cambio manual se sobrescribe en la proxima carga." |
| "Por que el estado `shipped` en ingles?" | "Los estados vienen del documento MongoDB y el `CHECK` de `MED_PEDIDOS` los valida tal cual: `pending`, `paid`, `processing`, `preparing`, `shipped`, `delivered`." |
| "Que diferencia hay entre tu trigger y el CHECK?" | "El `CHECK` es la ultima linea de defensa con mensaje tecnico; el trigger entrega el mensaje de negocio y se ejecuta antes, con acceso a `:NEW` y `:OLD`." |
| "Por que no usaste una tabla para la lista de pedidos?" | "Porque el requisito era un VARRAY: una coleccion acotada, ordenada y en memoria, que viaja como un solo parametro." |
| "Como garantizas que el JSON llego completo?" | "El script compara el stock de MongoDB con el `SELECT` en Oracle y falla con codigo de salida distinto de cero si no coinciden." |

---

## 7. Plan B: errores comunes y que hacer

| Sintoma | Causa | Solucion |
|---|---|---|
| `ORA-00942: la tabla o vista no existe` | Te conectaste a `XEPDB1` en vez del contenedor raiz | Usar `localhost:1521/XE` |
| `ORA-01017: usuario/contrasena no valida` | Clave incorrecta o usuario mal escrito | Usuario exacto `C##MEDISTOCK` (con los dos `#`) |
| `ORA-12541: no hay ningun listener` | Falta el listener | `net start OracleOraDB21Home1TNSListener` |
| `ORA-12514: el servicio no esta registrado` | El motor esta caido | `net start OracleServiceXE` |
| `ORA-00955: el nombre ya lo usa un objeto existente` | Se intento crear el tipo dos veces | Ignorar: la PARTE 0 ya lo detecta y no vuelve a crearlo |
| El script de Node dice `Falta ORACLE_PASSWORD` | No hay `.env` ni variable de entorno | `cp .env.example .env` y completar la clave |
| `ECONNREFUSED 127.0.0.1:27017` | MongoDB detenido | `net start "MongoDB"` |
| Las tablas `MED_*` aparecen vacias de repente | El backend se reinicio y recargo la replica desde MongoDB | Volver a ejecutar `@evaluacion_medistock.sql` (es idempotente) |
| Un bloque PL/SQL no se ejecuta completo | Se uso "Run Statement" (Ctrl+Enter) en vez de "Run Script" | Ejecutar todo el archivo con F5 (o `/` en SQL*Plus) |

**Regla de oro para la presentacion:** mientras se demuestra, **no arrancar el backend** (`npm run dev`). Al iniciar, borra las tablas de replica y las recarga desde MongoDB; eso elimina los datos de prueba y los pedidos quedarian sin `shipped`.

---

## 8. Anexo: comandos sueltos utiles durante la presentacion

```sql
-- Ver los productos de la replica con su valor de linea
SELECT ID_PRODUCTO, SKU, NOMBRE, PRECIO, STOCK, PRECIO * STOCK AS VALOR
  FROM MED_PRODUCTOS ORDER BY ID_PRODUCTO;

-- Ver el stock bajo (misma regla que el reporte del RECORD)
SELECT SKU, NOMBRE, STOCK, STOCK_MINIMO
  FROM MED_PRODUCTOS WHERE STOCK <= STOCK_MINIMO ORDER BY STOCK;

-- Ver el historial que escribe el trigger de auditoria
SELECT ID_PRODUCTO, SKU, STOCK_ANTERIOR, STOCK_NUEVO, TIPO_CAMBIO, FECHA_CAMBIO
  FROM MED_HISTORIAL_STOCK ORDER BY ID_CAMBIO DESC;

-- Probar el trigger a mano (debe fallar con ORA-20003)
UPDATE MED_PRODUCTOS SET STOCK = -1 WHERE SKU = 'GAS-001';

-- Probar la excepcion de precio a mano (debe fallar con ORA-20010)
BEGIN
  MEDISTOCK_GESTION.REGISTRAR_PRODUCTO('x-1','X-1','Prueba','Prueba',-100,'Insumos',1,1,'img');
END;
/

-- Llamar el paquete completo
BEGIN
  DBMS_OUTPUT.PUT_LINE('Valor: ' || MEDISTOCK_GESTION.VALOR_INVENTARIO);
  MEDISTOCK_GESTION.LISTAR_STOCK_BAJO;
  MEDISTOCK_GESTION.MOSTRAR_PEDIDOS_POR_CATEGORIA('Equipamiento');
END;
/
```

**Comandos de terminal**

```bash
# Estado de los servicios
net start | grep -i -E "mongo|oracle"

# Reinstalar dependencias si se copia la carpeta a otro equipo
cd /c/Users/pazMa/Downloads/Medistock_Oracle/evaluacion_plsql
npm install

# Demostracion
node demo_conexion.js

# Ver la salida completa del PL/SQL guardada como referencia
less salida_esperada_sqlplus.txt
```

> Nota: el ultimo contador de `salida_esperada_sqlplus.txt` (`CAMBIOS_REGISTRADOS_POR_EL_TRIGGER`) crece con cada ejecucion del script, porque el trigger de auditoria agrega filas reales al historial. Es el unico valor que cambia entre corridas.
