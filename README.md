# Módulos do PowerShell

## Requisitos

- Windows PowerShell 5.1 ou PowerShell 7+.
- Git no `PATH` — apenas para o FancyGit-Pwsh (sem o Git, o prompt mostra apenas o caminho).
- Maven no `PATH` e pelo menos um JDK instalado — apenas para o módulo Java.
- Para publicar no Service Bus: string de conexão SAS com permissão **Send** e autenticação SAS/local habilitada; nenhum módulo nem CLI do Azure é necessário.
- Pester 3.4.x (já incluído no Windows PowerShell 5.1) — apenas para executar os testes do repositório.

## Módulos e funções exportadas

Importe o módulo necessário a partir de `Modules\`. O módulo Java exporta:

- `Import-DotEnv`: Lê as atribuições compatíveis de um arquivo `.env` e as retorna como strings `nome=valor`. Não modifica o ambiente.
- `Set-JdkPath`: Adiciona ou atualiza o caminho de um JDK em `java\config.json`; use `-Remove` para remover uma versão.
- `Set-MavenProfiles`: Lista ou altera os perfis Maven ativados automaticamente por `runMvn`; as alteracoes sao salvas e aplicadas imediatamente.
- `runMvn`: Executa o Maven e, quando presente, seleciona o JDK configurado em `java.version` no `pom.xml` do diretório atual.
- `runApp`: Compila o projeto com `mvn clean package -Pazure` e, em seguida, executa o único arquivo JAR do projeto usando o JDK configurado. Carrega os valores de `.env` para o processo filho e restaura o ambiente do processo atual depois da execução.

O módulo Service Bus exporta `publishEvt`, que publica um arquivo como uma única mensagem em uma fila do Azure Service Bus.

O módulo FancyGit-Pwsh exporta:

- `Get-FancyGitStatus`: Retorna o objeto de status do Git de um caminho (ramo, ahead/behind e contagens de alterações).
- `Get-FancyGitPromptString`: Monta a string completa do prompt de um caminho.
- `Format-FancyGitPrompt`: Retorna apenas o fragmento Git do prompt, com tema opcional.
- `Set-FancyGitTheme`: Seleciona o tema ativo (classic, ascii, minimal, darcula).
- `Set-FancyGitOption`: Altera opções como ShowUserHost, PathStyle, UseColor e StatusCacheMilliseconds.
- `Enable-FancyGitPrompt` e `Disable-FancyGitPrompt`: Ativa o prompt FancyGit ou restaura o prompt anterior.
- `Enable-FancyGitAliases` e `Disable-FancyGitAliases`: Instala ou remove os aliases do Git portados do fancy-git (gs, ga, gcm, gpl, ...), restaurando os originais.
- `Enable-FancyGitPSReadLine`: Aplica a configuração recomendada do PSReadLine.
- `fancygit`: Ponto de entrada único, no estilo `git`, para as funções acima, com tab-completion.

Todas as funções exportadas aceitam `-Help` para exibir um resumo e as descrições dos parâmetros. Também é possível usar o comando de ajuda do PowerShell:

```powershell
runApp -Help
Get-Help runApp -Full
publishEvt -Help
```

### Java e Maven

Neste diretório, importe o módulo e execute seus comandos a partir do diretório de um projeto Maven:

```powershell
Import-Module .\Modules\java\java.psm1 -Force

# Inspeciona as atribuições analisadas de .env sem definir variáveis de ambiente do processo.
Import-DotEnv -Path .\.env

# Executa o Maven usando a versão do JDK declarada no pom.xml deste projeto.
runMvn clean verify

# Compila com o perfil azure e executa o único JAR do projeto.
runApp

# Adiciona ou atualiza o caminho do JDK para uma versão do Java.
Set-JdkPath -Version 25 -Path 'C:\Program Files\Java\jdk-25'

# Remove uma versão do mapa de JDKs.
Set-JdkPath -Version 11 -Remove
```

`Set-JdkPath` exige que o diretório informado exista. Use `-WhatIf` para conferir
uma alteração sem gravá-la.

`runMvn` e `runApp` exigem que o Maven esteja no `PATH`. A seleção do JDK é configurada em
`java.psm1`; o JDK selecionado deve estar instalado nesta máquina. Para a seleção
automática, o `pom.xml` do projeto deve definir `java.version` com uma versão
configurada. `runApp` lê os valores opcionais `JAVA_OPTS` e `APP_ARGS` do ambiente
do processo ou do arquivo `.env` do projeto.

Gerencie os perfis Maven ativados automaticamente com `Set-MavenProfiles`:

```powershell
Set-MavenProfiles                              # Lista os perfis configurados.
Set-MavenProfiles -Profiles dev,integration     # Substitui a lista.
Set-MavenProfiles -Profiles qa -Add             # Adiciona sem duplicatas.
Set-MavenProfiles -Profiles integration -Remove
Set-MavenProfiles -Clear -WhatIf                # Simula a limpeza da lista.
Set-MavenProfiles -Clear                       # Remove todos os perfis.
Set-MavenProfiles -Help
```

Os IDs dos perfis diferenciam maiusculas de minusculas. Passe varios IDs como
um array do PowerShell, nao como uma unica string separada por virgulas.
O comando preserva as demais configuracoes e atualiza `maven.profiles` em
[Modules/java/config.json](Modules/java/config.json):

```json
{
	"maven": {
		"profiles": ["dev", "integration"]
	}
}
```

Com essa configuração, `runMvn clean verify` passa
`clean verify -Pdev,integration` ao Maven. Uma configuração de perfis vazia ou
ausente não adiciona argumentos. Alteracoes feitas com `Set-MavenProfiles`
entram em vigor imediatamente. Apos editar o JSON manualmente, importe
novamente o modulo com `-Force`.

## Publicar um arquivo no Service Bus

Compatível com Windows PowerShell 5.1 e PowerShell 7; não requer módulo nem CLI do Azure.
Importe o módulo a partir deste diretório:

```powershell
Import-Module .\Modules\azure-event-hub\azure-event-hub.psm1 -Force

# String de conexão direta (use uma variável obtida de forma segura, não um segredo literal).
publishEvt -BindingDefinition $connectionString -FilePath .\message.json -ContentType application/json

# Variável de ambiente padrão: SERVICEBUS_CONNECTION_STRING.
publishEvt -FilePath .\message.json -ContentType application/json

# Variável de ambiente personalizada; informe uma fila para strings de conexão no nível do namespace.
publishEvt -EnvironmentVariableName MY_SERVICEBUS_CONNECTION -QueueName orders -FilePath .\message.json

# Lê AZURE_SERVICE_BUS_CONNECTION_STRING de um arquivo .env.
publishEvt -DotEnvPath .\.env -FilePath .\message.json -ContentType application/json

# Valida as entradas sem publicar.
publishEvt -FilePath .\message.json -WhatIf
```

A definição de vínculo é uma string de conexão com chave SAS neste formato:

```text
Endpoint=sb://<namespace>.servicebus.windows.net/;SharedAccessKeyName=<send-policy>;SharedAccessKey=<key>;EntityPath=<queue>
```

Para usar `-DotEnvPath`, defina a propriedade a seguir no arquivo selecionado:

```dotenv
AZURE_SERVICE_BUS_CONNECTION_STRING="Endpoint=sb://<namespace>.servicebus.windows.net/;SharedAccessKeyName=<send-policy>;SharedAccessKey=<key>;EntityPath=<queue>"
```

Essa opção é explícita: arquivos `.env` não são carregados automaticamente. São aceitos
valores de uma linha sem aspas, entre aspas simples ou entre aspas duplas, além do prefixo
opcional `export` e de comentários no fim da linha (separados por espaços em branco quando
o valor não estiver entre aspas). Os valores não são expandidos nem executados, e as
variáveis de ambiente não são modificadas. Use apenas uma fonte de conexão por chamada.
Mantenha fora do controle de versão os arquivos `.env` que contenham segredos.

Use uma política com permissão **Send**. A autenticação SAS/local deve estar habilitada.
`-ConnectionString` é um alias de `-BindingDefinition`. `-QueueName` é obrigatório
quando `EntityPath` não está definido e, se ambos forem informados, deve corresponder
ao valor de `EntityPath`.
O arquivo é enviado sem alterações como uma única mensagem, não como uma mensagem por
linha. O tipo de conteúdo padrão é `application/octet-stream`; para JSON, use
`-ContentType application/json`. Aplicam-se os limites de tamanho de mensagem do Service
Bus; arquivos grandes demais não são divididos. Erros de rede ou do serviço interrompem
a execução. A função não tenta reenviar as mensagens automaticamente: após um timeout,
a mensagem talvez já tenha sido aceita. Verifique o status antes de enviar novamente
para evitar duplicatas.


## Prompt Git (FancyGit-Pwsh)

Prompt com informações do Git inspirado no
[fancy-git](https://github.com/diogocavilha/fancy-git), sem depender de Oh My
Posh, Starship ou posh-git. Importar o módulo já ativa o prompt: se Oh My Posh
ou Starship estiver ativo, um aviso é exibido e o prompt atual é preservado.
`Disable-FancyGitPrompt` restaura o prompt anterior.

```powershell
Import-Module .\Modules\FancyGit-Pwsh\FancyGit-Pwsh.psm1 -Force

fancygit theme darcula        # Temas: FancyGit-Pwsh\themes\*.psd1
fancygit option UseColor true
fancygit enable aliases       # Instala os aliases do Git (gs, ga, gcm, ...)
fancygit help
```

Temas novos são arquivos `.psd1` na pasta `themes` do módulo e devem ser salvos
como UTF-8 com BOM. Os aliases `gcm`, `gps`, `gl` e `gu` colidem com aliases
internos do PowerShell (ReadOnly, AllScope) e são ignorados com aviso; para
usá-los, remova os aliases internos no perfil antes de habilitar os aliases do
FancyGit.

## Instalação

Clone o repositório e execute o instalador:

```powershell
git clone <url-do-repositorio>
cd powershell-modules

# Menu interativo com caixas de seleção.
.\install.ps1

# Sem menu (inclusive para automação): todos os módulos ou apenas os informados.
.\install.ps1 -All
.\install.ps1 -Modules java,azure-event-hub

# Simula a instalação sem gravar nada.
.\install.ps1 -All -WhatIf
```

Se a política de execução bloquear os scripts, desbloqueie os arquivos antes
(veja [Some snippets](#some-snippets)).

O instalador copia os módulos selecionados para o diretório padrão de módulos
do usuário atual e importa-os pelo perfil (`$PROFILE.CurrentUserAllHosts`), em
todos os hosts. A instalação é idempotente; execute novamente para atualizar os
módulos instalados após alterações. Use `-ModulePath` para selecionar outro
diretório. Abra uma nova sessão do PowerShell para carregar os módulos.

O instalador exibe um menu com caixas de selecao. Use as setas para cima/baixo
para navegar, Espaco para marcar um modulo ou **All**, Enter para instalar e Esc
para cancelar sem alteracoes. Selecione pelo menos um modulo. Apenas os modulos
selecionados sao copiados e incluidos no bloco gerenciado do perfil; arquivos
instalados anteriormente nao sao removidos. Arquivos `config.json` existentes
sao preservados.

O menu exige um terminal interativo. Use `-All` ou `-Modules` quando a entrada
ou a saida estiver redirecionada. Essas duas opcoes nao podem ser combinadas.

### Configuração por módulo

- **java**: registre os JDKs instalados com `Set-JdkPath` (ex.:
  `Set-JdkPath -Version 25 -Path 'C:\Program Files\Java\jdk-25'`) e,
  opcionalmente, os perfis Maven com `Set-MavenProfiles`. As alterações são
  gravadas no `config.json` ao lado do módulo instalado e preservadas entre
  reinstalações.
- **FancyGit-Pwsh**: nenhuma configuração inicial — o prompt é ativado ao
  importar o módulo. Personalize com `fancygit theme <nome>` e
  `fancygit enable aliases`.
- **azure-event-hub**: defina a variável de ambiente
  `SERVICEBUS_CONNECTION_STRING` (ou informe a string de conexão em cada
  chamada de `publishEvt`).

Sem instalar, importe qualquer módulo diretamente do repositório:
`Import-Module .\Modules\<nome>\<nome>.psm1 -Force`.

## Some snippets

```powershell
# Exibe o caminho do arquivo de perfil
Write-Output $profile

# Exibe o caminho do arquivo de perfil alterado pelo install.ps1
Write-Output $PROFILE.CurrentUserAllHosts
```

```powershell
# Define todos os scripts deste repositório como confiáveis
Get-ChildItem -Path "." -Recurse -Include *.ps1, *.psm1, *.psd1 | Unblock-File
```
