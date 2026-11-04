# Módulos do PowerShell

## Módulos e funções exportadas

Importe deste diretório o módulo necessário. O módulo Java exporta:

- `Import-DotEnv`: Lê as atribuições compatíveis de um arquivo `.env` e as retorna como strings `nome=valor`. Não modifica o ambiente.
- `Set-JdkPath`: Adiciona ou atualiza o caminho de um JDK em `java\config.json`; use `-Remove` para remover uma versão.
- `runMvn`: Executa o Maven e, quando presente, seleciona o JDK configurado em `java.version` no `pom.xml` do diretório atual.
- `runApp`: Compila o projeto com `mvn clean package -Pazure` e, em seguida, executa o único arquivo JAR do projeto usando o JDK configurado. Carrega os valores de `.env` para o processo filho e restaura o ambiente do processo atual depois da execução.

O módulo Service Bus exporta `publishEvt`, que publica um arquivo como uma única mensagem em uma fila do Azure Service Bus.

### Java e Maven

Neste diretório, importe o módulo e execute seus comandos a partir do diretório de um projeto Maven:

```powershell
Import-Module .\java\java.psm1 -Force

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

## Publicar um arquivo no Service Bus

Compatível com Windows PowerShell 5.1 e PowerShell 7; não requer módulo nem CLI do Azure.
Importe o módulo a partir deste diretório:

```powershell
Import-Module .\event-hub\event-hub.psm1 -Force

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


## Perfil do PowerShell

```powershell
# Exibe o caminho do arquivo de perfil
Write-Output $profile
```
