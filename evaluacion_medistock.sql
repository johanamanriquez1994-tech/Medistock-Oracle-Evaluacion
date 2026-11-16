-- =====================================================================================
-- PROYECTO MEDISTOCK - EVALUACION DE TALLER DE BASE DE DATOS
-- Archivo: evaluacion_medistock.sql
-- Motor: Oracle Database 21c Express Edition (esquema C##MEDISTOCK, servicio XE)
-- Uso: abrir en Oracle SQL Developer y ejecutar TODO el archivo con "Run Script" (F5).
--      No usar "Run Statement" (Ctrl+Enter): los bloques PL/SQL necesitan el separador "/".
--      En DBeaver (Alt+X) las lineas SET/COLUMN son comandos de SQL*Plus y se ignoran:
--      no afectan al resultado, solo al formato de la salida.
-- Requisito: las tablas MED_* y el paquete MEDISTOCK_SINCRONIZACION ya existen en el esquema.
-- Contenido:
--   PARTE 0  Preparacion de la sesion y del tipo VARRAY
--   PARTE 1  Datos de prueba idempotentes (se pueden volver a ejecutar sin duplicar)
--   PARTE 2  Bloque anonimo con RECORD: productos con stock bajo
--   PARTE 3  Funcion almacenada: valor total del inventario
--   PARTE 4  Procedimiento almacenado con VARRAY: marcar pedidos como 'shipped'
--   PARTE 5  Bloque con cursor explicito parametrizado y loops anidados
--   PARTE 6  Procedimiento con excepcion definida por el usuario: precio negativo
--   PARTE 7  Trigger BEFORE INSERT/UPDATE: stock no negativo
--   PARTE 8  Paquete MEDISTOCK_GESTION (agrupa todo lo anterior)
--   PARTE 9  Pruebas finales de aceptacion
-- =====================================================================================

-- PARTE 0: PREPARACION DE LA SESION
-------------------------------------------------------------------------------------
-- Activa la salida de DBMS_OUTPUT con buffer amplio.
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
-- Desactiva la sustitucion de variables con "&" dentro de los textos.
SET DEFINE OFF
-- Amplia el ancho de linea para que las tablas se lean completas.
SET LINESIZE 200
-- Evita cortes de pagina cada 14 filas en las consultas de control.
SET PAGESIZE 100
-- Da ancho fijo a las columnas de texto para que las tablas finales se lean ordenadas.
COLUMN ID_PRODUCTO FORMAT A22
COLUMN SKU FORMAT A10
COLUMN NOMBRE FORMAT A34
COLUMN ID_PEDIDO FORMAT A10

-- El tipo VARRAY de nivel de esquema es indispensable: un parametro de un procedimiento
-- almacenado NO puede declararse con un tipo definido dentro de otro bloque PL/SQL.
-- Se crea de forma idempotente para que el archivo se pueda ejecutar varias veces.
DECLARE -- Bloque anonimo que solo crea el tipo si aun no existe.
  V_EXISTE NUMBER; -- Guarda cuantas filas devuelve el diccionario de datos.
BEGIN -- Inicia la verificacion.
  SELECT COUNT(*) INTO V_EXISTE -- Cuenta los tipos de usuario con ese nombre.
    FROM USER_TYPES -- Vista del diccionario con los tipos del esquema actual.
   WHERE TYPE_NAME = 'T_IDS_PEDIDO'; -- Nombre del VARRAY que necesitamos.
  IF V_EXISTE = 0 THEN -- Solo crea el tipo cuando no existe.
    EXECUTE IMMEDIATE 'CREATE TYPE T_IDS_PEDIDO AS VARRAY(100) OF VARCHAR2(100)'; -- Crea el VARRAY de hasta 100 IDs.
    DBMS_OUTPUT.PUT_LINE('Tipo T_IDS_PEDIDO creado.'); -- Informa la creacion.
  ELSE -- Si el tipo ya existe, no se toca.
    DBMS_OUTPUT.PUT_LINE('Tipo T_IDS_PEDIDO ya existia: no se vuelve a crear.'); -- Informa que se reutiliza.
  END IF; -- Fin de la decision.
END; -- Fin del bloque de creacion del tipo.
/

-- PARTE 1: DATOS DE PRUEBA (idempotentes)
-------------------------------------------------------------------------------------
-- MERGE inserta los datos la primera vez y los deja en su estado inicial en cada
-- nueva ejecucion. Asi las demostraciones siempre producen el mismo resultado.
MERGE INTO MED_PRODUCTOS T -- T es la fila destino de la replica Oracle.
USING ( -- S es el conjunto de productos de prueba que queremos garantizar.
  SELECT 'demo-product-1' ID_PRODUCTO, 'MSK-001' SKU, -- Producto que tambien existe en MongoDB.
         'Mascarilla Quirurgica C/3' NOMBRE, -- Nombre comercial del producto.
         'Caja de mascarillas quirurgicas desechables de triple capa.' DESCRIPCION, -- Descripcion sincronizada.
         5490 PRECIO, 'Insumos' CATEGORIA, -- Precio unitario y categoria del producto.
         50 STOCK, 10 STOCK_MINIMO, -- Existencias actuales y umbral de alerta.
         'https://example.com/mascarilla.jpg' IMAGEN -- URL de la imagen del producto.
    FROM DUAL -- DUAL permite construir una fila sin consultar una tabla.
  UNION ALL -- Une el segundo producto de prueba.
  SELECT 'prod-guantes-01', 'GUA-001', 'Guantes de Nitrilo M (caja 100)', -- Identificadores y nombre.
         'Caja con 100 guantes de nitrilo sin polvo, talla M.', -- Descripcion del producto.
         8990, 'Insumos', 4, 20, -- Precio, categoria, stock bajo (4) y minimo 20.
         'https://example.com/guantes.jpg' -- Imagen del producto.
    FROM DUAL -- Fila construida sobre DUAL.
  UNION ALL -- Une el tercer producto de prueba.
  SELECT 'prod-alcohol-01', 'ALG-001', 'Alcohol Gel 500 ml', -- Identificadores y nombre.
         'Alcohol gel desinfectante de manos de 500 ml.', -- Descripcion del producto.
         3490, 'Insumos', 8, 10, -- Precio, categoria, stock bajo (8) y minimo 10.
         'https://example.com/alcohol.jpg' -- Imagen del producto.
    FROM DUAL -- Fila construida sobre DUAL.
  UNION ALL -- Une el cuarto producto de prueba.
  SELECT 'prod-gasas-01', 'GAS-001', 'Gasa Esteril 10x10 (sobre)', -- Identificadores y nombre.
         'Sobre de gasa esteril de 10x10 cm para curaciones.', -- Descripcion del producto.
         990, 'Insumos', 300, 50, -- Precio, categoria y stock suficiente (300 sobre 50).
         'https://example.com/gasas.jpg' -- Imagen del producto.
    FROM DUAL -- Fila construida sobre DUAL.
  UNION ALL -- Une el quinto producto de prueba.
  SELECT 'prod-oximetro-01', 'OXI-001', 'Oximetro de Pulso', -- Identificadores y nombre.
         'Oximetro digital de pulso con pantalla OLED.', -- Descripcion del producto.
         24990, 'Equipamiento', 6, 5, -- Precio, categoria y stock sobre el minimo.
         'https://example.com/oximetro.jpg' -- Imagen del producto.
    FROM DUAL -- Fila construida sobre DUAL.
) S ON (T.ID_PRODUCTO = S.ID_PRODUCTO) -- El ID decide si el producto ya estaba cargado.
WHEN MATCHED THEN UPDATE SET -- Si existe, se restaura a su estado de demostracion.
  T.SKU = S.SKU, T.NOMBRE = S.NOMBRE, T.DESCRIPCION = S.DESCRIPCION, -- Atributos descriptivos.
  T.PRECIO = S.PRECIO, T.CATEGORIA = S.CATEGORIA, -- Atributos comerciales.
  T.STOCK = S.STOCK, T.STOCK_MINIMO = S.STOCK_MINIMO, T.IMAGEN = S.IMAGEN -- Existencias e imagen.
WHEN NOT MATCHED THEN INSERT -- Si no existe, se crea el producto de prueba.
  (ID_PRODUCTO, SKU, NOMBRE, DESCRIPCION, PRECIO, CATEGORIA, STOCK, STOCK_MINIMO, IMAGEN) -- Columnas destino.
-- Los valores salen del conjunto fuente S: el ";" debe cerrar la linea (regla de SQL*Plus).
VALUES
  (S.ID_PRODUCTO, S.SKU, S.NOMBRE, S.DESCRIPCION, S.PRECIO, S.CATEGORIA, S.STOCK, S.STOCK_MINIMO, S.IMAGEN);

-- Pedidos de prueba: el MERGE devuelve el estado a 'pending' en cada ejecucion.
MERGE INTO MED_PEDIDOS T -- T es la fila destino del pedido.
USING ( -- S contiene los pedidos de demostracion.
  SELECT 'PED-1001' ID_PEDIDO, 'customer-001' ID_CLIENTE, 'pending' ESTADO, -- Clave, cliente y estado.
         14470 TOTAL, 'B2C' TIPO_PEDIDO -- Total del pedido y tipo de cliente.
    FROM DUAL -- Fila construida sobre DUAL.
  UNION ALL -- Une el segundo pedido.
  SELECT 'PED-1002', 'customer-002', 'paid', 36870, 'B2B' -- Pedido mayorista pagado.
    FROM DUAL -- Fila construida sobre DUAL.
  UNION ALL -- Une el tercer pedido.
  SELECT 'PED-1003', 'customer-001', 'pending', 29940, 'B2C' -- Segundo pedido del cliente 001.
    FROM DUAL -- Fila construida sobre DUAL.
) S ON (T.ID_PEDIDO = S.ID_PEDIDO) -- El ID identifica el pedido.
WHEN MATCHED THEN UPDATE SET -- Si el pedido ya existe, se reajusta para la demo.
  T.ID_CLIENTE = S.ID_CLIENTE, T.ESTADO = S.ESTADO, T.TOTAL = S.TOTAL, -- Datos principales del pedido.
  T.TIPO_PEDIDO = S.TIPO_PEDIDO, T.MEDIO_PAGO = NULL, T.ID_TRANSACCION = NULL, T.FECHA_PAGO = NULL -- Se limpian metadatos.
WHEN NOT MATCHED THEN INSERT -- Si no existe, se inserta el pedido.
  (ID_PEDIDO, ID_CLIENTE, ESTADO, TOTAL, TIPO_PEDIDO, MEDIO_PAGO, ID_TRANSACCION, FECHA_PAGO) -- Columnas destino.
-- Los metadatos de pago quedan nulos en los pedidos de prueba.
VALUES
  (S.ID_PEDIDO, S.ID_CLIENTE, S.ESTADO, S.TOTAL, S.TIPO_PEDIDO, NULL, NULL, NULL);

-- Lineas de detalle: son las que permiten demostrar los cursores anidados.
MERGE INTO MED_DETALLE_PEDIDOS T -- T es la linea destino.
USING ( -- S son las lineas de los pedidos de prueba.
  SELECT 'PED-1001' ID_PEDIDO, 1 NUMERO_LINEA, 'demo-product-1' ID_PRODUCTO, 2 CANTIDAD, 5490 PRECIO_UNITARIO FROM DUAL -- Dos mascarillas.
  UNION ALL SELECT 'PED-1001', 2, 'prod-alcohol-01', 1, 3490 FROM DUAL -- Un alcohol gel.
  UNION ALL SELECT 'PED-1002', 1, 'prod-guantes-01', 3, 8990 FROM DUAL -- Tres cajas de guantes.
  UNION ALL SELECT 'PED-1002', 2, 'prod-gasas-01', 10, 990 FROM DUAL -- Diez sobres de gasa.
  UNION ALL SELECT 'PED-1003', 1, 'prod-oximetro-01', 1, 24990 FROM DUAL -- Un oximetro.
  UNION ALL SELECT 'PED-1003', 2, 'prod-gasas-01', 5, 990 FROM DUAL -- Cinco sobres de gasa.
) S ON (T.ID_PEDIDO = S.ID_PEDIDO AND T.NUMERO_LINEA = S.NUMERO_LINEA) -- La clave es pedido + numero de linea.
WHEN MATCHED THEN UPDATE SET -- Si la linea existe, se ajustan cantidad y precio.
  T.ID_PRODUCTO = S.ID_PRODUCTO, T.CANTIDAD = S.CANTIDAD, T.PRECIO_UNITARIO = S.PRECIO_UNITARIO -- Atributos de la linea.
WHEN NOT MATCHED THEN INSERT -- Si la linea no existe, se agrega.
  (ID_PEDIDO, NUMERO_LINEA, ID_PRODUCTO, CANTIDAD, PRECIO_UNITARIO) -- Columnas destino.
-- Cada linea se inserta con la clave compuesta pedido + numero de linea.
VALUES
  (S.ID_PEDIDO, S.NUMERO_LINEA, S.ID_PRODUCTO, S.CANTIDAD, S.PRECIO_UNITARIO);

-- Confirma los datos de prueba para que las demostraciones los vean.
COMMIT;

-- PARTE 2: BLOQUE ANONIMO CON RECORD -> PRODUCTOS CON STOCK BAJO
-------------------------------------------------------------------------------------
DECLARE -- Inicia el bloque anonimo: no queda guardado en la base de datos.
  TYPE T_PRODUCTO_CRITICO IS RECORD ( -- Define un RECORD: una fila con campos propios de distintos tipos.
    ID_PRODUCTO  MED_PRODUCTOS.ID_PRODUCTO%TYPE, -- Campo que hereda el tipo de la columna ID_PRODUCTO.
    SKU          MED_PRODUCTOS.SKU%TYPE, -- Campo para el codigo de inventario.
    NOMBRE       MED_PRODUCTOS.NOMBRE%TYPE, -- Campo para el nombre comercial.
    CATEGORIA    MED_PRODUCTOS.CATEGORIA%TYPE, -- Campo para la categoria del producto.
    STOCK        MED_PRODUCTOS.STOCK%TYPE, -- Campo con las existencias actuales.
    STOCK_MINIMO MED_PRODUCTOS.STOCK_MINIMO%TYPE, -- Campo con el umbral minimo configurado.
    FALTANTE     NUMBER -- Campo calculado: unidades que faltan para llegar al minimo.
  );
  V_PRODUCTO T_PRODUCTO_CRITICO; -- Variable (instancia) del RECORD anterior.
  V_TOTAL_FALTANTE NUMBER := 0; -- Acumulador de unidades faltantes del inventario.
  V_CANTIDAD       NUMBER := 0; -- Contador de productos criticos encontrados.
  CURSOR C_STOCK_BAJO IS -- Cursor explicito que trae los productos bajo el minimo.
    SELECT ID_PRODUCTO, SKU, NOMBRE, CATEGORIA, STOCK, STOCK_MINIMO -- Columnas que alimentan el RECORD.
      FROM MED_PRODUCTOS -- Tabla de productos de la replica Oracle.
     WHERE STOCK <= STOCK_MINIMO -- Condicion de stock bajo: existencias bajo o igual al minimo.
     ORDER BY (STOCK_MINIMO - STOCK) DESC, NOMBRE; -- Prioriza el faltante mas grande y ordena por nombre.
BEGIN -- Inicia la logica del bloque.
  DBMS_OUTPUT.PUT_LINE('=== PRODUCTOS CON STOCK BAJO (RECORD + cursor) ==='); -- Titulo del reporte.
  DBMS_OUTPUT.PUT_LINE(RPAD('SKU', 12) || RPAD('PRODUCTO', 34) || RPAD('CATEGORIA', 16) || 'STOCK / MIN'); -- Encabezado.
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 80, '-')); -- Linea separadora.
  OPEN C_STOCK_BAJO; -- Abre el cursor: reserva los recursos y fija el resultado.
  LOOP -- Recorre el resultado fila por fila.
    FETCH C_STOCK_BAJO INTO V_PRODUCTO.ID_PRODUCTO, V_PRODUCTO.SKU, V_PRODUCTO.NOMBRE, -- Carga las columnas basicas.
                             V_PRODUCTO.CATEGORIA, V_PRODUCTO.STOCK, V_PRODUCTO.STOCK_MINIMO; -- Carga stock y minimo en el RECORD.
    EXIT WHEN C_STOCK_BAJO%NOTFOUND; -- Sale del loop cuando no quedan filas.
    V_PRODUCTO.FALTANTE := V_PRODUCTO.STOCK_MINIMO - V_PRODUCTO.STOCK; -- Calcula el faltante del producto leido.
    V_TOTAL_FALTANTE := V_TOTAL_FALTANTE + V_PRODUCTO.FALTANTE; -- Acumula el faltante al total.
    V_CANTIDAD := V_CANTIDAD + 1; -- Cuenta un producto critico mas.
    DBMS_OUTPUT.PUT_LINE( -- Imprime una linea del reporte.
      RPAD(V_PRODUCTO.SKU, 12) || -- Codigo del producto alineado a la izquierda.
      RPAD(V_PRODUCTO.NOMBRE, 34) || -- Nombre del producto.
      RPAD(V_PRODUCTO.CATEGORIA, 16) || -- Categoria del producto.
      V_PRODUCTO.STOCK || ' / ' || V_PRODUCTO.STOCK_MINIMO || -- Existencias contra el minimo.
      '  (faltan ' || V_PRODUCTO.FALTANTE || ')' -- Faltante calculado en el RECORD.
    );
  END LOOP; -- Fin del recorrido del cursor.
  CLOSE C_STOCK_BAJO; -- Cierra el cursor y libera los recursos.
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 80, '-')); -- Cierra la tabla con una linea separadora.
  DBMS_OUTPUT.PUT_LINE('Productos criticos: ' || V_CANTIDAD || ' | Unidades faltantes: ' || V_TOTAL_FALTANTE); -- Resumen final.
END; -- Fin del bloque anonimo del RECORD.
/

-- PARTE 3: FUNCION ALMACENADA -> VALOR TOTAL DEL INVENTARIO
-------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION FN_VALOR_INVENTARIO RETURN NUMBER -- La funcion recibe nada y devuelve un numero.
IS -- Inicia la seccion declarativa.
  V_VALOR NUMBER(38, 2) := 0; -- Variable que almacena el valor total calculado.
BEGIN -- Inicia el cuerpo de la funcion.
  SELECT NVL(SUM(PRECIO * STOCK), 0) -- Suma precio por existencias y evita el nulo con NVL.
    INTO V_VALOR -- Guarda el resultado en la variable.
    FROM MED_PRODUCTOS; -- Recorre todos los productos del inventario.
  RETURN V_VALOR; -- Devuelve el valor total a quien invoque la funcion.
END FN_VALOR_INVENTARIO; -- Fin de la funcion.
/

-- Prueba directa de la funcion desde SQL.
SELECT FN_VALOR_INVENTARIO AS VALOR_TOTAL_INVENTARIO FROM DUAL;

-- PARTE 4: PROCEDIMIENTO ALMACENADO CON VARRAY -> PEDIDOS A 'shipped'
-------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE PR_MARCAR_PEDIDOS_ENVIADOS ( -- Procedimiento que recibe una lista de pedidos.
  P_IDS_PEDIDO    IN  T_IDS_PEDIDO, -- VARRAY de hasta 100 IDs de pedido (es el parametro destacado).
  P_ACTUALIZADOS  OUT NUMBER, -- Devuelve cuantos pedidos cambiaron realmente de estado.
  P_NO_ENCONTRADOS OUT NUMBER -- Devuelve cuantos IDs no existian en la tabla.
) IS -- Inicia la seccion declarativa.
  V_EXISTE NUMBER; -- Variable que cuenta coincidencias para cada ID recibido.
BEGIN -- Inicia el cuerpo del procedimiento.
  P_ACTUALIZADOS := 0; -- Inicializa el contador de pedidos actualizados.
  P_NO_ENCONTRADOS := 0; -- Inicializa el contador de IDs inexistentes.
  IF P_IDS_PEDIDO IS NULL OR P_IDS_PEDIDO.COUNT = 0 THEN -- Valida que la coleccion traiga elementos.
    RAISE_APPLICATION_ERROR(-20020, 'El VARRAY de pedidos no puede venir vacio'); -- Rechaza listas vacias.
  END IF; -- Fin de la validacion de la coleccion.
  FOR I IN 1 .. P_IDS_PEDIDO.COUNT LOOP -- Recorre el VARRAY por indice: 1, 2, 3 ... COUNT.
    UPDATE MED_PEDIDOS -- Tabla de pedidos que se va a modificar.
       SET ESTADO = 'shipped' -- Nuevo estado solicitado por la evaluacion.
     WHERE ID_PEDIDO = P_IDS_PEDIDO(I) -- Usa el elemento I del VARRAY como filtro.
       AND ESTADO <> 'shipped'; -- Evita contar dos veces un pedido ya enviado.
    IF SQL%ROWCOUNT > 0 THEN -- SQL%ROWCOUNT indica cuantas filas afecto el UPDATE.
      P_ACTUALIZADOS := P_ACTUALIZADOS + 1; -- Suma un pedido actualizado.
      DBMS_OUTPUT.PUT_LINE('  Pedido ' || P_IDS_PEDIDO(I) || ' -> shipped'); -- Traza del cambio aplicado.
    ELSE -- Si no se actualizo ninguna fila, el pedido no existe o ya estaba enviado.
      SELECT COUNT(*) INTO V_EXISTE FROM MED_PEDIDOS WHERE ID_PEDIDO = P_IDS_PEDIDO(I); -- Verifica si el pedido existe.
      IF V_EXISTE = 0 THEN -- Caso: el ID no existe en la tabla.
        P_NO_ENCONTRADOS := P_NO_ENCONTRADOS + 1; -- Suma un ID inexistente.
        DBMS_OUTPUT.PUT_LINE('  Pedido ' || P_IDS_PEDIDO(I) || ' -> no existe, se omite'); -- Informa el ID omitido.
      ELSE -- Caso: el pedido existe pero ya estaba en 'shipped'.
        DBMS_OUTPUT.PUT_LINE('  Pedido ' || P_IDS_PEDIDO(I) || ' -> ya estaba shipped'); -- Informa que no habia cambio.
      END IF; -- Fin de la verificacion de existencia.
    END IF; -- Fin del control de filas afectadas.
  END LOOP; -- Fin del recorrido del VARRAY.
  COMMIT; -- Confirma los cambios de todo el lote.
END PR_MARCAR_PEDIDOS_ENVIADOS; -- Fin del procedimiento.
/

DECLARE -- Bloque anonimo que prueba el procedimiento con un VARRAY literal.
  V_PEDIDOS T_IDS_PEDIDO := T_IDS_PEDIDO('PED-1001', 'PED-1003', 'PED-9999'); -- Lista de 3 IDs: dos reales y uno inexistente.
  V_OK      NUMBER; -- Recibe la cantidad de pedidos actualizados.
  V_FALTAN  NUMBER; -- Recibe la cantidad de IDs inexistentes.
BEGIN -- Inicia la prueba del procedimiento.
  DBMS_OUTPUT.PUT_LINE('=== MARCAR PEDIDOS COMO ENVIADOS (VARRAY de ' || V_PEDIDOS.COUNT || ' IDs) ==='); -- Titulo de la prueba.
  PR_MARCAR_PEDIDOS_ENVIADOS(V_PEDIDOS, V_OK, V_FALTAN); -- Invoca el procedimiento con el VARRAY.
  DBMS_OUTPUT.PUT_LINE('Actualizados: ' || V_OK || ' | No encontrados: ' || V_FALTAN); -- Muestra el resumen devuelto.
END; -- Fin de la prueba.
/

-- PARTE 5: CURSOR EXPLICITO PARAMETRIZADO CON LOOPS ANIDADOS
-------------------------------------------------------------------------------------
DECLARE -- Bloque anonimo con dos cursores: uno externo por categoria y uno interno por producto.
  V_CATEGORIA MED_PRODUCTOS.CATEGORIA%TYPE := 'Insumos'; -- Categoria que se analizara (cambiala para otra demo).
  CURSOR C_PRODUCTOS (P_CATEGORIA MED_PRODUCTOS.CATEGORIA%TYPE) IS -- Cursor externo: recibe la categoria como parametro.
    SELECT ID_PRODUCTO, SKU, NOMBRE, STOCK -- Datos que se mostraran del producto.
      FROM MED_PRODUCTOS -- Tabla de productos filtrada por categoria.
     WHERE CATEGORIA = P_CATEGORIA -- Usa el parametro del cursor, no una variable global.
     ORDER BY NOMBRE; -- Orden estable para la presentacion.
  CURSOR C_PEDIDOS_PRODUCTO (P_ID_PRODUCTO MED_PRODUCTOS.ID_PRODUCTO%TYPE) IS -- Cursor interno: recibe el ID del producto.
    SELECT P.ID_PEDIDO, P.ESTADO, P.TOTAL, D.NUMERO_LINEA, D.CANTIDAD, D.PRECIO_UNITARIO -- Datos del pedido y su linea.
      FROM MED_PEDIDOS P -- Encabezado del pedido.
      JOIN MED_DETALLE_PEDIDOS D ON D.ID_PEDIDO = P.ID_PEDIDO -- Une el encabezado con su detalle.
     WHERE D.ID_PRODUCTO = P_ID_PRODUCTO -- Filtra las lineas del producto recibido.
     ORDER BY P.ID_PEDIDO, D.NUMERO_LINEA; -- Orden por pedido y numero de linea.
  V_PEDIDOS_PRODUCTO NUMBER; -- Cuenta los pedidos encontrados para cada producto.
BEGIN -- Inicia el procesamiento anidado.
  DBMS_OUTPUT.PUT_LINE('=== PEDIDOS ASOCIADOS A LA CATEGORIA: ' || V_CATEGORIA || ' ==='); -- Titulo del reporte.
  FOR V_PRODUCTO IN C_PRODUCTOS(V_CATEGORIA) LOOP -- Loop externo: una iteracion por producto de la categoria.
    DBMS_OUTPUT.PUT_LINE('[PRODUCTO] ' || V_PRODUCTO.SKU || ' - ' || V_PRODUCTO.NOMBRE || -- Presenta el producto actual.
                         ' | stock: ' || V_PRODUCTO.STOCK); -- Muestra sus existencias.
    V_PEDIDOS_PRODUCTO := 0; -- Reinicia el contador para el producto actual.
    FOR V_PEDIDO IN C_PEDIDOS_PRODUCTO(V_PRODUCTO.ID_PRODUCTO) LOOP -- Loop interno: pedidos de ESE producto.
      V_PEDIDOS_PRODUCTO := V_PEDIDOS_PRODUCTO + 1; -- Cuenta un pedido mas para el producto actual.
      DBMS_OUTPUT.PUT_LINE('   Pedido ' || V_PEDIDO.ID_PEDIDO || -- Identificador del pedido encontrado.
                           ' | estado: ' || V_PEDIDO.ESTADO || -- Estado actual del pedido.
                           ' | linea ' || V_PEDIDO.NUMERO_LINEA || -- Numero de linea dentro del pedido.
                           ' | cantidad: ' || V_PEDIDO.CANTIDAD || -- Unidades pedidas del producto.
                           ' | precio: ' || V_PEDIDO.PRECIO_UNITARIO); -- Precio unitario aplicado.
    END LOOP; -- Fin del loop interno de pedidos.
    IF V_PEDIDOS_PRODUCTO = 0 THEN -- Controla los productos sin pedidos asociados.
      DBMS_OUTPUT.PUT_LINE('   (sin pedidos asociados)'); -- Informa que ese producto no tiene pedidos.
    END IF; -- Fin del control de productos sin pedidos.
  END LOOP; -- Fin del loop externo de productos.
END; -- Fin del bloque de cursores anidados.
/

-- PARTE 6: PROCEDIMIENTO CON EXCEPCION DEFINIDA POR EL USUARIO -> PRECIO NEGATIVO
-------------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE PR_REGISTRAR_PRODUCTO ( -- Procedimiento que inserta un producto con validaciones.
  P_ID_PRODUCTO IN MED_PRODUCTOS.ID_PRODUCTO%TYPE, -- Identificador unico del producto.
  P_SKU         IN MED_PRODUCTOS.SKU%TYPE, -- Codigo de inventario unico.
  P_NOMBRE      IN MED_PRODUCTOS.NOMBRE%TYPE, -- Nombre comercial del producto.
  P_DESCRIPCION IN MED_PRODUCTOS.DESCRIPCION%TYPE, -- Descripcion larga del producto.
  P_PRECIO      IN NUMBER, -- Precio unitario que se debe validar.
  P_CATEGORIA   IN MED_PRODUCTOS.CATEGORIA%TYPE, -- Categoria del producto.
  P_STOCK       IN NUMBER, -- Existencias iniciales.
  P_STOCK_MINIMO IN NUMBER, -- Umbral de alerta de stock.
  P_IMAGEN      IN MED_PRODUCTOS.IMAGEN%TYPE -- URL de la imagen.
) IS -- Inicia la seccion declarativa.
  E_PRECIO_NEGATIVO EXCEPTION; -- Excepcion definida por el usuario para precios invalidos.
BEGIN -- Inicia el cuerpo del procedimiento.
  IF P_PRECIO IS NULL THEN -- Un precio nulo tampoco es un dato valido.
    RAISE E_PRECIO_NEGATIVO; -- Reutiliza la excepcion de precio invalido.
  END IF; -- Fin del control de nulo.
  IF P_PRECIO < 0 THEN -- Regla de negocio: el precio nunca puede ser negativo.
    RAISE E_PRECIO_NEGATIVO; -- Lanza explicitamente la excepcion definida por el usuario.
  END IF; -- Fin del control de precio negativo.
  INSERT INTO MED_PRODUCTOS ( -- Inserta el producto cuando pasa las validaciones.
    ID_PRODUCTO, SKU, NOMBRE, DESCRIPCION, PRECIO, CATEGORIA, STOCK, STOCK_MINIMO, IMAGEN -- Columnas destino.
  ) VALUES (
    P_ID_PRODUCTO, P_SKU, P_NOMBRE, P_DESCRIPCION, P_PRECIO, P_CATEGORIA, -- Parametros de identificacion y precio.
    P_STOCK, P_STOCK_MINIMO, P_IMAGEN -- Parametros de inventario e imagen.
  );
  COMMIT; -- Confirma la insercion del producto valido.
  DBMS_OUTPUT.PUT_LINE('Producto ' || P_ID_PRODUCTO || ' registrado correctamente.'); -- Confirma la operacion.
EXCEPTION -- Inicia el manejador de errores del procedimiento.
  WHEN E_PRECIO_NEGATIVO THEN -- Atrapa la excepcion definida por el usuario.
    RAISE_APPLICATION_ERROR(-20010, -- Codigo de error de aplicacion propio de Medistock.
      'Precio invalido para ' || P_SKU || ': ' || P_PRECIO || '. El precio debe ser mayor o igual a cero.'); -- Mensaje entendible.
  WHEN DUP_VAL_ON_INDEX THEN -- Atrapa la violacion de las claves unicas (id o sku).
    RAISE_APPLICATION_ERROR(-20011, 'Ya existe un producto con el id o el SKU indicado: ' || P_SKU); -- Informa el duplicado.
END PR_REGISTRAR_PRODUCTO; -- Fin del procedimiento.
/

DECLARE -- Bloque anonimo que demuestra los dos caminos del procedimiento.
  V_ID VARCHAR2(100) := 'prod-demostracion-01'; -- ID del producto que se intentara insertar.
BEGIN -- Inicia la demostracion.
  DBMS_OUTPUT.PUT_LINE('=== VALIDACION DE PRECIO (excepcion definida por el usuario) ==='); -- Titulo de la demo.
  BEGIN -- Sub-bloque para el caso invalido, asi el error no corta el script.
    PR_REGISTRAR_PRODUCTO(V_ID, 'DEM-001', 'Producto con precio negativo', -- Datos del producto invalido.
      'Prueba de validacion de precio.', -1500, 'Insumos', 10, 5, -- Precio negativo a proposito.
      'https://example.com/demo.jpg'); -- Imagen de prueba.
  EXCEPTION -- Captura el error lanzado por el procedimiento.
    WHEN OTHERS THEN -- Cualquier error de aplicacion se informa sin abortar la demo.
      DBMS_OUTPUT.PUT_LINE('  Rechazado  -> ORA' || SQLCODE || ': ' || SQLERRM); -- Muestra el mensaje de rechazo.
  END; -- Fin del sub-bloque del caso invalido.
  BEGIN -- Sub-bloque para el caso valido.
    DELETE FROM MED_PRODUCTOS WHERE ID_PRODUCTO = V_ID; -- Limpia una ejecucion anterior del mismo ID.
    PR_REGISTRAR_PRODUCTO(V_ID, 'DEM-001', 'Producto de demostracion', -- Datos del producto valido.
      'Producto creado durante la evaluacion.', 2990, 'Demostracion', 12, 5, -- Categoria propia para no mezclarlo con los reportes.
      'https://example.com/demo.jpg'); -- Imagen de prueba.
  EXCEPTION -- Captura cualquier error inesperado del caso valido.
    WHEN OTHERS THEN -- Informa sin abortar la demo.
      DBMS_OUTPUT.PUT_LINE('  Error -> ' || SQLERRM); -- Muestra el error del caso valido.
  END; -- Fin del sub-bloque del caso valido.
END; -- Fin de la demostracion de precio.
/

-- PARTE 7: TRIGGER BEFORE INSERT/UPDATE -> EL STOCK NO PUEDE SER NEGATIVO
-------------------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER MED_PRODUCTOS_STOCK_VALIDA_TRG -- Nombre del trigger de validacion.
BEFORE INSERT OR UPDATE OF STOCK ON MED_PRODUCTOS -- Se dispara antes de insertar o de cambiar el stock.
FOR EACH ROW -- Se ejecuta una vez por cada fila afectada.
BEGIN -- Inicia el cuerpo del trigger.
  IF :NEW.STOCK < 0 THEN -- Valida el valor nuevo que intenta entrar en la tabla.
    RAISE_APPLICATION_ERROR(-20003, -- Codigo de error propio de la validacion de stock.
      'Stock invalido (' || :NEW.STOCK || ') para el producto ' || :NEW.SKU || -- Detalla el valor recibido y el producto.
      '. El stock no puede ser negativo.'); -- Explica la regla de negocio.
  END IF; -- Fin de la validacion de stock.
END MED_PRODUCTOS_STOCK_VALIDA_TRG; -- Fin del trigger.
/

DECLARE -- Bloque anonimo que comprueba que el trigger realmente bloquea el dato invalido.
BEGIN -- Inicia la prueba del trigger.
  DBMS_OUTPUT.PUT_LINE('=== VALIDACION DE STOCK EN EL TRIGGER ==='); -- Titulo de la prueba.
  BEGIN -- Sub-bloque del caso invalido.
    UPDATE MED_PRODUCTOS SET STOCK = -5 WHERE ID_PRODUCTO = 'prod-gasas-01'; -- Intenta dejar el stock negativo.
    DBMS_OUTPUT.PUT_LINE('  ERROR DE LA DEMO: el stock negativo fue aceptado.'); -- Solo aparece si el trigger falla.
  EXCEPTION -- Captura el error del trigger.
    WHEN OTHERS THEN -- El trigger debe impedir la actualizacion.
      DBMS_OUTPUT.PUT_LINE('  Bloqueado  -> ORA' || SQLCODE || ': ' || SQLERRM); -- Muestra el rechazo del trigger.
  END; -- Fin del sub-bloque invalido.
  BEGIN -- Sub-bloque del caso valido.
    UPDATE MED_PRODUCTOS SET STOCK = STOCK WHERE ID_PRODUCTO = 'prod-gasas-01'; -- Actualiza un stock valido (300).
    DBMS_OUTPUT.PUT_LINE('  Stock valido aceptado para prod-gasas-01.'); -- Confirma que el trigger no bloquea lo correcto.
  END; -- Fin del sub-bloque valido.
END; -- Fin de la prueba del trigger.
/

-- PARTE 8: PAQUETE MEDISTOCK_GESTION (agrupa funcion, procedimientos y reportes)
-------------------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE MEDISTOCK_GESTION AS -- Especificacion: es el contrato publico del paquete.
  FUNCTION VALOR_INVENTARIO RETURN NUMBER; -- Expone el calculo del valor total del inventario.
  FUNCTION PRODUCTOS_BAJO_MINIMO RETURN NUMBER; -- Devuelve cuantos productos estan bajo el minimo.
  PROCEDURE MARCAR_PEDIDOS_ENVIADOS ( -- Expone el proceso masivo con VARRAY.
    P_IDS_PEDIDO     IN  T_IDS_PEDIDO, -- Lista de IDs de pedidos a marcar.
    P_ACTUALIZADOS   OUT NUMBER, -- Cantidad de pedidos efectivamente actualizados.
    P_NO_ENCONTRADOS OUT NUMBER -- Cantidad de IDs que no existen.
  );
  PROCEDURE REGISTRAR_PRODUCTO ( -- Expone el alta de producto con validacion de precio.
    P_ID_PRODUCTO  IN MED_PRODUCTOS.ID_PRODUCTO%TYPE, -- Identificador del producto.
    P_SKU          IN MED_PRODUCTOS.SKU%TYPE, -- Codigo de inventario.
    P_NOMBRE       IN MED_PRODUCTOS.NOMBRE%TYPE, -- Nombre comercial.
    P_DESCRIPCION  IN MED_PRODUCTOS.DESCRIPCION%TYPE, -- Descripcion del producto.
    P_PRECIO       IN NUMBER, -- Precio unitario validado.
    P_CATEGORIA    IN MED_PRODUCTOS.CATEGORIA%TYPE, -- Categoria del producto.
    P_STOCK        IN NUMBER, -- Existencias iniciales.
    P_STOCK_MINIMO IN NUMBER, -- Umbral de alerta.
    P_IMAGEN       IN MED_PRODUCTOS.IMAGEN%TYPE -- Imagen del producto.
  );
  PROCEDURE LISTAR_STOCK_BAJO; -- Reporte de productos bajo el minimo usando RECORD y cursor.
  PROCEDURE MOSTRAR_PEDIDOS_POR_CATEGORIA ( -- Reporte con cursor parametrizado y loops anidados.
    P_CATEGORIA IN MED_PRODUCTOS.CATEGORIA%TYPE DEFAULT 'Insumos' -- Categoria a analizar, con valor por defecto.
  );
END MEDISTOCK_GESTION; -- Fin de la especificacion del paquete.
/

CREATE OR REPLACE PACKAGE BODY MEDISTOCK_GESTION AS -- Cuerpo: implementa todo lo declarado arriba.

  FUNCTION VALOR_INVENTARIO RETURN NUMBER IS -- Implementa el valor total del inventario.
  BEGIN -- Inicia la funcion del paquete.
    RETURN FN_VALOR_INVENTARIO; -- Reutiliza la funcion almacenada ya existente: no duplica la logica.
  END VALOR_INVENTARIO; -- Fin de la funcion del paquete.

  FUNCTION PRODUCTOS_BAJO_MINIMO RETURN NUMBER IS -- Cuenta los productos criticos del inventario.
    V_TOTAL NUMBER; -- Almacena el conteo.
  BEGIN -- Inicia el conteo.
    SELECT COUNT(*) INTO V_TOTAL -- Cuenta los productos con stock bajo.
      FROM MED_PRODUCTOS -- Tabla de productos de la replica.
     WHERE STOCK <= STOCK_MINIMO; -- Misma regla de negocio que usan los reportes.
    RETURN V_TOTAL; -- Devuelve el conteo al invocador.
  END PRODUCTOS_BAJO_MINIMO; -- Fin del conteo.

  PROCEDURE MARCAR_PEDIDOS_ENVIADOS ( -- Delega el proceso masivo en el procedimiento almacenado.
    P_IDS_PEDIDO     IN  T_IDS_PEDIDO, -- VARRAY recibido desde el llamador.
    P_ACTUALIZADOS   OUT NUMBER, -- Resultado: pedidos actualizados.
    P_NO_ENCONTRADOS OUT NUMBER -- Resultado: IDs inexistentes.
  ) IS -- Inicia la seccion declarativa.
  BEGIN -- Inicia el cuerpo del procedimiento del paquete.
    PR_MARCAR_PEDIDOS_ENVIADOS(P_IDS_PEDIDO, P_ACTUALIZADOS, P_NO_ENCONTRADOS); -- Reutiliza la logica ya validada.
  END MARCAR_PEDIDOS_ENVIADOS; -- Fin del procedimiento del paquete.

  PROCEDURE REGISTRAR_PRODUCTO ( -- Delega el alta de producto en el procedimiento almacenado.
    P_ID_PRODUCTO  IN MED_PRODUCTOS.ID_PRODUCTO%TYPE, -- Identificador del producto.
    P_SKU          IN MED_PRODUCTOS.SKU%TYPE, -- Codigo de inventario.
    P_NOMBRE       IN MED_PRODUCTOS.NOMBRE%TYPE, -- Nombre comercial.
    P_DESCRIPCION  IN MED_PRODUCTOS.DESCRIPCION%TYPE, -- Descripcion del producto.
    P_PRECIO       IN NUMBER, -- Precio unitario validado.
    P_CATEGORIA    IN MED_PRODUCTOS.CATEGORIA%TYPE, -- Categoria del producto.
    P_STOCK        IN NUMBER, -- Existencias iniciales.
    P_STOCK_MINIMO IN NUMBER, -- Umbral de alerta.
    P_IMAGEN       IN MED_PRODUCTOS.IMAGEN%TYPE -- Imagen del producto.
  ) IS -- Inicia la seccion declarativa.
  BEGIN -- Inicia el cuerpo del procedimiento del paquete.
    PR_REGISTRAR_PRODUCTO(P_ID_PRODUCTO, P_SKU, P_NOMBRE, P_DESCRIPCION, -- Reutiliza las validaciones existentes.
                           P_PRECIO, P_CATEGORIA, P_STOCK, P_STOCK_MINIMO, P_IMAGEN); -- Continua con los datos de inventario.
  END REGISTRAR_PRODUCTO; -- Fin del procedimiento del paquete.

  PROCEDURE LISTAR_STOCK_BAJO IS -- Reporte de productos criticos dentro del paquete.
    TYPE T_PRODUCTO_CRITICO IS RECORD ( -- RECORD local del paquete: estructura de una fila del reporte.
      ID_PRODUCTO  MED_PRODUCTOS.ID_PRODUCTO%TYPE, -- Campo con el ID del producto.
      SKU          MED_PRODUCTOS.SKU%TYPE, -- Campo con el codigo de inventario.
      NOMBRE       MED_PRODUCTOS.NOMBRE%TYPE, -- Campo con el nombre del producto.
      STOCK        MED_PRODUCTOS.STOCK%TYPE, -- Campo con las existencias.
      STOCK_MINIMO MED_PRODUCTOS.STOCK_MINIMO%TYPE, -- Campo con el umbral minimo.
      FALTANTE     NUMBER -- Campo calculado con las unidades faltantes.
    );
    V_PRODUCTO T_PRODUCTO_CRITICO; -- Variable del RECORD para cada fila leida.
    V_FALTANTE_TOTAL NUMBER := 0; -- Acumula las unidades faltantes del inventario.
    CURSOR C_STOCK_BAJO IS -- Cursor explicito de productos bajo el minimo.
      SELECT ID_PRODUCTO, SKU, NOMBRE, STOCK, STOCK_MINIMO -- Columnas que alimentan el RECORD.
        FROM MED_PRODUCTOS -- Tabla de productos.
       WHERE STOCK <= STOCK_MINIMO -- Regla de stock bajo.
       ORDER BY (STOCK_MINIMO - STOCK) DESC, NOMBRE; -- Ordena por gravedad del faltante.
  BEGIN -- Inicia el reporte.
    DBMS_OUTPUT.PUT_LINE('=== MEDISTOCK_GESTION.LISTAR_STOCK_BAJO ==='); -- Titulo del reporte.
    OPEN C_STOCK_BAJO; -- Abre el cursor.
    LOOP -- Recorre el resultado.
      FETCH C_STOCK_BAJO INTO V_PRODUCTO.ID_PRODUCTO, V_PRODUCTO.SKU, -- Carga el ID y el SKU en el RECORD.
                              V_PRODUCTO.NOMBRE, V_PRODUCTO.STOCK, -- Carga el nombre y las existencias.
                              V_PRODUCTO.STOCK_MINIMO; -- Carga el minimo (FALTANTE se calcula despues).
      EXIT WHEN C_STOCK_BAJO%NOTFOUND; -- Sale cuando no hay mas filas.
      V_PRODUCTO.FALTANTE := V_PRODUCTO.STOCK_MINIMO - V_PRODUCTO.STOCK; -- Calcula el faltante.
      V_FALTANTE_TOTAL := V_FALTANTE_TOTAL + V_PRODUCTO.FALTANTE; -- Acumula el faltante.
      DBMS_OUTPUT.PUT_LINE('  ' || V_PRODUCTO.SKU || ' | ' || V_PRODUCTO.NOMBRE || -- Identifica el producto.
                           ' | stock: ' || V_PRODUCTO.STOCK || ' | minimo: ' || V_PRODUCTO.STOCK_MINIMO || -- Muestra niveles.
                           ' | faltan: ' || V_PRODUCTO.FALTANTE); -- Muestra el faltante calculado.
    END LOOP; -- Fin del recorrido.
    CLOSE C_STOCK_BAJO; -- Cierra el cursor.
    DBMS_OUTPUT.PUT_LINE('  Unidades faltantes totales: ' || V_FALTANTE_TOTAL); -- Resumen del reporte.
  END LISTAR_STOCK_BAJO; -- Fin del reporte de stock bajo.

  PROCEDURE MOSTRAR_PEDIDOS_POR_CATEGORIA ( -- Reporte anidado de pedidos por categoria.
    P_CATEGORIA IN MED_PRODUCTOS.CATEGORIA%TYPE DEFAULT 'Insumos' -- Categoria recibida con valor por defecto.
  ) IS -- Inicia la seccion declarativa.
    CURSOR C_PRODUCTOS (P_CAT MED_PRODUCTOS.CATEGORIA%TYPE) IS -- Cursor externo parametrizado por categoria.
      SELECT ID_PRODUCTO, SKU, NOMBRE, STOCK -- Datos del producto.
        FROM MED_PRODUCTOS -- Tabla de productos.
       WHERE CATEGORIA = P_CAT -- Filtra por el parametro del cursor.
       ORDER BY NOMBRE; -- Orden alfabetico.
    CURSOR C_PEDIDOS_PRODUCTO (P_ID_PRODUCTO MED_PRODUCTOS.ID_PRODUCTO%TYPE) IS -- Cursor interno parametrizado por producto.
      SELECT P.ID_PEDIDO, P.ESTADO, D.NUMERO_LINEA, D.CANTIDAD, D.PRECIO_UNITARIO -- Datos del pedido y su linea.
        FROM MED_PEDIDOS P -- Encabezado del pedido.
        JOIN MED_DETALLE_PEDIDOS D ON D.ID_PEDIDO = P.ID_PEDIDO -- Une con el detalle del pedido.
       WHERE D.ID_PRODUCTO = P_ID_PRODUCTO -- Filtra por el producto del loop externo.
       ORDER BY P.ID_PEDIDO, D.NUMERO_LINEA; -- Orden por pedido y linea.
  BEGIN -- Inicia el reporte anidado.
    DBMS_OUTPUT.PUT_LINE('=== MEDISTOCK_GESTION.MOSTRAR_PEDIDOS_POR_CATEGORIA(''' || P_CATEGORIA || ''') ==='); -- Titulo.
    FOR V_PRODUCTO IN C_PRODUCTOS(P_CATEGORIA) LOOP -- Loop externo por producto de la categoria.
      DBMS_OUTPUT.PUT_LINE('  Producto: ' || V_PRODUCTO.SKU || ' - ' || V_PRODUCTO.NOMBRE); -- Encabezado del producto.
      FOR V_PEDIDO IN C_PEDIDOS_PRODUCTO(V_PRODUCTO.ID_PRODUCTO) LOOP -- Loop interno por pedido del producto.
        DBMS_OUTPUT.PUT_LINE('    Pedido ' || V_PEDIDO.ID_PEDIDO || ' (' || V_PEDIDO.ESTADO || -- Pedido y estado.
                             ') linea ' || V_PEDIDO.NUMERO_LINEA || ' x ' || V_PEDIDO.CANTIDAD); -- Linea y cantidad.
      END LOOP; -- Fin del loop interno.
    END LOOP; -- Fin del loop externo.
  END MOSTRAR_PEDIDOS_POR_CATEGORIA; -- Fin del reporte anidado.

END MEDISTOCK_GESTION; -- Fin del cuerpo del paquete.
/

-- PARTE 9: PRUEBAS FINALES DE ACEPTACION
-------------------------------------------------------------------------------------
DECLARE -- Bloque anonimo que recorre el contrato del paquete de punta a punta.
  V_PEDIDOS T_IDS_PEDIDO := T_IDS_PEDIDO('PED-1001', 'PED-1002'); -- VARRAY con dos pedidos vigentes.
  V_OK      NUMBER; -- Resultado: pedidos actualizados.
  V_FALTAN  NUMBER; -- Resultado: IDs inexistentes.
BEGIN -- Inicia la prueba integral.
  DBMS_OUTPUT.PUT_LINE('=== PRUEBA INTEGRAL MEDISTOCK_GESTION ==='); -- Titulo de la prueba.
  DBMS_OUTPUT.PUT_LINE('Valor total inventario : ' || TO_CHAR(MEDISTOCK_GESTION.VALOR_INVENTARIO, 'FM999G999G999G999G990D00')); -- Funcion del paquete.
  DBMS_OUTPUT.PUT_LINE('Productos bajo minimo   : ' || MEDISTOCK_GESTION.PRODUCTOS_BAJO_MINIMO); -- Conteo del paquete.
  MEDISTOCK_GESTION.LISTAR_STOCK_BAJO; -- Reporte de stock bajo del paquete.
  MEDISTOCK_GESTION.MARCAR_PEDIDOS_ENVIADOS(V_PEDIDOS, V_OK, V_FALTAN); -- Proceso masivo con VARRAY.
  DBMS_OUTPUT.PUT_LINE('Pedidos actualizados    : ' || V_OK || ' | no encontrados: ' || V_FALTAN); -- Resultado del proceso.
  MEDISTOCK_GESTION.MOSTRAR_PEDIDOS_POR_CATEGORIA('Insumos'); -- Reporte anidado por categoria.
END; -- Fin de la prueba integral.
/

-- Consulta de control del estado final de los pedidos.
SELECT ID_PEDIDO, ESTADO, TOTAL -- Columnas del reporte de control.
  FROM MED_PEDIDOS -- Tabla de pedidos.
 ORDER BY ID_PEDIDO;

-- Consulta de control del inventario y del calculo por producto.
SELECT ID_PRODUCTO, SKU, NOMBRE, PRECIO, STOCK, -- Datos base del producto.
       PRECIO * STOCK AS VALOR_LINEA -- Calculo por producto para comparar con la funcion.
  FROM MED_PRODUCTOS -- Tabla de productos.
 ORDER BY ID_PRODUCTO;

-- Comprueba que el trigger de auditoria siguio registrando los cambios de stock.
SELECT COUNT(*) AS CAMBIOS_REGISTRADOS_POR_EL_TRIGGER -- Total de filas historicas.
  FROM MED_HISTORIAL_STOCK;

-- Fin de evaluacion_medistock.sql
