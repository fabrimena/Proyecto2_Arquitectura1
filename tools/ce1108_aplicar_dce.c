/* Adaptador del DCE público del IDE CE1108, sin reimplementar la optimización.
 * Se enlaza externamente con los mismos fuentes que tests/test_ide_dce. Recibe
 * un BAL y un destino NUEVO; ide_dce_analizar produce codigo_nuevo y el backend
 * normal lo compilará después. No escribe dentro de CE1108 ni cambia sus fases.
 * La salida JSON acredita si hubo transformación; una copia idéntica no se
 * admite como otro nivel por el comparador. Errores de IO/análisis retornan 1,
 * argumentos inválidos 64; nunca se publica código si el análisis no está LISTO.
 */
#include "ide_dce.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc != 3) return 64;
    FILE *in = fopen(argv[1], "rb");
    if (!in) return 1;
    /* Límite explícito de un MiB: leer un prefijo no equivale a transformar
     * todo el programa. El byte adicional detecta exceso sin truncar fuente. */
    const size_t limit = 1024u * 1024u;
    char *text = malloc(limit + 1);
    if (!text) { fclose(in); return 1; }
    size_t length = fread(text, 1, limit + 1, in);
    int bad = ferror(in) || length > limit;
    if (fclose(in)) bad = 1;
    if (bad || memchr(text, '\0', length)) { free(text); return 1; }
    text[length] = '\0';
    IdeDce result = {0};
    int rc = 1;
    /* La API del IDE crea un temporal junto a la ruta que recibe. Se usa la
     * ruta de SALIDA externa, nunca la fuente del repositorio de Compiladores.
     * El manifiesto actual solo acredita programas autónomos, sin bring local. */
    if (ide_dce_analizar(text, length, argv[2], &result) != 0 ||
        result.estado != IDE_DCE_LISTO) goto done;
    const char *code = result.codigo_nuevo ? result.codigo_nuevo : text;
    /* wx impide sobrescribir una captura anterior. El llamador acredita que el
     * destino está fuera de ambos repositorios antes de ejecutar este binario. */
    FILE *out = fopen(argv[2], "wx");
    if (!out) goto done;
    size_t size = result.codigo_nuevo ? strlen(code) : length;
    bad = fwrite(code, 1, size, out) != size;
    if (fclose(out)) bad = 1;
    if (bad) goto done;
    printf("{\"producer\":\"ide_dce_analizar\",\"changed\":%s,"
           "\"deleted\":%zu,\"rewritten\":%zu,\"bundles_before\":%zu,\"bundles_after\":%zu}\n",
           result.codigo_nuevo ? "true" : "false", result.sentencias_borradas,
           result.sentencias_cambiadas, result.bundles_antes, result.bundles_despues);
    rc = fflush(stdout) ? 1 : 0;
done:
    /* La API entrega propiedad de sus textos; todas las rutas de salida tras
     * analizar liberan el resultado, incluido el caso de código sin cambios. */
    ide_dce_liberar(&result);
    free(text);
    return rc;
}
