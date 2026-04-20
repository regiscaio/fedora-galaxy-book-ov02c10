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

En la práctica, para una experiencia completa en el Galaxy Book4 Ultra también
conviene instalar:

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

En el estado validado de abril de 2026, este controlador ya cubre el escenario
crítico del Galaxy Book4 Ultra:

- el módulo corregido puede cargarse desde `updates/` con `Secure Boot`
  activado, siempre que el flujo de firma de akmods esté configurado en el
  host;
- la cámara vuelve a aparecer en `libcamera` cuando el sistema realmente usa
  el módulo corregido en lugar de la copia in-tree del kernel;
- la quirk de rotación del Galaxy Book4 Ultra evita que la imagen salga
  invertida en la app nativa de cámara.

Lo que este repositorio **no** resuelve por sí solo es la exposición de la
cámara para navegadores y aplicaciones WebRTC. Ese flujo sigue centralizado en
`Galaxy Book Setup`, porque también depende de un bridge V4L2 y de la
integración del host.

## Qué ofrece este repositorio

El repositorio separa claramente tres capas:

- `sources/intel-ipu6/ov02c10.c`: snapshot del controlador `ov02c10`
  extraído del source RPM de Intel IPU6 usado en Fedora;
- `module/ov02c10.c`: versión downstream con el delta específico necesario;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: parche generado a
  partir de la diferencia entre ambos archivos;
- `data/modules-load.d/galaxybook-ov02c10.conf`: configuración para asegurar
  que el módulo se cargue automáticamente en el arranque;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` para pedir `ov02c10`
  antes de `intel_ipu6_isys`.

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
  en uso.

Rebasarse sobre la base Intel IPU6 fue una decisión deliberada: el módulo
antiguo, aunque resolvía el probe del sensor, se había alejado demasiado del
stack instalado en Fedora 44 y empezó a romper la integración de `libcamera`
con el grafo de medios expuesto por IPU6.

## Relación con el fix comunitario del Galaxy Book3

Este trabajo fue posible gracias a lo aprendido del repositorio comunitario:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

Ese repositorio fue fundamental para validar la ruta de la cámara e identificar
los puntos más importantes de clock y crop. Aun así, este proyecto **no** es
un fork directo de ese código. La meta aquí es mantener un parche pequeño sobre
el `ov02c10` de Intel IPU6 que realmente acompaña a Fedora.

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

El paquete común también instala dos configuraciones importantes:

- un archivo en `modules-load.d` para cargar `ov02c10` en el arranque;
- un `softdep` para preferir `ov02c10` antes de `intel_ipu6_isys`.

Eso evita un estado en el que el módulo existe en `/lib/modules/.../updates`
pero nunca llega a cargarse en el kernel.

Si necesitas forzar la recompilación del módulo, usa:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo depmod -a
sudo reboot
```

### Validación después de instalar

Las comprobaciones más útiles después del reinicio son:

```bash
modinfo -n ov02c10
lsmod | grep '^ov02c10 '
cam -l
journalctl -b -k | grep -i ov02c10
```

Lo esperado es:

- el módulo `ov02c10` viniendo de una ruta externa prioritaria, idealmente
  `updates/`, y no de `kernel/drivers/...` in-tree;
- el módulo realmente cargado en el kernel, y no solo instalado en disco;
- la cámara apareciendo en `libcamera`;
- ausencia del error `probe with driver ov02c10 failed with error -22`.

Si el arranque todavía registra:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

entonces el sistema volvió al driver in-tree. En ese caso, las comprobaciones
más útiles son:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

Si los paquetes están instalados y `akmods` está sano, pero `modinfo -n
ov02c10` sigue resolviendo a `kernel/drivers/...`, el siguiente paso es
**ajustar la prioridad del módulo corregido**. Ese flujo ya está expuesto en la
interfaz gráfica en:

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
