// Consulta de solo lectura: lista los objetos PL/SQL del usuario actual.
// Se ejecuta con: node _consulta_objetos.js
import oracledb from 'oracledb';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const AQUI = dirname(fileURLToPath(import.meta.url));

try {
  const texto = readFileSync(join(AQUI, '.env'), 'utf8');
  for (const linea of texto.split(/\r?\n/)) {
    const limpia = linea.trim();
    if (!limpia || limpia.startsWith('#')) continue;
    const corte = limpia.indexOf('=');
    if (corte < 1) continue;
    const clave = limpia.slice(0, corte).trim();
    const valor = limpia.slice(corte + 1).trim().replace(/^["']|["']$/g, '');
    if (process.env[clave] === undefined) process.env[clave] = valor;
  }
} catch { /* sin .env */ }

const cfg = {
  user: process.env.ORACLE_USER || 'C##MEDISTOCK',
  password: process.env.ORACLE_PASSWORD || '',
  connectString: process.env.ORACLE_CONNECT_STRING || 'localhost:1521/XE',
};

const SQL = `SELECT OBJECT_NAME, OBJECT_TYPE, STATUS, TO_CHAR(LAST_DDL_TIME,'YYYY-MM-DD HH24:MI') AS ULTIMO_DDL
               FROM USER_OBJECTS
              WHERE OBJECT_TYPE IN ('PACKAGE','PACKAGE BODY','PROCEDURE','FUNCTION','TRIGGER')
              ORDER BY DECODE(OBJECT_TYPE,'PACKAGE',1,'PACKAGE BODY',2,'PROCEDURE',3,'FUNCTION',4,'TRIGGER',5), OBJECT_NAME`;

const conn = await oracledb.getConnection(cfg);
oracledb.outFormat = oracledb.OUT_FORMAT_OBJECT;
const sesion = await conn.execute(
  `SELECT USER AS USUARIO, SYS_CONTEXT('USERENV','CON_NAME') AS CONTENEDOR, SYS_CONTEXT('USERENV','DB_NAME') AS BD FROM DUAL`);
const s = sesion.rows[0];
console.log(`Sesion      : ${s.USUARIO} @ ${s.CONTENEDOR} (${s.BD})`);

const res = await conn.execute(SQL);
const filas = res.rows;

const tipos = ['PACKAGE', 'PACKAGE BODY', 'PROCEDURE', 'FUNCTION', 'TRIGGER'];
const anchoTipo = 16, anchoNombre = 34;
console.log('');
console.log('TIPO'.padEnd(anchoTipo) + 'OBJETO'.padEnd(anchoNombre) + 'ESTADO'.padEnd(10) + 'ULTIMO DDL');
console.log('-'.repeat(anchoTipo + anchoNombre + 10 + 16));
let tipoActual = null;
for (const f of filas) {
  if (f.OBJECT_TYPE !== tipoActual) {
    tipoActual = f.OBJECT_TYPE;
    const n = filas.filter((x) => x.OBJECT_TYPE === tipoActual).length;
    console.log(`[${tipoActual} - ${n}]`);
  }
  console.log(
    String(f.OBJECT_TYPE).padEnd(anchoTipo) +
    String(f.OBJECT_NAME).padEnd(anchoNombre) +
    String(f.STATUS).padEnd(10) +
    (f.ULTIMO_DDL ?? ''),
  );
}
console.log('-'.repeat(anchoTipo + anchoNombre + 10 + 16));
console.log('TOTAL OBJETOS PL/SQL: ' + filas.length);
console.log('');
for (const t of tipos) {
  const n = filas.filter((f) => f.OBJECT_TYPE === t).length;
  const invalidos = filas.filter((f) => f.OBJECT_TYPE === t && f.STATUS !== 'VALID').length;
  console.log(`  ${t.padEnd(14)} ${String(n).padStart(3)}   invalidos: ${invalidos}`);
}

await conn.close();
