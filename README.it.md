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

Come strumenti complementari di diagnostica e userspace per il Galaxy Book4
Ultra, ha senso installare anche:

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

Nell'agosto 2026 il modulo esterno ha registrato il sensore nel grafo IPU6 e
`libcamera` ha elencato la fotocamera, ma la cattura non ha restituito alcun
fotogramma. Il journal ha registrato `csi2-4 error: Frame sync error`.

Il nuovo adeguamento si applica solo al Samsung Galaxy Book4 Ultra `960XGL`
con scheda DMI `NP960XGL-XG1BR`, clock del sensore di **26 MHz** e due lane
CSI-2. Nella modalità nominale da 400 MHz il driver comunica la frequenza
effettiva del link di **541666666 Hz** e **216666666 pixel/s**; il VTS
predefinito è di **3152 righe**. Non riprogramma il PLL né modifica il bridge
IPU6. Per le altre schede, frequenze e configurazioni delle lane i tempi
rimangono invariati.

Il 21 ottobre [4nrry ha misurato 30,08 fps sullo stesso modello di scheda](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/123#issuecomment-6319696718)
con un altro driver che usa questi tempi. Non è una verifica di questo
pacchetto Fedora: per provarlo sul notebook usare il test dei dieci fotogrammi
descritto più avanti.

## Cosa fornisce questo repository

Il repository separa chiaramente tre livelli:

- `sources/intel-ipu6/ov02c10.c`: snapshot del driver `ov02c10` estratto dallo
  source RPM Intel IPU6 usato in Fedora;
- `module/ov02c10.c`: versione downstream con il delta specifico necessario;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: patch generata dalla
  differenza tra i due file;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` per richiedere
  `ov02c10` prima di `intel_ipu6_isys`;
- `data/depmod.d/galaxybook-ov02c10.conf`: override per dare priorità al
  modulo pacchettizzato in `extra/galaxybook-ov02c10/drivers/media/i2c`
  rispetto alla copia in-tree di Fedora;
- `scripts/finalize-kernel.sh`: finalizzazione di `depmod` e initramfs per lo
  stesso kernel dopo aver validato owner RPM, vermagic e payload esterno;
- `scripts/kmod-lifecycle-lock.sh`: mutex globale autenticato che serializza la
  manutenzione dei moduli tra i driver Galaxy Book;
- `scripts/migrate-legacy-config.sh`: rimozione conservativa dei vecchi shadow
  in `/etc` solo quando i byte corrispondono esattamente a contenuti generati
  dal progetto;
- `scripts/cleanup-stale-modules.sh`: rilevamento e pulizia protetta delle
  vecchie copie installate manualmente.

Il progetto non installa più `modules-load.d`. Forzare il sensore all'inizio
del boot poteva eseguire il probe prima che il grafo IPU6 fosse pronto e
produrre un defer transitorio. Ora il caricamento è guidato dalla richiesta del
dispositivo, mentre il `softdep` conserva l'ordine necessario.

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
  corretto;
- valida le risorse di power management e i dati SSDB, segnala i defer del
  probe tramite l'API appropriata e pubblica i controlli di
  orientamento/rotazione del firmware;
- mantiene `HTS=2280` nella modalità a due lane. La velocità nominale a
  19,2 MHz è di 160 milioni di pixel/s; soltanto la configurazione a 26 MHz
  descritta sopra adegua le velocità dichiarate e la durata predefinita del
  fotogramma.

Il rebase sulla base Intel IPU6 è stata una scelta deliberata: il vecchio
modulo, pur risolvendo il probe del sensore, si era allontanato troppo dallo
stack installato in Fedora 44 e iniziava a rompere l'integrazione di
`libcamera` con il grafo multimediale esposto da IPU6.

## Relazione con il fix comunitario del Galaxy Book3

Questo lavoro è stato reso possibile dalle conoscenze ricavate dal repository
comunitario:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

Quel repository ha guidato l'indagine sul percorso della fotocamera e sui punti
relativi a clock e crop. Tuttavia, non fornisce una sequenza PLL a 26 MHz
validata per questa macchina. Questo progetto **non** è un fork diretto di quel
codice: l'obiettivo è mantenere una patch piccola sopra l'`ov02c10` di Intel
IPU6 che segue Fedora.

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
kernel="$(uname -r)"
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$kernel"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$kernel"
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

OV02C10 `1.00.25` coordina le transazioni solo con
`galaxybook-max98390-kmod-common` `1.00.12` o successivo e
`galaxybook-setup` `1.00.48` o successivo quando questi pacchetti sono già
installati. Aggiorna l'insieme in un'unica operazione; le dipendenze
condizionali non installano automaticamente un componente mancante.

La migrazione iniziale dalla linea pubblica legacy è supportata solo tramite
la procedura DNF online, con systemd attivo. Non riavviare finché recovery e
riconciliazione non sono terminate. Un aggiornamento iniziale in chroot o in
un'immagine offline non applica lo stato dei nuovi attivatori; in seguito,
esegui la procedura online completa prima di considerare armati la path unit e
il timer. Le mask amministrative preesistenti non vengono rimosse: la migrazione
fallisce in modo chiuso affinché l'amministratore possa mantenere o rivedere
tale policy.

Il worker richiede inoltre che il kmod specifico del kernel e il pacchetto
`common` abbiano lo stesso EVR. Se il nuovo `common` arriva prima del kmod
corrispondente, la coda resta durevole e nessun `depmod`, initramfs o stato
`ready` viene pubblicato con il payload precedente. Un'installazione pubblica
legacy senza worker rimane senza worker dopo il rollback. Un precedente
preview transazionale con worker resta mascherato e adottabile finché una nuova
transazione compatibile non completa il recupero.

Il pacchetto comune installa due configurazioni importanti:

- un `softdep` per preferire `ov02c10` prima di `intel_ipu6_isys`;
- un override in `depmod.d` per dare priorità al modulo pacchettizzato in
  `extra/galaxybook-ov02c10/drivers/media/i2c` rispetto al driver in-tree di
  Fedora.

Un `transfiletrigger` RPM reagisce quando viene installato il kmod reale, anche
se ciò avviene in una transazione successiva avviata da `akmods`, ma non
interroga mai il database RPM dentro la transazione. Convalida il percorso
regolare esatto, nome e vermagic, registra una richiesta durevole e avvia un
worker systemd fuori transazione. Il worker acquisisce, nell'ordine, il mutex
globale cross-driver, il lock esclusivo privato di OV02C10 e il read lock
compatibile con RPM 6. Mantenendo tutti e tre, migra i legacy e richiede
esattamente un payload appartenente a
`kmod-galaxybook-ov02c10-<kernel>` con vermagic corretto. Solo allora esegue
`depmod`, richiede che `modinfo` risolva lo stesso payload, ricostruisce
l'initramfs, usa `lsinitrd` per rifiutare copie in-tree, pubblica lo stato
pronto e conferma la richiesta in coda. OV02C10 non può quindi modificare
indici o initramfs in parallelo con un altro driver che adotta lo stesso
contratto. Il worker inibisce
spegnimento/sospensione, attende `akmods.service`, ritenta con una path unit e
un timer e conserva la coda dopo errori o installazioni in chroot.

Un aggiornamento del solo pacchetto common mantiene la migrazione in coda e la
configurazione legacy di caricamento finché una richiesta kernel non dimostra
un replacement valido. Il worker attende fino a 600 secondi sia il mutex
globale sia una transazione RPM esistente. Dopo aver acquisito il read lock
blocca nuove scritture RPM fino al termine di `dracut`; in questa breve
finestra DNF5 può fallire subito invece di attendere. In tal caso attendi il
worker e ripeti l'operazione DNF.

Pubblica poi atomicamente l'attestazione root-owned
`/var/lib/galaxybook-ov02c10/ready/<kernel>.state` con fingerprint del modulo e
dell'initramfs. Il setup la verifica soltanto e ogni modifica successiva la
invalida.

Il pacchetto migra inoltre i file legacy in `/etc/modules-load.d`,
`/etc/modprobe.d` e `/etc/depmod.d`. Rimuove un file regolare senza owner RPM
solo quando i suoi byte corrispondono esattamente a una variante storicamente
generata; symlink e personalizzazioni locali vengono preservati.

Se è necessario forzare la ricompilazione del modulo, usa:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$(uname -r)"
sudo reboot
```

Se DNF, PackageKit o il registro della transazione mostra avvisi di `depmod`
che citano `/lib/modules/<kernel>/updates/ov02c10.ko`, cerca copie obsolete che
non appartengono a nessun RPM:

```bash
make cleanup-stale-modules
sudo make cleanup-stale-modules-apply
```

Il target di pulizia considera solo vecchi override diretti in `updates/` o
`extra/` quando non appartengono ad alcun pacchetto. Anche con `--apply`,
rifiuta la rimozione se lo stesso kernel non dispone già di esattamente un
replacement esterno, appartenente all'RPM previsto e con vermagic corretto. Il
modulo in-tree di Fedora e i moduli pacchettizzati da Intel IPU6 restano
intatti.

Le sezioni `%post` e `%postun` normalmente generate da `kmodtool` per ogni
kmod binario sono no-op espliciti: non eseguono `depmod` né tentano di acquisire
il mutex globale mentre RPM mantiene il proprio lock. Durante l'installazione,
il `transfiletriggerin` sopra accoda soltanto il lavoro che il worker esegue
dopo la transazione. Durante la rimozione, `%postun` resta intenzionalmente un
no-op e si applica la limitazione manuale seguente.

Limitazione deliberata: la rimozione esatta del kmod binario **non è supportata
automaticamente in questa versione**. `transfiletriggerpostun` non fornisce i
percorsi rimossi, `%postun` è deliberatamente un no-op e il pacchetto common che
possiede il worker potrebbe uscire nella stessa transazione. Mantieni installato
il pacchetto common e non considerare una sequenza manuale di `dnf`, `depmod` e
`dracut` una rimozione coordinata. Una futura API appartenente al pacchetto
dovrà validare l'assenza del modulo e i marker pending/ready, eseguire la
transazione e poi mantenere, in quest'ordine, il mutex globale, il lock privato
e il read lock condiviso di RPM durante l'intera riconciliazione successiva alla
transazione.

### Verifica dopo l'installazione

Prima del riavvio, il comando `finalize-kernel` sopra è il gate: termina con
successo solo quando il modulo esterno e l'initramfs dello **stesso kernel**
sono coerenti. Dopo il riavvio, separa la verifica in tre livelli:

```bash
modinfo -n ov02c10
rpm -qf "$(modinfo -n ov02c10)"
lsmod | grep '^ov02c10 '
cam -l
capture_start=$(date --iso-8601=seconds)
timeout 15s cam -c 1 --capture=10
journalctl -b -k --since "$capture_start" | grep -Ei 'ov02c10|frame sync|csi2'
```

I tre livelli significano:

- **installato**: `modinfo` punta a
  `extra/galaxybook-ov02c10/drivers/media/i2c` e `rpm -qf` restituisce
  esattamente il kmod del kernel in uso;
- **registrato**: il modulo compare in `lsmod` e la fotocamera in `cam -l`;
- **in cattura**: usare il numero della fotocamera interna indicato da
  `cam -l` (nell'esempio è `1`). Il test deve restituire dieci fotogrammi,
  ciascuno con `bytesused > 0`, senza salvare immagini (omettere `--file`).

Un singolo avviso di sincronizzazione all'avvio non dimostra la perdita di
fotogrammi. Errori ripetuti durante la cattura, buffer vuoti o timeout non
costituiscono un esito positivo.

Se il boot continua a mostrare:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

quel log è compatibile con il rifiuto dei 26 MHz del driver in-tree, ma da solo
non dimostra l'origine del modulo. `modinfo -n` e `rpm -qf` identificano il file
su disco, non il modulo in memoria. Se l'RPM è stato installato dopo l'avvio,
il kernel potrebbe usare ancora la copia precedente. Controllare anche:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

Se i pacchetti sono installati e `akmods` è in salute, ma `modinfo -n ov02c10`
continua a risolversi in `kernel/drivers/...`, probabilmente il pacchetto
generato da `akmods` non contiene il payload
`kmod-galaxybook-ov02c10-<kernel>`. Reinstalla la versione corretta, forza
nuovamente `akmods` e conferma che `modinfo -n ov02c10` punti a un percorso
esterno prima di riavviare. L'interfaccia grafica espone anche questo flusso in:

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

Eseguire i test di contratto di driver, patch, helper e packaging:

```bash
make test
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
