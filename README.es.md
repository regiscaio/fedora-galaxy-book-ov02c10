<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book OV02C10

## Instalación rápida

Para instalar el controlador desde el repositorio público DNF:

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-ov02c10
```

Como herramientas complementarias de diagnóstico y userspace para el Galaxy
Book4 Ultra, también conviene instalar:

```bash
sudo dnf install galaxybook-camera galaxybook-setup
```

`fedora-galaxy-book-ov02c10` es el repositorio del controlador `ov02c10`
adaptado para notebooks Samsung Galaxy Book en Fedora, con foco actual en el
**Galaxy Book4 Ultra**.

El objetivo de este proyecto es mantener un delta **pequeño y revisable** sobre
la base `ov02c10` usada por el stack **Intel IPU6** empaquetado en Fedora, y
no sobre el controlador upstream puro del kernel Linux. Eso evita divergencias
grandes entre el módulo del sensor y el resto de la pila IPU6 instalada en el
sistema.

## Estado actual

En el estado validado en agosto de 2026, el empaquetado instala el módulo
externo, le da prioridad sobre la copia in-tree, registra el sensor en el grafo
IPU6 y permite que `libcamera` enumere la cámara. Esto demuestra
**instalación y registro**, no captura estable.

La captura en el Galaxy Book4 Ultra todavía no entrega frames y registra
`csi2-4 error: Frame sync error`. La máquina proporciona un clock externo de
26 MHz, pero ni el [driver Linux v7.1](https://github.com/torvalds/linux/blob/v7.1/drivers/media/i2c/ov02c10.c)
ni la [base Intel IPU6](https://github.com/intel/ipu6-drivers/blob/master/drivers/media/i2c/ov02c10.c)
incluyen una secuencia PLL de 26 MHz validada que mantenga el enlace en 400 MHz.
La [discusión de Intel sobre el clock](https://github.com/intel/ipu6-drivers/issues/171)
también identifica esa secuencia de registros como la pieza ausente.

Por lo tanto, este proyecto **no afirma que la cámara funcione** en este
hardware. Corrige instalación, probe y metadatos sin inventar registros PLL.
La exposición a navegadores y WebRTC sigue en `Galaxy Book Setup`, pero ningún
bridge de userspace puede corregir el error físico de sincronización.

## Qué ofrece este repositorio

El repositorio separa claramente tres capas:

- `sources/intel-ipu6/ov02c10.c`: snapshot del controlador `ov02c10`
  extraído del source RPM de Intel IPU6 usado en Fedora;
- `module/ov02c10.c`: versión downstream con el delta específico necesario;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: parche generado a
  partir de la diferencia entre ambos archivos;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` para pedir `ov02c10`
  antes de `intel_ipu6_isys`;
- `data/depmod.d/galaxybook-ov02c10.conf`: override para priorizar el módulo
  empaquetado en `extra/galaxybook-ov02c10/drivers/media/i2c` sobre la copia
  in-tree de Fedora;
- `scripts/finalize-kernel.sh`: finalización de `depmod` e initramfs para el
  mismo kernel después de validar owner RPM, vermagic y payload externo;
- `scripts/kmod-lifecycle-lock.sh`: mutex global autenticado que serializa el
  mantenimiento de módulos entre los drivers Galaxy Book;
- `scripts/migrate-legacy-config.sh`: eliminación conservadora de shadows
  antiguos en `/etc` solo cuando sus bytes coinciden exactamente con contenido
  generado por el proyecto;
- `scripts/cleanup-stale-modules.sh`: detección y limpieza protegida de copias
  antiguas instaladas manualmente.

El proyecto ya no instala `modules-load.d`. Forzar el sensor al inicio del
arranque podía ejecutar el probe antes de que el grafo IPU6 estuviera listo y
producir un defer transitorio. Ahora la demanda del dispositivo activa la carga
y el `softdep` conserva el orden necesario.

El empaquetado Fedora genera:

- `akmod-galaxybook-ov02c10`
- `kmod-galaxybook-ov02c10`
- `galaxybook-ov02c10-kmod-common`

## Qué cambia hoy el parche

El delta downstream actual es intencionalmente pequeño:

- expone `get_selection()` y metadatos de crop para que userspace vea
  correctamente el área activa del sensor sobre la base Intel IPU6;
- aplica la quirk de rotación del OV02C10 también al Samsung Galaxy Book4
  Ultra, para que la imagen no quede invertida cuando el módulo corregido esté
  en uso;
- valida los recursos de power management y los datos SSDB, informa los defer
  de probe mediante la API apropiada y publica controles de
  orientación/rotación del firmware;
- corrige los metadatos del modo de dos lanes a `pixel_rate=160 MHz` y
  `HTS=2280`, conservando el line time y produciendo un `HBLANK` válido.

Esa corrección de timing es solo de metadatos: no cambia la tabla PLL del
sensor ni resuelve por sí sola el `Frame sync error` observado con 26 MHz.

Rebasarse sobre la base Intel IPU6 fue una decisión deliberada: el módulo
antiguo, aunque resolvía el probe del sensor, se había alejado demasiado del
stack instalado en Fedora 44 y empezó a romper la integración de `libcamera`
con el grafo de medios expuesto por IPU6.

## Relación con el fix comunitario del Galaxy Book3

Este trabajo fue posible gracias a lo aprendido del repositorio comunitario:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

Ese repositorio orientó la investigación de la ruta de la cámara y de los
puntos de clock y crop. Sin embargo, no proporciona una secuencia PLL de 26 MHz
validada para esta máquina. Este proyecto **no** es un fork directo de ese
código: la meta es mantener un parche pequeño sobre el `ov02c10` de Intel IPU6
que acompaña a Fedora.

## Alcance

Este repositorio cubre solo el **lado kernel** de la solución.

Para la aplicación de cámara en userspace, ver:

- <https://github.com/regiscaio/fedora-galaxy-book-camera>

Para el asistente gráfico de instalación y diagnóstico, ver:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Instalación para usuarios

### Vía RPM local

Después de generar los paquetes con `make rpm`, la instalación local
recomendada es:

```bash
sudo dnf install \
  /ruta/a/galaxybook-ov02c10-kmod-common-*.rpm \
  /ruta/a/akmod-galaxybook-ov02c10-*.rpm \
  /ruta/a/kmod-galaxybook-ov02c10-*.rpm
kernel="$(uname -r)"
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$kernel"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$kernel"
sudo reboot
```

Este es el flujo recomendado porque el `akmod` compila automáticamente el
módulo para el kernel en uso. Si ya existe un RPM binario para un kernel
específico, tendrá un nombre como
`kmod-galaxybook-ov02c10-<kernel>.rpm`; ese es el payload real del módulo. El
paquete `kmod-galaxybook-ov02c10` sin versión de kernel en el nombre es solo
el metapaquete de seguimiento y no basta por sí solo para garantizar que el
`.ko` ya esté disponible en el arranque.

Si estás actualizando RPM locales ya instalados, incluye siempre los tres
archivos en la misma transacción (`common`, `akmod` y `kmod`). Un metapaquete
`kmod-galaxybook-ov02c10` antiguo puede fijar la versión previa del `akmod`
por dependencia exacta y hacer que `dnf` ignore la actualización del driver.

El paquete común instala dos configuraciones importantes:

- un `softdep` para preferir `ov02c10` antes de `intel_ipu6_isys`;
- un override en `depmod.d` para priorizar el módulo empaquetado en
  `extra/galaxybook-ov02c10/drivers/media/i2c` sobre el driver in-tree de
  Fedora.

Un `transfiletrigger` de RPM reacciona cuando se instala el kmod real, incluso
si ocurre en una transacción posterior iniciada por `akmods`, pero nunca
consulta la base RPM dentro de esa transacción. Valida la ruta regular exacta,
el nombre y el vermagic, registra una solicitud durable y activa un worker
systemd fuera de la transacción. El worker adquiere, en este orden, el mutex
global cross-driver, el lock exclusivo privado de OV02C10 y el read lock
compatible con RPM 6. Manteniendo los tres, migra los legados y exige
exactamente un payload perteneciente a
`kmod-galaxybook-ov02c10-<kernel>` con vermagic correcto. Solo entonces
ejecuta `depmod`, exige que `modinfo` resuelva ese mismo payload, reconstruye el
initramfs, usa `lsinitrd` para rechazar copias in-tree, publica el estado listo
y confirma la solicitud en cola. Así OV02C10 no puede alterar índices o
initramfs en paralelo con otro driver que adopte el mismo contrato. El worker
inhibe apagado/suspensión,
espera `akmods.service`, reintenta mediante una unidad path y un timer, y
conserva la cola tras fallos o instalaciones en chroot.

Una actualización solo del paquete común conserva la migración en cola y la
configuración legacy de carga hasta que una solicitud de kernel demuestre un
replacement válido. El worker espera hasta 600 segundos tanto el mutex global
como una transacción RPM existente. Después de adquirir el read lock, bloquea
nuevas escrituras RPM hasta terminar `dracut`; durante esa ventana breve DNF5
puede fallar de inmediato en vez de esperar. En ese caso, espera al worker y
repite DNF.

Después publica atómicamente la atestación root-owned
`/var/lib/galaxybook-ov02c10/ready/<kernel>.state` con fingerprints del módulo
y del initramfs. El setup solo la verifica y cualquier cambio posterior la
invalida.

El paquete también migra archivos legados en `/etc/modules-load.d`,
`/etc/modprobe.d` y `/etc/depmod.d`. Solo elimina un archivo regular sin owner
RPM cuando sus bytes coinciden exactamente con una variante generada
históricamente; los symlinks y las personalizaciones locales se conservan.

Si necesitas forzar la recompilación del módulo, usa:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$(uname -r)"
sudo reboot
```

Si DNF, PackageKit o el registro de transacción vuelve a mostrar avisos de
`depmod` citando `/lib/modules/<kernel>/updates/ov02c10.ko`, busca copias
legadas que no pertenezcan a ningún RPM:

```bash
make cleanup-stale-modules
sudo make cleanup-stale-modules-apply
```

El objetivo de limpieza solo considera overrides directos antiguos en
`updates/` o `extra/` que no pertenezcan a ningún paquete. Incluso con
`--apply`, rechaza la eliminación si el mismo kernel no tiene ya exactamente
un replacement externo, perteneciente al RPM esperado y con vermagic correcto.
El módulo in-tree de Fedora y los módulos empaquetados por Intel IPU6 permanecen
intactos.

Limitación deliberada: quitar solo el kmod binario todavía no reconstruye el
initramfs automáticamente. `transfiletriggerpostun` no entrega las rutas
eliminadas y el paquete común que contiene el worker puede quitarse en la misma
transacción; una cola parcial no sería segura. Antes de quitar el paquete
común, elimina el kmod específico y reconstruye ese kernel explícitamente:

```bash
kernel="<versión-exacta-del-kernel>"
sudo /usr/bin/bash -c '
  set -euo pipefail
  source /usr/libexec/galaxybook-ov02c10/kmod-lifecycle-lock.sh
  acquire_kmod_lifecycle_lock
  /usr/bin/dnf remove "kmod-galaxybook-ov02c10-$1"
  /usr/bin/depmod -a "$1"
  /usr/bin/dracut --force --kver "$1"
' bash "$kernel"
```

Confirma con `lsinitrd --kver "$kernel"` que la ruta externa
`extra/galaxybook-ov02c10` no permanezca antes del próximo arranque.
Este procedimiento mantiene el mismo mutex global desde la eliminación RPM
hasta la reconstrucción y evita una carrera con el mantenimiento de otro
driver.

### Validación después de instalar

Antes de reiniciar, el comando `finalize-kernel` anterior es el gate: solo
termina correctamente cuando el módulo externo y el initramfs del **mismo
kernel** son coherentes. Después del reinicio, separa la validación en tres
niveles:

```bash
modinfo -n ov02c10
rpm -qf "$(modinfo -n ov02c10)"
lsmod | grep '^ov02c10 '
cam -l
cam -c 1 --capture=10
journalctl -b -k | grep -Ei 'ov02c10|frame sync|csi2'
```

Los tres niveles significan:

- **instalado**: `modinfo` apunta a
  `extra/galaxybook-ov02c10/drivers/media/i2c` y `rpm -qf` devuelve exactamente
  el kmod del kernel en uso;
- **registrado**: el módulo aparece en `lsmod` y la cámara en `cam -l`;
- **capturando**: `cam --capture` entrega los diez frames y no aparecen nuevos
  errores `Frame sync`/CSI-2 en el journal.

En el Galaxy Book4 Ultra probado, los dos primeros niveles pasan, pero el
tercero todavía falla. Por lo tanto, la enumeración en `libcamera` no se debe
usar como prueba de que la cámara funciona.

Si el arranque todavía registra:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

ese log es compatible con el rechazo de 26 MHz del driver in-tree, pero no
demuestra por sí solo el origen del módulo. Confirma la ruta y el owner RPM
exacto con los comandos anteriores. Las comprobaciones adicionales más útiles
son:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

Si los paquetes están instalados y `akmods` está sano, pero `modinfo -n
ov02c10` sigue resolviendo a `kernel/drivers/...`, el paquete generado por
`akmods` probablemente no contiene el payload
`kmod-galaxybook-ov02c10-<kernel>`. Reinstala la version corregida, fuerza
`akmods` otra vez y confirma que `modinfo -n ov02c10` apunta a una ruta externa
antes de reiniciar. La interfaz grafica tambien expone ese flujo en:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Secure Boot

Si `Secure Boot` está habilitado, el flujo de firma de módulos del sistema debe
estar configurado para `akmods`. De lo contrario, el módulo puede compilarse
correctamente pero aun así ser rechazado durante el arranque.

## Build y mantenimiento

Compilar el módulo para el kernel en uso:

```bash
make build
```

Ejecutar las pruebas de contrato del driver, parche, helpers y empaquetado:

```bash
make test
```

Regenerar el parche después de editar `module/ov02c10.c`:

```bash
make export-patch
```

Actualizar la base Intel IPU6 usada como referencia a partir del source RPM
instalado en el sistema:

```bash
make refresh-base
```

Por defecto este objetivo lee `/usr/src/akmods/intel-ipu6-kmod.latest`. Si
quieres apuntar a otro source RPM, usa:

```bash
INTEL_IPU6_SRPM=/ruta/a/intel-ipu6-kmod.src.rpm make refresh-base
```

Generar source RPM y RPM binarios:

```bash
make srpm
make rpm
```

Archivos relevantes:

- spec RPM: [`packaging/fedora/galaxybook-ov02c10-kmod.spec`](packaging/fedora/galaxybook-ov02c10-kmod.spec)
- parche downstream: [`patches/0001-galaxy-book-ov02c10-downstream.patch`](patches/0001-galaxy-book-ov02c10-downstream.patch)
- base de referencia Intel IPU6: [`sources/intel-ipu6/ov02c10.c`](sources/intel-ipu6/ov02c10.c)
