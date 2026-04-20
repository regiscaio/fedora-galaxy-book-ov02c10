<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book OV02C10

## Installazione rapida

Per installare il driver dal repository DNF pubblico:

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-ov02c10
```

In pratica, per un'esperienza completa sul Galaxy Book4 Ultra ha senso
installare anche:

```bash
sudo dnf install galaxybook-camera galaxybook-setup
```

`fedora-galaxy-book-ov02c10` è il repository del driver `ov02c10` adattato per
i notebook Samsung Galaxy Book su Fedora, con focus attuale sul
**Galaxy Book4 Ultra**.

L'obiettivo di questo progetto è mantenere un delta **piccolo e revisionabile**
sopra la base `ov02c10` usata dallo stack **Intel IPU6** pacchettizzato in
Fedora, e non sopra il driver puro upstream del kernel Linux. In questo modo si
evitano divergenze troppo grandi tra il modulo del sensore e il resto dello
stack IPU6 installato sul sistema.

## Stato attuale

Nello stato validato ad aprile 2026, questo driver copre già lo scenario
critico del Galaxy Book4 Ultra:

- il modulo corretto può essere caricato da `updates/` con `Secure Boot`
  attivo, purché il flusso di firma di akmods sia configurato sull'host;
- la fotocamera torna visibile a `libcamera` quando il sistema usa davvero il
  modulo corretto al posto della copia in-tree del kernel;
- la quirk di rotazione per il Galaxy Book4 Ultra evita che l'immagine appaia
  capovolta nell'app nativa della fotocamera.

Quello che questo repository **non** risolve da solo è l'esposizione della
fotocamera ai browser e alle applicazioni WebRTC. Quel flusso rimane
centralizzato in `Galaxy Book Setup`, perché dipende anche dal bridge V4L2 e
dall'integrazione lato host.

## Cosa fornisce questo repository

Il repository separa chiaramente tre livelli:

- `sources/intel-ipu6/ov02c10.c`: snapshot del driver `ov02c10` estratto dallo
  source RPM Intel IPU6 usato in Fedora;
- `module/ov02c10.c`: versione downstream con il delta specifico necessario;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: patch generata dalla
  differenza tra i due file;
- `data/modules-load.d/galaxybook-ov02c10.conf`: configurazione per garantire
  il caricamento automatico del modulo all'avvio;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` per richiedere
  `ov02c10` prima di `intel_ipu6_isys`.

Il packaging Fedora genera:

- `akmod-galaxybook-ov02c10`
- `kmod-galaxybook-ov02c10`
- `galaxybook-ov02c10-kmod-common`

## Cosa cambia oggi la patch

Il delta downstream attuale è volutamente piccolo:

- espone `get_selection()` e i metadati di crop, così userspace può vedere
  correttamente l'area attiva del sensore sopra la base Intel IPU6;
- applica la quirk di rotazione dell'OV02C10 anche al Samsung Galaxy Book4
  Ultra, così l'immagine non risulta invertita quando è in uso il modulo
  corretto.

Il rebase sulla base Intel IPU6 è stata una scelta deliberata: il vecchio
modulo, pur risolvendo il probe del sensore, si era allontanato troppo dallo
stack installato in Fedora 44 e iniziava a rompere l'integrazione di
`libcamera` con il grafo multimediale esposto da IPU6.

## Relazione con il fix comunitario del Galaxy Book3

Questo lavoro è stato reso possibile dalle conoscenze ricavate dal repository
comunitario:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

Quel repository è stato fondamentale per validare il percorso della fotocamera
e identificare i punti più importanti relativi a clock e crop. Nonostante ciò,
questo progetto **non** è un fork diretto di quel codice. L'obiettivo qui è
mantenere una patch piccola sopra l'`ov02c10` di Intel IPU6 che segue davvero
Fedora.

## Ambito

Questo repository copre solo il **lato kernel** della soluzione.

Per l'applicazione userspace della fotocamera, vedere:

- <https://github.com/regiscaio/fedora-galaxy-book-camera>

Per l'assistente grafico di installazione e diagnostica, vedere:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Installazione per gli utenti

### Tramite RPM locali

Dopo aver generato i pacchetti con `make rpm`, l'installazione locale
raccomandata è:

```bash
sudo dnf install \
  /percorso/galaxybook-ov02c10-kmod-common-*.rpm \
  /percorso/akmod-galaxybook-ov02c10-*.rpm \
  /percorso/kmod-galaxybook-ov02c10-*.rpm
sudo reboot
```

Questo è il flusso consigliato perché l'`akmod` compila automaticamente il
modulo per il kernel in uso. Se esiste già un RPM binario per un kernel
specifico, avrà un nome del tipo
`kmod-galaxybook-ov02c10-<kernel>.rpm`; quello è il vero payload del modulo. Il
pacchetto `kmod-galaxybook-ov02c10` senza versione del kernel nel nome è solo
il metapacchetto di tracciamento e da solo non basta a garantire che il file
`.ko` sia già disponibile al boot.

Se stai aggiornando RPM locali già installati, includi sempre i tre file nella
stessa transazione (`common`, `akmod` e `kmod`). Un vecchio metapacchetto
`kmod-galaxybook-ov02c10` può bloccare la versione precedente dell'`akmod`
tramite dipendenza esatta e fare sì che `dnf` ignori l'aggiornamento del
driver.

Il pacchetto comune installa inoltre due configurazioni importanti:

- un file in `modules-load.d` per caricare `ov02c10` all'avvio;
- un `softdep` per preferire `ov02c10` prima di `intel_ipu6_isys`.

Questo evita uno stato in cui il modulo esiste in `/lib/modules/.../updates`
ma non viene mai realmente caricato dal kernel.

Se è necessario forzare la ricompilazione del modulo, usa:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo depmod -a
sudo reboot
```

### Verifica dopo l'installazione

I controlli più utili dopo il riavvio sono:

```bash
modinfo -n ov02c10
lsmod | grep '^ov02c10 '
cam -l
journalctl -b -k | grep -i ov02c10
```

Il risultato atteso è:

- il modulo `ov02c10` deve provenire da un percorso esterno prioritario,
  preferibilmente `updates/`, e non dalla copia in-tree `kernel/drivers/...`;
- il modulo deve essere effettivamente caricato nel kernel, non solo installato
  su disco;
- la fotocamera deve apparire in `libcamera`;
- l'errore `probe with driver ov02c10 failed with error -22` deve essere
  assente.

Se il boot continua a mostrare:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

allora il sistema è tornato al driver in-tree. In quel caso, i controlli più
utili sono:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

Se i pacchetti sono installati e `akmods` è in salute, ma `modinfo -n ov02c10`
continua a risolversi in `kernel/drivers/...`, il passo successivo è
**regolare la priorità del modulo corretto**. Quel flusso è già esposto
nell'interfaccia grafica in:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Secure Boot

Se `Secure Boot` è abilitato, il flusso di firma dei moduli del sistema deve
essere configurato per `akmods`. In caso contrario, il modulo può compilarsi
correttamente ma essere comunque rifiutato durante il boot.

## Build e manutenzione

Compilare il modulo per il kernel in uso:

```bash
make build
```

Rigenerare la patch dopo aver modificato `module/ov02c10.c`:

```bash
make export-patch
```

Aggiornare la base Intel IPU6 usata come riferimento a partire dallo source RPM
installato nel sistema:

```bash
make refresh-base
```

Per default questo target legge `/usr/src/akmods/intel-ipu6-kmod.latest`. Se
vuoi puntare a un altro source RPM, usa:

```bash
INTEL_IPU6_SRPM=/percorso/intel-ipu6-kmod.src.rpm make refresh-base
```

Generare source RPM e RPM binari:

```bash
make srpm
make rpm
```

File rilevanti:

- spec RPM: [`packaging/fedora/galaxybook-ov02c10-kmod.spec`](packaging/fedora/galaxybook-ov02c10-kmod.spec)
- patch downstream: [`patches/0001-galaxy-book-ov02c10-downstream.patch`](patches/0001-galaxy-book-ov02c10-downstream.patch)
- base di riferimento Intel IPU6: [`sources/intel-ipu6/ov02c10.c`](sources/intel-ipu6/ov02c10.c)
