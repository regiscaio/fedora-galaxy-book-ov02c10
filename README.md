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

No estado validado em agosto de 2026, o empacotamento instala o módulo externo,
prioriza-o sobre a cópia in-tree, registra o sensor no grafo IPU6 e permite que
o `libcamera` enumere a câmera. Isso comprova **instalação e registro**, não
captura estável.

A captura no Galaxy Book4 Ultra ainda termina sem quadros e registra
`csi2-4 error: Frame sync error`. A máquina fornece clock externo de 26 MHz,
mas nem o [driver Linux v7.1](https://github.com/torvalds/linux/blob/v7.1/drivers/media/i2c/ov02c10.c)
nem a [base Intel IPU6](https://github.com/intel/ipu6-drivers/blob/master/drivers/media/i2c/ov02c10.c)
trazem uma sequência PLL de 26 MHz validada para manter o link de 400 MHz. A
[discussão Intel sobre o clock](https://github.com/intel/ipu6-drivers/issues/171)
também identifica essa sequência de registradores como o ponto ausente.

Portanto, este projeto **não declara a câmera funcional** neste hardware. Ele
corrige o ciclo de instalação, probe e metadados sem inventar registradores de
PLL. A exposição para navegadores e comunicadores WebRTC continua no
`Galaxy Book Setup`, mas nenhuma bridge de userspace corrige o erro físico de
sincronismo.

## O que este repositório entrega

O repositório separa claramente três camadas:

- `sources/intel-ipu6/ov02c10.c`: snapshot do driver `ov02c10` extraído do
  source RPM do Intel IPU6 usado no Fedora;
- `module/ov02c10.c`: versão downstream com o delta específico necessário;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: patch gerado a partir
  da diferença entre os dois arquivos;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` para pedir o `ov02c10`
  antes do `intel_ipu6_isys`;
- `data/depmod.d/galaxybook-ov02c10.conf`: override para priorizar o modulo
  empacotado em `extra/galaxybook-ov02c10/drivers/media/i2c` sobre a copia
  in-tree do Fedora;
- `scripts/finalize-kernel.sh`: finalização do `depmod` e do initramfs para o
  mesmo kernel somente após validar owner RPM, `vermagic` e payload externo;
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

## O que o patch muda hoje

O delta downstream atual é intencionalmente pequeno:

- expõe `get_selection()` e metadados de crop para que o userspace consiga
  enxergar corretamente a área ativa do sensor em cima da base Intel IPU6;
- aplica a quirk de rotação do OV02C10 também no Samsung Galaxy Book4 Ultra,
  para que a imagem não fique invertida quando o módulo corrigido estiver em
  uso;
- valida os recursos de power management e o SSDB, trata defer de probe com a
  API apropriada e publica os controles de orientação/rotação do firmware;
- corrige os metadados do modo de duas lanes para `pixel_rate=160 MHz` e
  `HTS=2280`, mantendo o mesmo line time e produzindo `HBLANK` válido.

Essa correção de timing é de metadados: ela não altera a tabela PLL do sensor e
não resolve, por si só, o `Frame sync error` observado com clock de 26 MHz.

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

O pacote comum instala duas configurações importantes:

- um `softdep` para preferir `ov02c10` antes do `intel_ipu6_isys`;
- um override em `depmod.d` para priorizar o modulo empacotado em
  `extra/galaxybook-ov02c10/drivers/media/i2c` sobre o driver in-tree do
  Fedora.

Um `transfiletrigger` do RPM reage quando o kmod real é instalado — inclusive
quando isso ocorre numa transação posterior iniciada pelo `akmods`. Para cada
kernel, o finalizador exige exatamente um payload pertencente a
`kmod-galaxybook-ov02c10-<kernel>` e com `vermagic` correspondente; só então
executa `depmod`, confirma a resolução por `modinfo`, reconstrói o initramfs e
confirma com `lsinitrd` que não entrou uma cópia in-tree. Falhas não são
mascaradas.

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

Se o DNF, o PackageKit ou a tela de transacao voltar a mostrar avisos de
`depmod` citando `/lib/modules/<kernel>/updates/ov02c10.ko`, procure copias
legadas nao pertencentes a nenhum RPM:

```bash
make cleanup-stale-modules
sudo make cleanup-stale-modules-apply
```

O alvo de limpeza considera somente overrides diretos antigos em `updates/` ou
`extra/` que não pertençam a pacote nenhum. Mesmo com `--apply`, ele recusa a
remoção se o mesmo kernel ainda não tiver exatamente um replacement externo,
pertencente ao RPM esperado e com `vermagic` correto. O módulo in-tree do Fedora
e os módulos empacotados pelo Intel IPU6 permanecem intocados.

### Validação após a instalação

Antes do reboot, o comando `finalize-kernel` acima é o gate: ele só termina com
sucesso quando o módulo externo e o initramfs do **mesmo kernel** estão
coerentes. Depois do reboot, separe a validação em três níveis:

```bash
modinfo -n ov02c10
rpm -qf "$(modinfo -n ov02c10)"
lsmod | grep '^ov02c10 '
cam -l
cam -c 1 --capture=10
journalctl -b -k | grep -Ei 'ov02c10|frame sync|csi2'
```

Os três níveis significam:

- **instalado**: `modinfo` aponta para
  `extra/galaxybook-ov02c10/drivers/media/i2c` e `rpm -qf` retorna exatamente o
  kmod do kernel em uso;
- **registrado**: o módulo está em `lsmod` e a câmera aparece em `cam -l`;
- **capturando**: `cam --capture` entrega os dez quadros e não aparecem novos
  erros `Frame sync`/CSI-2 no journal.

No Galaxy Book4 Ultra testado, os dois primeiros níveis passam, mas o terceiro
ainda falha. Portanto, enumeração no `libcamera` não deve ser usada como prova
de que a câmera está funcional.

Se o boot ainda registrar:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

esse log é compatível com a rejeição de 26 MHz do driver in-tree, mas sozinho
não prova a origem do módulo. Confirme o caminho e o owner RPM exato com os
comandos acima. Os checks adicionais mais úteis são:

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
