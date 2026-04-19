# Galaxy Book OV02C10

`fedora-galaxy-book-ov02c10` é o repositório do driver `ov02c10` ajustado para
uso em notebooks Samsung Galaxy Book no Fedora, com foco atual no
**Galaxy Book4 Ultra**.

O objetivo deste projeto é manter um delta **mínimo e revisável** em cima da
base `ov02c10` usada pelo stack **Intel IPU6** empacotado no Fedora, e não em
cima do driver upstream puro do kernel Linux. Isso evita divergências grandes
entre o módulo do sensor e o restante da pilha IPU6 instalada no sistema.

## Status atual

No estado validado em abril de 2026, este driver já cobre o cenário crítico do
Galaxy Book4 Ultra:

- o módulo corrigido pode ser carregado a partir de `updates/` com `Secure Boot`
  ativo, desde que o fluxo de assinatura do `akmods` esteja configurado no
  host;
- a câmera volta a aparecer no `libcamera` quando o sistema realmente usa o
  módulo corrigido, em vez da cópia in-tree do kernel;
- a quirk de rotação para o Galaxy Book4 Ultra evita a imagem invertida no app
  nativo de câmera.

O que este repositório **não** resolve sozinho é a exposição da câmera para
navegadores e comunicadores WebRTC. Esse fluxo continua centralizado no
`Galaxy Book Setup`, porque depende também de bridge V4L2 e integração do host.

## O que este repositório entrega

O repositório separa claramente três camadas:

- `sources/intel-ipu6/ov02c10.c`: snapshot do driver `ov02c10` extraído do
  source RPM do Intel IPU6 usado no Fedora;
- `module/ov02c10.c`: versão downstream com o delta específico necessário;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: patch gerado a partir
  da diferença entre os dois arquivos.
- `data/modules-load.d/galaxybook-ov02c10.conf`: configuração para garantir
  que o módulo seja carregado automaticamente no boot;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` para pedir o `ov02c10`
  antes do `intel_ipu6_isys`.

O empacotamento Fedora gera:

- `akmod-galaxybook-ov02c10`
- `kmod-galaxybook-ov02c10`
- `galaxybook-ov02c10-kmod-common`

## O que o patch muda hoje

O delta downstream atual é intencionalmente pequeno:

- expõe `get_selection()` e metadados de crop para que o userspace consiga
  enxergar corretamente a área ativa do sensor em cima da base Intel IPU6.
- aplica a quirk de rotação do OV02C10 também no Samsung Galaxy Book4 Ultra,
  para que a imagem não fique invertida quando o módulo corrigido estiver em
  uso.

O rebase para a base Intel IPU6 foi uma decisão deliberada: o módulo antigo,
embora resolvesse o probe do sensor, tinha divergido demais do stack instalado
no Fedora 44 e passava a quebrar a integração do `libcamera` com o grafo de
mídia exposto pelo IPU6.

## Relação com o fix comunitário do Galaxy Book3

O trabalho aqui foi viabilizado pelos aprendizados do repositório comunitário:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

Esse repositório foi fundamental para validar o caminho da câmera e para
identificar os pontos mais importantes em clock e crop. Ainda assim, este
projeto **não** é um fork direto daquele código. A meta aqui é manter um patch
pequeno em cima do `ov02c10` do Intel IPU6 que de fato acompanha o Fedora.

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

O pacote comum também instala duas configurações importantes:

- um arquivo em `modules-load.d` para carregar `ov02c10` no boot;
- um `softdep` para preferir `ov02c10` antes do `intel_ipu6_isys`.

Isso evita um estado em que o módulo existe em `/lib/modules/.../updates`, mas
nunca chega a ser carregado no kernel.

Se for necessário forçar a recompilação do módulo, use:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo depmod -a
sudo reboot
```

### Validação após a instalação

Os checks mais úteis depois do reboot são:

```bash
modinfo -n ov02c10
lsmod | grep '^ov02c10 '
cam -l
journalctl -b -k | grep -i ov02c10
```

O resultado esperado é:

- o módulo `ov02c10` vindo de um caminho externo priorizado para o sistema,
  preferencialmente `updates/`, e não do `kernel/drivers/...` in-tree;
- o módulo efetivamente carregado no kernel, e não apenas instalado em disco;
- a câmera aparecendo no `libcamera`;
- ausência do erro `probe with driver ov02c10 failed with error -22`.

Se o boot ainda registrar:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

então o sistema caiu de volta no driver in-tree. Nesse caso, o check mais útil
é:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

Se os pacotes estiverem instalados e o `akmods` estiver saudável, mas o
sistema ainda continuar resolvendo `modinfo -n ov02c10` para o caminho
`kernel/drivers/...`, o próximo passo é **ajustar a prioridade do módulo
corrigido**. Esse fluxo já é exposto pela interface gráfica em:

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
