/* Captura independiente de la sesión pública M2 al horizonte declarado.
 * No certifica terminación de main: conserva pipeline activo y publica todos
 * los GPR, estado criptográfico público y los 65536 bytes de DMEM. */
#include "sim_ejecucion.h"
#include <errno.h>
#include <inttypes.h>
#include <stdlib.h>

int main(int argc,char **argv)
{
    /* El presupuesto es decimal estricto; un signo no se interpreta como un
     * entero unsigned enorme. La herramienta solo escribe el destino explícito. */
    if(argc!=4||!*argv[2])return 64;
    for(const char *p=argv[2];*p;p++)if(*p<'0'||*p>'9')return 64;
    errno=0;char *end;uintmax_t n=strtoumax(argv[2],&end,10);
    if(errno||*end||n>100000)return 64;
    SimEjecucion *s=NULL;SimMetricasResumen r;uint8_t memory[65536];int rc=1;
    if(sim_ejecucion_crear(argv[1],SIM_EJECUCION_MEM,SIM_BUSQUEDA_FISICA,&s,stderr)!=SIM_EJECUCION_OK)return 1;
    /* LIMITE es una pausa administrativa: no fuerza HALT, reset o drenado. Las
     * métricas y arquitectura corresponden exactamente a los flancos ejecutados. */
    if(sim_ejecucion_ejecutar(s,(uint64_t)n)!=SIM_EJECUCION_OK||
       sim_ejecucion_resultados(s,&r)!=SIM_METRICAS_OK||
       sim_ejecucion_memoria(s,memory,sizeof memory)!=SIM_EJECUCION_OK)goto done;
    FILE *f=fopen(argv[3],"wbx");if(!f)goto done;
    int ok=fwrite(memory,1,sizeof memory,f)==sizeof memory;
    if(fclose(f))ok=0;
    if(!ok)goto done;
    printf("{\"registers\":[");
    for(unsigned k=0;k<32;k++)printf("%s%" PRIu32,k?",":"",r.registros[k]);
    printf("],\"crypto\":%" PRIu32 ",\"traps\":%" PRIu32 ",\"cycles\":%" PRIu64 "}\n",
           r.estado_crypto,r.trap_count32,r.ciclos);
    rc=fflush(stdout)?1:0;
done:
    /* Todas las rutas posteriores a crear la sesión liberan imagen, CPU y M1;
     * el archivo independiente ya pertenece al llamador y no se elimina. */
    sim_ejecucion_liberar(&s);return rc;
}
