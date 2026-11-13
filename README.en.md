# PowerShell Modules

## Modules and exported functions

Import the module you need from this directory. The Java module exports:

- `Import-DotEnv`: Reads supported assignments from a `.env` file and returns them as `name=value` strings. It does not modify the environment.
- `Set-JdkPath`: Adds or updates a JDK path in `java\config.json`; use `-Remove` to remove a version.
- `Set-MavenProfiles`: Lists or changes the Maven profiles activated automatically by `runMvn`; changes are saved and applied immediately.
- `runMvn`: Runs Maven, selecting the configured JDK from `java.version` in the current directory's `pom.xml` when present.
- `runApp`: Builds the project with `mvn clean package -Pazure`, then runs its single JAR using the configured JDK. It loads `.env` values for the child process and restores the current process environment afterward.

The Service Bus module exports `publishEvt`, which publishes a file as one Azure Service Bus queue message.

Each exported function accepts `-Help` to display its summary and parameter descriptions. You can also use PowerShell's help command, for example:

```powershell
runApp -Help
Get-Help runApp -Full
publishEvt -Help
```

### Java and Maven

From this directory, import the module and call its commands from a Maven project directory:

```powershell
Import-Module .\java\java.psm1 -Force

# Inspect parsed .env assignments without setting process environment variables.
Import-DotEnv -Path .\.env

# Run Maven using the JDK version declared in this project's pom.xml.
runMvn clean verify

# Build with the azure profile and run the project's single JAR.
runApp

# Add or update the JDK path for a Java version.
Set-JdkPath -Version 25 -Path 'C:\Program Files\Java\jdk-25'

# Remove a version from the JDK map.
Set-JdkPath -Version 11 -Remove
```

`Set-JdkPath` requires the specified directory to exist. Use `-WhatIf` to preview
a change without saving it.

`runMvn` and `runApp` require Maven on `PATH`. JDK selection is configured in
`java.psm1`; the selected JDK must exist on this machine. For automatic
selection, the project `pom.xml` must define `java.version` as a configured
version. `runApp` reads optional `JAVA_OPTS` and `APP_ARGS` values from the
process environment or the project's `.env` file.

Manage automatically activated Maven profiles with `Set-MavenProfiles`:

```powershell
Set-MavenProfiles                              # List configured profiles.
Set-MavenProfiles -Profiles dev,integration     # Replace the list.
Set-MavenProfiles -Profiles qa -Add             # Add without duplicates.
Set-MavenProfiles -Profiles integration -Remove
Set-MavenProfiles -Clear -WhatIf                # Preview clearing the list.
Set-MavenProfiles -Clear                       # Clear all profiles.
Set-MavenProfiles -Help
```

Profile IDs are case-sensitive. Pass multiple IDs as a PowerShell array, not a
single comma-separated string. The command preserves unrelated configuration
and updates `maven.profiles` in [Modules/java/config.json](Modules/java/config.json):

```json
{
	"maven": {
		"profiles": ["dev", "integration"]
	}
}
```

With this configuration, `runMvn clean verify` passes
`clean verify -Pdev,integration` to Maven. An empty or missing profiles setting
adds no arguments. Changes made with `Set-MavenProfiles` take effect immediately.
After editing the JSON file manually, reimport the module with `-Force`.

## Publish a file to Service Bus

Compatible with Windows PowerShell 5.1 and PowerShell 7; no Azure module or CLI required.
Import the module from this directory:

```powershell
Import-Module .\azure-event-hub\azure-event-hub.psm1 -Force

# Direct connection string (use a securely obtained variable, not a literal secret).
publishEvt -BindingDefinition $connectionString -FilePath .\message.json -ContentType application/json

# Default environment variable: SERVICEBUS_CONNECTION_STRING.
publishEvt -FilePath .\message.json -ContentType application/json

# Custom environment variable; specify a queue for namespace-level connection strings.
publishEvt -EnvironmentVariableName MY_SERVICEBUS_CONNECTION -QueueName orders -FilePath .\message.json

# Read AZURE_SERVICE_BUS_CONNECTION_STRING from a .env file.
publishEvt -DotEnvPath .\.env -FilePath .\message.json -ContentType application/json

# Validate inputs without publishing.
publishEvt -FilePath .\message.json -WhatIf
```

The binding definition is a SAS-key connection string in this format:

```text
Endpoint=sb://<namespace>.servicebus.windows.net/;SharedAccessKeyName=<send-policy>;SharedAccessKey=<key>;EntityPath=<queue>
```

For `-DotEnvPath`, define the following property in the selected file:

```dotenv
AZURE_SERVICE_BUS_CONNECTION_STRING="Endpoint=sb://<namespace>.servicebus.windows.net/;SharedAccessKeyName=<send-policy>;SharedAccessKey=<key>;EntityPath=<queue>"
```

This option is explicit: `.env` files are not loaded automatically. Single-line
unquoted, single-quoted, and double-quoted values are supported, as are an optional
`export` prefix and inline comments (separated by whitespace for unquoted values).
Values are not expanded or executed, and environment variables are not modified.
Use only one connection source per invocation. Keep `.env` files containing secrets
out of source control.

Use a policy with **Send** permission. SAS/local authentication must be enabled.
`-ConnectionString` is an alias for `-BindingDefinition`. `-QueueName` is required
when `EntityPath` is absent, and must match it when both are supplied.
The file is sent unchanged as one message, not one message per line. The default
content type is `application/octet-stream`; use `-ContentType application/json`
for JSON. Service Bus message size limits apply; oversized files are not split.
Network and service errors stop execution. Sends are not automatically retried
by the function: after a timeout the message may already have been accepted,
so verify before sending again to avoid duplicates.


## PowerShell profile

Run the installer from this repository to copy its modules into the current
user's default module directory and import them from your profile for every
host. The install is idempotent; rerun it to update the installed modules after
changing them. Use `-WhatIf` to preview the changes, then open a new PowerShell
session to load the modules. Pass `-ModulePath` to use a different module
directory.

```powershell
.\install.ps1
```

```powershell
# Display profile file location
Write-Output $profile
```
