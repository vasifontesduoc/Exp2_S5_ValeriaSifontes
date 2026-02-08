----------------------------------
-- SOLUCIONES A LOS CASOS
-- SUMATIVA 2 - VALERIA SIFONTES
----------------------------------

SET SERVEROUTPUT ON;

-- =========================================
-- VARIABLE BIND (SIN FECHAS FIJAS)
-- año del proceso en forma paramétrica
VARIABLE b_anio NUMBER;
EXEC :b_anio := EXTRACT(YEAR FROM SYSDATE);

-- =========================================
-- BLOQUE PRINCIPAL
DECLARE

    -- =====================================
    -- EXCEPCIONES DEFINIDAS POR EL USUARIO
    e_sin_transacciones EXCEPTION;   -- cuando no se procesa ningún registro
    e_aporte_negativo   EXCEPTION;   -- cuando el cálculo da negativo

    -- =====================================
    -- EXCEPCION NO PREDEFINIDA
    e_error_grupo EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_error_grupo, -937);

    -- =====================================
    -- VARRAY DE TIPOS DE TRANSACCION
    TYPE t_varray_tipo IS VARRAY(2) OF VARCHAR2(50);
    v_tipos t_varray_tipo;

    -- =====================================
    -- REGISTRO PARA DETALLE
    TYPE r_detalle IS RECORD(
        numrun              CLIENTE.numrun%TYPE,
        dv                  CLIENTE.dvrun%TYPE,
        nro_tarjeta         TARJETA_CLIENTE.nro_tarjeta%TYPE,
        nro_transaccion     TRANSACCION_TARJETA_CLIENTE.nro_transaccion%TYPE,
        fecha_transaccion   TRANSACCION_TARJETA_CLIENTE.fecha_transaccion%TYPE,
        tipo_transaccion    TIPO_TRANSACCION_TARJETA.nombre_tptran_tarjeta%TYPE,
        monto               TRANSACCION_TARJETA_CLIENTE.monto_total_transaccion%TYPE
    );

    v_detalle r_detalle;

    -- =====================================
    -- CURSOR PRINCIPAL CON PARÁMETRO
    -- obtiene las transacciones del año y tipo
    CURSOR c_transacciones(p_tipo VARCHAR2) IS
        SELECT 
            c.numrun,
            c.dvrun,
            tc.nro_tarjeta,
            ttc.nro_transaccion,
            ttc.fecha_transaccion,
            tt.nombre_tptran_tarjeta,
            ttc.monto_total_transaccion
        FROM cliente c
        JOIN tarjeta_cliente tc 
            ON c.numrun = tc.numrun
        JOIN transaccion_tarjeta_cliente ttc 
            ON tc.nro_tarjeta = ttc.nro_tarjeta
        JOIN tipo_transaccion_tarjeta tt 
            ON ttc.cod_tptran_tarjeta = tt.cod_tptran_tarjeta
        WHERE tt.nombre_tptran_tarjeta = p_tipo
        AND EXTRACT(YEAR FROM ttc.fecha_transaccion) = :b_anio
        ORDER BY ttc.fecha_transaccion, c.numrun;

    -- =====================================
    -- CURSOR DE RESUMEN (SIN PARÁMETRO)
    CURSOR c_resumen IS
        SELECT DISTINCT
            TO_CHAR(fecha_transaccion,'MMYYYY') mes_anno,
            tipo_transaccion
        FROM detalle_aporte_sbif
        ORDER BY 1,2;

    -- =====================================
    -- VARIABLES DE CONTROL
    v_contador      NUMBER := 0;
    v_total_reg     NUMBER := 0;
    v_aporte        NUMBER;
    v_porcentaje    NUMBER;

    -- variables para resumen
    v_mes_anno      VARCHAR2(6);
    v_tipo          VARCHAR2(50);
    v_total_monto   NUMBER;
    v_total_aporte  NUMBER;

BEGIN
    -- =====================================
    -- LIMPIEZA DE TABLAS
    EXECUTE IMMEDIATE 'TRUNCATE TABLE detalle_aporte_sbif';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE resumen_aporte_sbif';

    -- =====================================
    -- CARGA DE VARRAY
    v_tipos := t_varray_tipo('Avance en Efectivo',
                             'S per Avance en Efectivo');

    DBMS_OUTPUT.PUT_LINE('--------------------------------');
    DBMS_OUTPUT.PUT_LINE('INICIO PROCESO SBIF');
    DBMS_OUTPUT.PUT_LINE('AÑO PROCESADO: ' || :b_anio);
    DBMS_OUTPUT.PUT_LINE('--------------------------------');

    -- =====================================
    -- CICLO POR TIPOS DE TRANSACCION
    FOR i IN 1 .. v_tipos.COUNT LOOP
        OPEN c_transacciones(v_tipos(i));

        LOOP
            FETCH c_transacciones INTO
                v_detalle.numrun,
                v_detalle.dv,
                v_detalle.nro_tarjeta,
                v_detalle.nro_transaccion,
                v_detalle.fecha_transaccion,
                v_detalle.tipo_transaccion,
                v_detalle.monto;

            EXIT WHEN c_transacciones%NOTFOUND;

            BEGIN
                -- obtener porcentaje según tramo
                SELECT porc_aporte_sbif
                INTO v_porcentaje
                FROM tramo_aporte_sbif
                WHERE v_detalle.monto 
                      BETWEEN tramo_inf_av_sav 
                          AND tramo_sup_av_sav;

                -- cálculo en PL/SQL
                v_aporte := ROUND(v_detalle.monto * v_porcentaje / 100);

                IF v_aporte < 0 THEN
                    RAISE e_aporte_negativo;
                END IF;

                v_contador := v_contador + 1;

                -- inserción en tabla detalle
                INSERT INTO detalle_aporte_sbif
                VALUES(
                    v_detalle.numrun,
                    v_detalle.dv,
                    v_detalle.nro_tarjeta,
                    v_detalle.nro_transaccion,
                    v_detalle.fecha_transaccion,
                    v_detalle.tipo_transaccion,
                    v_detalle.monto,
                    v_aporte
                );

            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    DBMS_OUTPUT.PUT_LINE(
                        'No existe tramo para monto: ' ||
                        v_detalle.monto
                    );

                WHEN e_aporte_negativo THEN
                    DBMS_OUTPUT.PUT_LINE(
                        'Error: aporte negativo en transacción ' ||
                        v_detalle.nro_transaccion
                    );
            END;

        END LOOP;

        CLOSE c_transacciones;
    END LOOP;

    -- =====================================
    -- VALIDACION DE ITERACIONES
    SELECT COUNT(*)
    INTO v_total_reg
    FROM detalle_aporte_sbif;

    IF v_contador = 0 THEN
        RAISE e_sin_transacciones;
    END IF;

    -- =====================================
    -- GENERACION DE RESUMEN CON CURSOR
    OPEN c_resumen;
    LOOP
        FETCH c_resumen INTO v_mes_anno, v_tipo;
        EXIT WHEN c_resumen%NOTFOUND;

        SELECT 
            SUM(monto_transaccion),
            SUM(aporte_sbif)
        INTO 
            v_total_monto,
            v_total_aporte
        FROM detalle_aporte_sbif
        WHERE TO_CHAR(fecha_transaccion,'MMYYYY') = v_mes_anno
        AND tipo_transaccion = v_tipo;

        INSERT INTO resumen_aporte_sbif
        VALUES(
            v_mes_anno,
            v_tipo,
            v_total_monto,
            v_total_aporte
        );

    END LOOP;
    CLOSE c_resumen;

    -- =====================================
    -- COMMIT SOLO SI ITERACIONES COINCIDEN
    IF v_contador = v_total_reg THEN
        COMMIT;
    ELSE
        ROLLBACK;
    END IF;

    DBMS_OUTPUT.PUT_LINE('--------------------------------');
    DBMS_OUTPUT.PUT_LINE('PROCESO FINALIZADO');
    DBMS_OUTPUT.PUT_LINE('TRANSACCIONES PROCESADAS: ' || v_contador);
    DBMS_OUTPUT.PUT_LINE('--------------------------------');

-- =====================================
-- MANEJO DE EXCEPCIONES

EXCEPTION
    WHEN e_sin_transacciones THEN
        DBMS_OUTPUT.PUT_LINE('No existen transacciones para el año.');
        ROLLBACK;

    WHEN e_error_grupo THEN
        DBMS_OUTPUT.PUT_LINE('Error en función de grupo.');
        ROLLBACK;

    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE(
            'Error capturado (' || SQLCODE || ') ' || SQLERRM
        );
        ROLLBACK;
END;
/

-- =============================
-- VERIFICACIÓN FINAL

-- DETALLE ORDENADO
SELECT 
    numrun,
    dvrun,
    TRIM(TO_CHAR(nro_tarjeta, '9999999999999999')) AS nro_tarjeta,
    nro_transaccion,
    fecha_transaccion,
    tipo_transaccion,
    monto_transaccion,
    aporte_sbif
FROM detalle_aporte_sbif
ORDER BY fecha_transaccion, numrun;

-- RESUMEN ORDENADO
SELECT 
    mes_anno,
    tipo_transaccion,
    monto_total_transacciones,
    aporte_total_abif
FROM resumen_aporte_sbif
ORDER BY mes_anno, tipo_transaccion;

