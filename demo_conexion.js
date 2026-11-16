#!/usr/bin/env node
/* =====================================================================================
 * PROYECTO MEDISTOCK - DEMOSTRACION DE CONEXION MONGODB -> ORACLE
 * Archivo: demo_conexion.js
 * Ejecutar: node demo_conexion.js
 * Requiere: npm install mongodb oracledb   (ya incluido en package.json de esta carpeta)
 *
 * Que demuestra este script (en este orden, con salida en pantalla de cada paso):
 *   PASO 1  Conexion a MongoDB y lectura de la coleccion "products".
 *   PASO 2  Busqueda del producto de demostracion; si no existe se inserta,
 *           si existe se actualiza su stock (asi se ven los dos caminos del UPSERT).
 *   PASO 3  Conexion a Oracle como C##MEDISTOCK y estado previo de MED_PRODUCTOS.
 *   PASO 4  Invocacion de MEDISTOCK_SINCRONIZACION.APLICAR_CAMBIO('products','UPSERT', json)
 *           pasando el documento de MongoDB serializado como JSON (CLOB).
 *   PASO 5  SELECT en Oracle para comprobar que el producto ya esta en MED_PRODUCTOS.
 *   PASO 6  Verificacion final: el stock de Oracle coincide con el de MongoDB.
 *
 * Credenciales: se leen de variables de entorno o de un archivo .env en esta carpeta.
 *   ORACLE_USER            (por defecto C##MEDISTOCK)
 *   ORACLE_PASSWORD        (obligatoria, no se escribe en el codigo)
 *   ORACLE_CONNECT_STRING  (por defecto localhost:1521/XE)
 *   MONGODB_URI            (por defecto mongodb://localhost:27017)
 *   MONGODB_DB             (por defecto medistock)
 * ===================================================================================== */

import { MongoClient } from 'mongodb'; // Driver oficial de MongoDB para Node.js.
import oracledb from 'oracledb'; // Driver oficial de Oracle para Node.js (modo Thin).
import { readFileSync } from 'node:fs'; // Se usa para leer el archivo .env opcional.
import { fileURLToPath } from 'node:url'; // Convierte la URL del modulo en una ruta de archivo.
import { dirname, join } from 'node:path'; // Construye rutas portables dentro de la carpeta.

const AQUI = dirname(fileURLToPath(import.meta.url)); // Carpeta donde vive este script.

/* -------------------------------------------------------------------------------------
 * 0. Configuracion: .env opcional -> variables de entorno -> valores por defecto.
 * ----------------------------------------------------------------------------------- */
function cargarEnv(ruta) {
  // Lee el .env si existe; si no existe simplemente se ignoran las variables de entorno.
  try {
    const texto = readFileSync(ruta, 'utf8'); // Contenido completo del archivo .env.
    for (const linea of texto.split(/\r?\n/)) { // Recorre el archivo linea por linea.
      const limpia = linea.trim(); // Quita espacios sobrantes.
      if (!limpia || limpia.startsWith('#')) continue; // Ignora lineas vacias y comentarios.
      const corte = limpia.indexOf('='); // Busca el separador clave=valor.
      if (corte < 1) continue; // Ignora lineas sin formato valido.
      const clave = limpia.slice(0, corte).trim(); // Nombre de la variable.
      const valor = limpia.slice(corte + 1).trim().replace(/^["']|["']$/g, ''); // Valor sin comillas.
      if (process.env[clave] === undefined) process.env[clave] = valor; // El entorno real tiene prioridad.
    }
  } catch { /* Sin .env: se usan las variables de entorno o los valores por defecto. */ }
}

cargarEnv(join(AQUI, '.env')); // Carga la configuracion local si el alumno crea el archivo.

const CONFIG = {
  mongoUri: process.env.MONGODB_URI || 'mongodb://localhost:27017', // Servicio local de MongoDB.
  mongoDb: process.env.MONGODB_DB || 'medistock', // Base de datos principal del proyecto.
  oracleUser: process.env.ORACLE_USER || 'C##MEDISTOCK', // Usuario dueno del esquema Oracle.
  oraclePassword: process.env.ORACLE_PASSWORD || '', // Contrasena: nunca se escribe en el codigo.
  oracleConnect: process.env.ORACLE_CONNECT_STRING || 'localhost:1521/XE', // Servicio XE (contenedor raiz).
};

// Producto fijo de la demostracion: el mismo identificador existe en MongoDB y en Oracle.
const PRODUCTO_ID = 'demo-sync-01'; // Clave de negocio usada por el paquete de sincronizacion.
const PRODUCTO_SKU = 'SYNC-DEMO-01'; // SKU unico para poder buscar el documento en MongoDB.

/* -------------------------------------------------------------------------------------
 * Utilidades de presentacion en consola.
 * ----------------------------------------------------------------------------------- */
const linea = (caracter = '-') => console.log(caracter.repeat(94)); // Separador visual.
const paso = (n, titulo) => { console.log(''); linea('='); console.log(`PASO ${n}: ${titulo}`); linea('='); }; // Titulo de paso.
const dato = (etiqueta, valor) => console.log(`  ${etiqueta.padEnd(26)}${valor}`); // Fila etiqueta/valor alineada.
const tiempo = (ms) => `${ms.toFixed(0)} ms`; // Formatea una duracion en milisegundos.
const ahora = () => Number(process.hrtime.bigint() / 1000000n); // Marca de tiempo simple en ms.

/* -------------------------------------------------------------------------------------
 * Programa principal.
 * ----------------------------------------------------------------------------------- */
let mongo = null; // Cliente de MongoDB a nivel de modulo para poder cerrarlo si algo falla.
let oracle = null; // Conexion de Oracle a nivel de modulo para poder cerrarla si algo falla.

async function main() {
  console.log('DEMOSTRACION DE SINCRONIZACION MONGODB -> ORACLE'); // Cabecera de la demo.
  dato('MongoDB', CONFIG.mongoUri); // Muestra el destino de MongoDB.
  dato('Oracle', `${CONFIG.oracleConnect} (usuario ${CONFIG.oracleUser})`); // Muestra el destino de Oracle.
  console.log('');

  if (!CONFIG.oraclePassword) { // Falla temprano si falta la credencial de Oracle.
    console.error('Falta ORACLE_PASSWORD. Definela en el entorno o en un archivo .env de esta carpeta.'); // Mensaje claro.
    process.exitCode = 1; // Codigo de salida distinto de cero para que el error sea visible.
    return;
  }

  const inicioGlobal = ahora(); // Inicio del cronometro total.

  /* ------------------------------- PASO 1: MONGODB ------------------------------- */
  paso(1, 'Conectar a MongoDB y leer la coleccion products'); // Titulo del paso.
  const mongoCliente = new MongoClient(CONFIG.mongoUri, { serverSelectionTimeoutMS: 5000 }); // Cliente con timeout corto.
  mongo = mongoCliente; // Deja la referencia visible para el manejo de errores.
  await mongoCliente.connect(); // Abre la conexion con el servidor de MongoDB.
  const db = mongoCliente.db(CONFIG.mongoDb); // Selecciona la base de datos del proyecto.
  const coleccion = db.collection('products'); // Coleccion principal de productos.
  const totalMongo = await coleccion.countDocuments(); // Cuenta los documentos existentes.
  dato('Base de datos', CONFIG.mongoDb); // Informa la base usada.
  dato('Documentos en products', totalMongo); // Muestra el total antes de la demo.

  /* --------------------- PASO 2: BUSCAR O INSERTAR EL PRODUCTO ------------------- */
  paso(2, 'Buscar el producto de demostracion (o insertarlo si no existe)'); // Titulo del paso.
  let documento = await coleccion.findOne({ id: PRODUCTO_ID }); // Busca por la clave de negocio.
  let origenMongo; // Guarda si el producto se inserto o solo se actualizo.

  if (documento) { // Rama: el producto ya estaba en MongoDB.
    origenMongo = 'ENCONTRADO'; // Marca el camino seguido.
    const nuevoStock = Number(documento.stock ?? 0) + 10; // Suma 10 unidades para forzar un cambio visible.
    await coleccion.updateOne( // Actualiza el documento existente.
      { id: PRODUCTO_ID }, // Filtro por la clave de negocio.
      { $set: { stock: nuevoStock, updatedAt: new Date().toISOString() } }, // Cambia stock y marca de tiempo.
    );
    documento = await coleccion.findOne({ id: PRODUCTO_ID }); // Relee el documento ya actualizado.
    dato('Resultado', 'producto encontrado y actualizado (+10 stock)'); // Explica la rama tomada.
  } else { // Rama: el producto no existia en MongoDB.
    origenMongo = 'INSERTADO'; // Marca el camino seguido.
    documento = { // Documento nuevo con la misma forma que usa la aplicacion.
      id: PRODUCTO_ID, // Clave de negocio que viaja a Oracle.
      name: 'Termometro Digital Infrarrojo', // Nombre del producto de demostracion.
      sku: PRODUCTO_SKU, // SKU unico.
      description: 'Termometro infrarrojo sin contacto para triage clinico.', // Descripcion.
      price: 19990, // Precio unitario en CLP.
      category: 'Equipamiento', // Categoria del producto.
      stock: 25, // Existencias iniciales.
      minStock: 5, // Umbral minimo de stock.
      image: 'https://example.com/termometro.jpg', // Imagen del producto.
      createdAt: new Date().toISOString(), // Fecha de creacion del documento.
    };
    await coleccion.insertOne({ ...documento }); // Inserta el documento en MongoDB.
    dato('Resultado', 'producto no existia: insertado en MongoDB'); // Explica la rama tomada.
  }

  dato('Origen del documento', origenMongo); // Inserta o actualizado.
  dato('id / sku', `${documento.id} / ${documento.sku}`); // Identificadores sincronizados.
  dato('name', documento.name); // Nombre del producto.
  dato('price / stock / minStock', `${documento.price} / ${documento.stock} / ${documento.minStock}`); // Cifras clave.
  console.log('  Documento JSON que se enviara a Oracle:'); // Aviso del documento serializado.
  const jsonProducto = JSON.stringify({ // Serializa SOLO los campos de negocio.
    id: documento.id, // Identificador que usa JSON_VALUE en el paquete.
    name: documento.name, // Nombre del producto.
    sku: documento.sku, // SKU unico.
    description: documento.description, // Descripcion.
    price: documento.price, // Precio unitario.
    category: documento.category, // Categoria.
    stock: documento.stock, // Existencias.
    minStock: documento.minStock, // Umbral de stock.
    image: documento.image, // Imagen.
  });
  console.log(`  ${jsonProducto}`); // Muestra el JSON exacto que recibe PL/SQL.

  /* -------------------------------- PASO 3: ORACLE ------------------------------- */
  paso(3, 'Conectar a Oracle y revisar el estado previo de MED_PRODUCTOS'); // Titulo del paso.
  oracle = await oracledb.getConnection({ // Abre la conexion con Oracle.
    user: CONFIG.oracleUser, // Usuario dueno del esquema.
    password: CONFIG.oraclePassword, // Contrasena leida de la configuracion.
    connectString: CONFIG.oracleConnect, // Cadena de conexion al listener.
  });
  oracledb.outFormat = oracledb.OUT_FORMAT_OBJECT; // Devuelve las filas como objetos con nombre de columna.

  const version = await oracle.execute('SELECT banner FROM v$version WHERE ROWNUM = 1'); // Version del motor.
  dato('Motor Oracle', version.rows[0].BANNER); // Muestra la version detectada.
  const sesion = await oracle.execute('SELECT USER AS USUARIO, SYS_CONTEXT(\'USERENV\', \'CON_NAME\') AS CONTENEDOR FROM DUAL'); // Usuario y contenedor.
  dato('Sesion', `${sesion.rows[0].USUARIO} @ ${sesion.rows[0].CONTENEDOR}`); // Confirma con quien se conecto.

  const antes = await oracle.execute( // Estado previo del producto en la replica.
    'SELECT COUNT(*) AS TOTAL, MAX(STOCK) AS STOCK, MAX(PRECIO) AS PRECIO FROM MED_PRODUCTOS WHERE ID_PRODUCTO = :id', // Cuenta y datos actuales.
    { id: PRODUCTO_ID }, // Parametro de entrada.
  );
  const filaAntes = antes.rows[0]; // Primera (y unica) fila del agregado.
  const existiaEnOracle = Number(filaAntes.TOTAL) > 0; // Indica si el MERGE hara UPDATE o INSERT.
  dato('Ya existia en Oracle', existiaEnOracle ? `si (stock ${filaAntes.STOCK})` : 'no'); // Estado previo entendible.
  dato('Filas totales en Oracle', (await oracle.execute('SELECT COUNT(*) AS N FROM MED_PRODUCTOS')).rows[0].N); // Conteo global previo.

  /* --------------------- PASO 4: INVOCAR EL PAQUETE PL/SQL ----------------------- */
  paso(4, 'Invocar MEDISTOCK_SINCRONIZACION.APLICAR_CAMBIO desde Node.js'); // Titulo del paso.
  const inicioPlsql = ahora(); // Cronometro de la llamada PL/SQL.
  await oracle.execute( // Ejecuta el procedimiento del paquete.
    `BEGIN MEDISTOCK_SINCRONIZACION.APLICAR_CAMBIO(:p_entidad, :p_accion, :p_datos); END;`, // Bloque PL/SQL con tres binds.
    {
      p_entidad: 'products', // Entidad que genero el evento en MongoDB.
      p_accion: 'UPSERT', // UPSERT inserta o actualiza segun el ID.
      p_datos: jsonProducto, // Documento JSON serializado (se convierte a CLOB).
    },
  );
  const msPlsql = ahora() - inicioPlsql; // Duracion de la llamada PL/SQL.
  await oracle.commit(); // Confirma el MERGE realizado por el paquete.
  dato('Llamada', 'APLICAR_CAMBIO(products, UPSERT, json)'); // Documenta la invocacion.
  dato('Tiempo PL/SQL', tiempo(msPlsql)); // Muestra el tiempo de ejecucion.
  dato('Commit', 'realizado'); // Confirma la transaccion.

  /* ------------------------ PASO 5: SELECT DE COMPROBACION ----------------------- */
  paso(5, 'SELECT en Oracle: el producto ya esta en MED_PRODUCTOS'); // Titulo del paso.
  const despues = await oracle.execute( // Consulta la fila recien sincronizada.
    `SELECT ID_PRODUCTO, SKU, NOMBRE, CATEGORIA, PRECIO, STOCK, STOCK_MINIMO -- Columnas de la replica.
       FROM MED_PRODUCTOS -- Tabla destino del MERGE del paquete.
      WHERE ID_PRODUCTO = :id`, // Filtra el producto sincronizado.
    { id: PRODUCTO_ID }, // Parametro de entrada.
  );
  const fila = despues.rows[0]; // Fila devuelta por Oracle.
  if (!fila) { // Si no aparece, la sincronizacion no funciono.
    throw new Error('El producto no aparece en MED_PRODUCTOS: revise la sincronizacion.'); // Error explicito.
  }
  console.log(''); // Separacion antes de la tabla.
  console.log('  ID_PRODUCTO    SKU           NOMBRE                          CATEGORIA      PRECIO     STOCK'); // Cabecera de la tabla.
  linea('-'); // Linea bajo la cabecera.
  console.log( // Imprime la fila con columnas alineadas.
    `  ${String(fila.ID_PRODUCTO).padEnd(15)}${String(fila.SKU).padEnd(14)}${String(fila.NOMBRE).padEnd(32)}${String(fila.CATEGORIA).padEnd(15)}${String(fila.PRECIO).padStart(7)}${String(fila.STOCK).padStart(8)}`,
  );
  linea('-'); // Cierre de la tabla.

  const totalDespues = await oracle.execute('SELECT COUNT(*) AS N FROM MED_PRODUCTOS'); // Conteo global posterior.
  const productos = await oracle.execute( // Lista completa para mostrar el inventario replicado.
    `SELECT ID_PRODUCTO, SKU, NOMBRE, STOCK FROM MED_PRODUCTOS ORDER BY ID_PRODUCTO`, // Consulta ordenada.
  );
  dato('Filas totales en Oracle', totalDespues.rows[0].N); // Compara antes y despues.
  console.log('  Inventario replicado completo:'); // Aviso de la lista.
  for (const p of productos.rows) { // Recorre cada producto de la replica.
    console.log(`    - ${String(p.ID_PRODUCTO).padEnd(22)}${String(p.SKU).padEnd(14)}${String(p.NOMBRE).padEnd(34)}stock: ${p.STOCK}`); // Una linea por producto.
  }

  /* ------------------------- PASO 6: VERIFICACION FINAL -------------------------- */
  paso(6, 'Verificacion: MongoDB y Oracle tienen el mismo stock'); // Titulo del paso.
  const stockMongo = Number(documento.stock); // Stock vigente en MongoDB.
  const stockOracle = Number(fila.STOCK); // Stock replicado en Oracle.
  dato('stock en MongoDB', stockMongo); // Valor de la fuente principal.
  dato('stock en Oracle', stockOracle); // Valor de la replica.
  dato('precio Oracle', fila.PRECIO); // Precio replicado.
  if (stockMongo === stockOracle) { // Comparacion de los dos valores.
    console.log(''); // Separacion.
    console.log('  RESULTADO: OK - la sincronizacion MongoDB -> Oracle quedo demostrada.'); // Conclusion de la demo.
  } else { // Si los valores difieren, la demo fallo.
    console.log(''); // Separacion.
    console.log(`  RESULTADO: ERROR - los valores no coinciden (${stockMongo} vs ${stockOracle}).`); // Conclusion negativa.
    process.exitCode = 2; // Codigo de salida de error.
  }
  linea('='); // Cierre visual.
  dato('Tiempo total', tiempo(ahora() - inicioGlobal)); // Duracion total de la demostracion.
  linea('='); // Cierre visual.

  await oracle.close(); // Cierra la conexion con Oracle.
  await mongo.close(); // Cierra la conexion con MongoDB.
}

/* -------------------------------------------------------------------------------------
 * Arranque con manejo central de errores: siempre cierra recursos y explica el motivo.
 * ----------------------------------------------------------------------------------- */
function pistasDeError(error) {
  // Traduce el error del driver a instrucciones concretas sobre que corregir.
  const mensaje = String(error && error.message ? error.message : ''); // Texto del error.
  const numero = Number(error && error.errorNum); // Codigo ORA cuando lo entrega oracledb.
  if (numero === 1017 || mensaje.includes('ORA-01017')) { // Credenciales rechazadas por Oracle.
    return [
      'Oracle rechazo el usuario o la contrasena.',
      'ORACLE_USER debe ser el dueno de las tablas MED_*: en este equipo es C##MEDISTOCK, no system.',
      'ORACLE_PASSWORD debe ser la contrasena de ESE usuario (son cuentas distintas).',
    ];
  }
  if (numero === 942 || mensaje.includes('ORA-00942')) { // Objetos no visibles para el usuario.
    return [
      'La tabla MED_* no existe para el usuario con el que te conectaste.',
      'Las tablas y los paquetes pertenecen al esquema C##MEDISTOCK.',
      'Usa ORACLE_USER=C##MEDISTOCK y ORACLE_CONNECT_STRING=localhost:1521/XE (no XEPDB1).',
    ];
  }
  if (numero === 6550 || numero === 6508 || numero === 4063) { // Paquete no ejecutable por ese usuario.
    return [
      'Oracle no puede ejecutar MEDISTOCK_SINCRONIZACION con ese usuario.',
      'El paquete vive en el esquema C##MEDISTOCK: conectate con ese usuario.',
    ];
  }
  if (mensaje.includes('ECONNREFUSED') || mensaje.includes('failed to connect')) { // Servicio apagado.
    return [
      'El motor no esta escuchando en ese puerto.',
      'Oracle: net start OracleServiceXE && net start OracleOraDB21Home1TNSListener',
      'MongoDB: net start "MongoDB"',
    ];
  }
  return []; // Sin pista especifica: se muestra solo el error original.
}

main().catch(async (error) => { // Captura cualquier fallo de la demostracion.
  console.error(''); // Separacion visual.
  console.error('ERROR EN LA DEMOSTRACION:', error.message); // Motivo legible del fallo.
  if (error.code) console.error('Codigo:', error.code); // Codigo de error del driver u Oracle.
  if (error.errorNum) console.error('ORA-' + error.errorNum); // Codigo ORA cuando lo entrega oracledb.
  const pistas = pistasDeError(error); // Instrucciones segun el tipo de fallo.
  if (pistas.length > 0) { // Solo se muestran si hay algo concreto que corregir.
    console.error(''); // Separacion visual.
    console.error('QUE CORREGIR:'); // Encabezado de las pistas.
    for (const p of pistas) console.error('  - ' + p); // Una instruccion por linea.
  }
  try { if (oracle) await oracle.close(); } catch { /* La conexion ya estaba cerrada. */ } // Libera Oracle.
  try { if (mongo) await mongo.close(); } catch { /* La conexion ya estaba cerrada. */ } // Libera MongoDB.
  process.exit(1); // Termina siempre: sin esto Node queda colgado con los sockets abiertos.
});
