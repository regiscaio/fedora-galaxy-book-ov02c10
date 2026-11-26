<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book OV02C10

## Instalação rápida

Para instalar o driver a partir do repositório DNF público:

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-ov02c10
```

Como ferramentas complementares de diagnóstico e userspace no Galaxy Book4
Ultra, também faz sentido instalar:

```bash
sudo dnf install galaxybook-camera galaxybook-setup
```

`fedora-galaxy-book-ov02c10` é o repositório do driver `ov02c10` ajustado para
uso em notebooks Samsung Galaxy Book no Fedora, com foco atual no
**Galaxy Book4 Ultra**.

O objetivo deste projeto é manter um delta **mínimo e revisável** em cima da
base `ov02c10` usada pelo stack **Intel IPU6** empacotado no Fedora, e não em
cima do driver upstream puro do kernel Linux. Isso evita divergências grandes
entre o módulo do sensor e o restante da pilha IPU6 instalada no sistema.

## Status atual

Em agosto de 2026, o módulo externo registrou o sensor no grafo IPU6 e o
`libcamera` enumerou a câmera, mas a captura não entregou quadros. O journal
registrou `csi2-4 error: Frame sync error`.

O novo ajuste só se aplica ao Samsung Galaxy Book4 Ultra `960XGL` com placa
DMI `NP960XGL-XG1BR`, sensor a **26 MHz** e duas lanes CSI-2. Na configuração
nominal de 400 MHz, o driver passa a informar o link real de **541666666 Hz**
e a taxa de **216666666 pixels/s**; o VTS padrão passa para **3152 linhas**.
Não reprograma o PLL nem altera a ponte IPU6. Outros modelos, clocks e
configurações de lanes mantêm o comportamento anterior.

Em 21 de outubro, [4nrry mediu 30,08 fps no mesmo modelo de placa](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/123#issuecomment-6319696718),
com outro driver baseado nesses tempos. Esse resultado não valida este pacote
Fedora: a captura local só fica comprovada após o teste de dez quadros abaixo.

## O que este repositório entrega

O repositório separa claramente três camadas:

- `sources/intel-ipu6/ov02c10.c`: snapshot do driver `ov02c10` extraído do
  source RPM do Intel IPU6 usado no Fedora;
- `module/ov02c10.c`: versão downstream com o delta específico necessário;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: patch gerado a partir
  da diferença entre os dois arquivos;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` para pedir o `ov02c10`
  antes do `intel_ipu6_isys`;
- `data/depmod.d/galaxybook-ov02c10.conf`: override para priorizar o módulo
  empacotado em `extra/galaxybook-ov02c10/drivers/media/i2c` sobre a cópia
  in-tree do Fedora;
- `scripts/finalize-kernel.sh`: finalização do `depmod` e do initramfs para o
  mesmo kernel somente após validar owner RPM, `vermagic` e payload externo;
- `scripts/kmod-lifecycle-lock.sh`: mutex global autenticado que serializa
  manutenção de módulos entre os drivers Galaxy Book;
- `scripts/migrate-legacy-config.sh`: remoção conservadora de shadows antigos
  em `/etc` somente quando os bytes forem exatamente os gerados pelo projeto;
- `scripts/cleanup-stale-modules.sh`: detecção e limpeza protegida de módulos
  manuais antigos.

O projeto não instala mais `modules-load.d`. Forçar o sensor no início do boot
podia antecipar o probe antes de o grafo IPU6 estar pronto e produzir um defer
transitório. O carregamento fica a cargo da demanda do dispositivo, com o
`softdep` preservando a ordem necessária.

O empacotamento Fedora gera:

- `akmod-galaxybook-ov02c10`
- `kmod-galaxybook-ov02c10`
- `galaxybook-ov02c10-kmod-common`

Na reconstrução local, o `akmods` indica o kernel de destino. Nesse modo, o
pacote gera apenas o RPM daquele kernel. O `-common` instalado continua
responsável pela fila de finalização; um rebuild não deve reinstalá-lo.

## O que o patch muda hoje

O delta downstream atual é intencionalmente pequeno:

- expõe `get_selection()` e metadados de crop para que o userspace consiga
  enxergar corretamente a área ativa do sensor em cima da base Intel IPU6;
- aplica a quirk de rotação do OV02C10 também no Samsung Galaxy Book4 Ultra,
  para que a imagem não fique invertida quando o módulo corrigido estiver em
  uso;
- valida os recursos de power management e o SSDB, trata defer de probe com a
  API apropriada e publica os controles de orientação/rotação do firmware;
- mantém `HTS=2280` no modo de duas lanes. A taxa nominal a 19,2 MHz é
  de 160 milhões de pixels/s; somente a configuração de 26 MHz descrita
  acima ajusta as taxas anunciadas e a duração padrão do quadro.

O rebase para a base Intel IPU6 foi uma decisão deliberada: o módulo antigo,
embora resolvesse o probe do sensor, tinha divergido demais do stack instalado
no Fedora 44 e passava a quebrar a integração do `libcamera` com o grafo de
mídia exposto pelo IPU6.

## Relação com o fix comunitário do Galaxy Book3

O trabalho aqui foi viabilizado pelos aprendizados do repositório comunitário:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

Esse repositório orientou a investigação do caminho da câmera e dos pontos de
clock e crop. Ele não fornece, contudo, uma sequência PLL de 26 MHz validada
para esta máquina. Este projeto **não** é um fork direto daquele código: a meta
é manter um patch pequeno em cima do `ov02c10` do Intel IPU6 que acompanha o
Fedora.

## Escopo

Este repositório cobre apenas o **lado kernel** da solução.

Para o aplicativo de câmera em userspace, veja:

- <https://github.com/regiscaio/fedora-galaxy-book-camera>

Para o auxiliar de instalação e diagnóstico em interface gráfica, veja:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Instalação para usuários

### Via RPM local

Depois de gerar os pacotes com `make rpm`, a instalação local recomendada é:

```bash
sudo dnf install \
  /caminho/para/galaxybook-ov02c10-kmod-common-*.rpm \
  /caminho/para/akmod-galaxybook-ov02c10-*.rpm \
  /caminho/para/kmod-galaxybook-ov02c10-*.rpm
kernel="$(uname -r)"
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$kernel"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$kernel"
sudo reboot
```

Esse é o fluxo recomendado porque o `akmod` compila automaticamente o módulo
para o kernel em uso. Se um RPM binário já existir para um kernel específico,
ele terá um nome no formato `kmod-galaxybook-ov02c10-<kernel>.rpm`; esse é o
payload real do módulo. O pacote `kmod-galaxybook-ov02c10` sem versão de
kernel no nome é apenas um metapacote de acompanhamento e não é suficiente por
si só para garantir que o `.ko` já esteja disponível no boot.

Se você estiver atualizando RPMs locais já instalados, inclua sempre os três
arquivos na mesma transação (`common`, `akmod` e `kmod`). Um metapacote
`kmod-galaxybook-ov02c10` antigo pode manter a versão anterior do `akmod`
presa por dependência exata e fazer o `dnf` ignorar a atualização do driver.

O OV02C10 `1.00.25` coordena transações apenas com
`galaxybook-max98390-kmod-common` `1.00.12` ou superior e
`galaxybook-setup` `1.00.48` ou superior, quando esses pacotes já estão
instalados. Atualize o conjunto na mesma operação; as dependências condicionais
não instalam automaticamente um componente ausente.

A migração inicial da linha pública legada é suportada somente pelo
procedimento DNF online, com o systemd ativo. Não reinicie até a recuperação e
a reconciliação terminarem. Uma atualização inicial em chroot ou imagem
offline não aplica o estado dos novos ativadores; depois dela, execute o
procedimento online completo antes de considerar o `path` e o timer armados.
Máscaras administrativas preexistentes não são removidas: a migração falha de
forma fechada para que o administrador possa manter ou revisar essa política.

O worker também exige que o kmod exato do kernel e o pacote `common` tenham o
mesmo EVR. Se o `common` novo chegar antes do kmod correspondente, a fila
permanece durável e nenhum `depmod`, initramfs ou estado `ready` é publicado
com o payload antigo. Uma instalação pública legada sem worker permanece sem
worker após rollback. Já um preview transacional anterior com worker fica
mascarado e adotável até uma nova transação compatível concluir a recuperação.

O pacote comum instala duas configurações importantes:

- um `softdep` para preferir `ov02c10` antes do `intel_ipu6_isys`;
- um override em `depmod.d` para priorizar o módulo empacotado em
  `extra/galaxybook-ov02c10/drivers/media/i2c` sobre o driver in-tree do
  Fedora.

Um `transfiletrigger` do RPM reage quando o kmod real é instalado — inclusive
quando isso ocorre numa transação posterior iniciada pelo `akmods` — mas não
consulta o banco do RPM dentro da própria transação. Ele valida caminho,
arquivo regular, nome e `vermagic`, grava uma fila durável e aciona um worker
systemd fora da transação. O worker adquire, nessa ordem, o mutex global
cross-driver, o lock exclusivo privado do OV02C10 e o read lock compatível com
o RPM 6. Mantendo os três, migra os legados e, para cada kernel, exige
exatamente um payload pertencente a `kmod-galaxybook-ov02c10-<kernel>` e com
`vermagic` correspondente; só então executa `depmod`, confirma que `modinfo`
resolve o mesmo payload, reconstrói o initramfs, confirma com `lsinitrd` que não
entrou uma cópia in-tree, publica a atestação de prontidão e confirma a
solicitação da fila. Assim, o OV02C10 não pode alterar índices ou initramfs em
paralelo com outro driver que
adote o mesmo contrato. O worker impede shutdown/suspensão durante todo o
ciclo, espera `akmods.service`, tenta novamente por `path`/timer e preserva a
fila em caso de falha ou instalação em chroot.

Uma atualização somente do pacote comum mantém a migração na fila e preserva
a configuração legada de carregamento até que um pedido de kernel prove um
replacement válido. O worker espera por até 600 segundos tanto o mutex global
quanto uma transação RPM já em andamento. Depois de adquirir o read lock,
bloqueia novas escritas no RPM até terminar o `dracut`; nessa janela curta, o
DNF5 pode falhar imediatamente em vez de esperar. Nesse caso, aguarde o worker
e repita a operação do DNF.

Depois da verificação, o mesmo ciclo publica
`/var/lib/galaxybook-ov02c10/ready/<kernel>.state` com fingerprints do módulo e
do initramfs. A atestação root-owned é criada atomicamente ainda sob os locks;
o setup apenas a confere e qualquer troca posterior dos arquivos a invalida.

O pacote também migra arquivos legados em `/etc/modules-load.d`,
`/etc/modprobe.d` e `/etc/depmod.d`. Só remove um arquivo regular não pertencente
a RPM quando seus bytes correspondem exatamente a uma variante historicamente
gerada; symlinks e customizações locais são preservados.

Se for necessário forçar a recompilação do módulo, use:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$(uname -r)"
sudo reboot
```

Se o DNF, o PackageKit ou a tela de transação voltar a mostrar avisos de
`depmod` citando `/lib/modules/<kernel>/updates/ov02c10.ko`, procure cópias
legadas não pertencentes a nenhum RPM:

```bash
make cleanup-stale-modules
sudo make cleanup-stale-modules-apply
```

O alvo de limpeza considera somente overrides diretos antigos em `updates/` ou
`extra/` que não pertençam a pacote nenhum. Mesmo com `--apply`, ele recusa a
remoção se o mesmo kernel ainda não tiver exatamente um replacement externo,
pertencente ao RPM esperado e com `vermagic` correto. O módulo in-tree do Fedora
e os módulos empacotados pelo Intel IPU6 permanecem intocados.

Os `%post` e `%postun` gerados pelo `kmodtool` para cada kmod binário são
no-ops explícitos: não executam `depmod` nem tentam adquirir o mutex global
enquanto o RPM mantém seu próprio lock. Na instalação, o `transfiletriggerin`
acima só enfileira o trabalho, que o worker executa depois da transação. Na
remoção, o `%postun` continua no-op de propósito e vale a limitação manual a
seguir.

Limitação deliberada: a remoção exata do kmod binário **não é suportada
automaticamente nesta versão**. `transfiletriggerpostun` não entrega os
caminhos removidos, o `%postun` é deliberadamente um no-op e o pacote comum que
possui o worker poderia sair na mesma transação. Mantenha o pacote comum
instalado e não use uma sequência manual de `dnf`, `depmod` e `dracut` como se
ela fosse uma remoção coordenada. Uma futura API pertencente ao pacote deverá
validar a ausência do módulo e os marcadores pendentes/prontos, executar a
transação e então manter, nessa ordem, o mutex global, o lock privado e o read
lock compartilhado do RPM durante toda a reconciliação pós-transação.

### Validação após a instalação

Antes do reboot, o comando `finalize-kernel` acima é o gate: ele só termina com
sucesso quando o módulo externo e o initramfs do **mesmo kernel** estão
coerentes. Depois do reboot, separe a validação em três níveis:

```bash
modinfo -n ov02c10
rpm -qf "$(modinfo -n ov02c10)"
lsmod | grep '^ov02c10 '
cam -l
capture_start=$(date --iso-8601=seconds)
timeout 15s cam -c 1 --capture=10
journalctl -b -k --since "$capture_start" | grep -Ei 'ov02c10|frame sync|csi2'
```

Os três níveis significam:

- **instalado**: `modinfo` aponta para
  `extra/galaxybook-ov02c10/drivers/media/i2c` e `rpm -qf` retorna exatamente o
  kmod do kernel em uso;
- **registrado**: o módulo está em `lsmod` e a câmera aparece em `cam -l`;
- **capturando**: selecione em `cam -l` o número da câmera interna (o exemplo
  usa `1`). O teste deve terminar com dez quadros, cada um com `bytesused > 0`,
  sem gravar imagens (não use `--file`).

Um aviso de sincronismo isolado ao iniciar não comprova perda de quadros.
Erros recorrentes durante a captura, quadros vazios ou o limite de tempo
atingido não constituem sucesso.

Se o boot ainda registrar:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

esse log é compatível com a rejeição de 26 MHz do driver in-tree, mas sozinho
não prova a origem do módulo. `modinfo -n` e `rpm -qf` identificam o
arquivo em disco, não o módulo carregado. Se o RPM foi instalado depois do
boot, o kernel pode continuar usando a cópia anterior. Confira também:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

Se os pacotes estiverem instalados e o `akmods` estiver saudável, mas o
sistema ainda continuar resolvendo `modinfo -n ov02c10` para o caminho
`kernel/drivers/...`, o pacote gerado pelo `akmods` provavelmente não contém o
payload `kmod-galaxybook-ov02c10-<kernel>`. Reinstale a versao corrigida,
force o `akmods` novamente e confirme que `modinfo -n ov02c10` aponta para um
caminho externo antes do reboot. A interface grafica tambem expoe esse fluxo
em:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Secure Boot

Se `Secure Boot` estiver habilitado, o fluxo de assinatura de módulos do
sistema precisa estar configurado para `akmods`. Caso contrário, o módulo pode
ser compilado corretamente, mas não ser aceito no boot.

## Build e manutenção

Compilar o módulo para o kernel em uso:

```bash
make build
```

Executar os testes de contrato do driver, patch, helpers e empacotamento:

```bash
make test
```

Regenerar o patch depois de editar `module/ov02c10.c`:

```bash
make export-patch
```

Atualizar a base Intel IPU6 usada como referência a partir do source RPM
instalado no sistema:

```bash
make refresh-base
```

Esse alvo lê por padrão `/usr/src/akmods/intel-ipu6-kmod.latest`. Se você
quiser apontar para outro source RPM, use:

```bash
INTEL_IPU6_SRPM=/caminho/para/intel-ipu6-kmod.src.rpm make refresh-base
```

Gerar source RPM e RPMs binários:

```bash
make srpm
make rpm
```

Arquivos relevantes:

- spec RPM: [`packaging/fedora/galaxybook-ov02c10-kmod.spec`](packaging/fedora/galaxybook-ov02c10-kmod.spec)
- patch downstream: [`patches/0001-galaxy-book-ov02c10-downstream.patch`](patches/0001-galaxy-book-ov02c10-downstream.patch)
- base Intel IPU6 de referência: [`sources/intel-ipu6/ov02c10.c`](sources/intel-ipu6/ov02c10.c)
