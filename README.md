# Uso de Claude

Widget flotante para macOS que muestra el consumo del plan de Claude (sesión de 5 horas y semanal), con una mascota que cambia de humor según lo que queda. Sigue al monitor en el que estás trabajando y se actualiza solo desde este repositorio.

## Instalar (una vez por Mac)

```
curl -fsSL https://raw.githubusercontent.com/jorgemoraz/claude-usage-widget/main/instalar.sh | bash
```

Requiere las Command Line Tools de Xcode (`xcode-select --install`).

## Desinstalar

```
curl -fsSL https://raw.githubusercontent.com/jorgemoraz/claude-usage-widget/main/instalar.sh | bash -s -- desinstalar
```

## Cómo se actualiza

Cada 10 minutos el widget consulta el último commit de `main`. Si es nuevo, descarga ese `main.swift`, lo compila y se reinicia. Si la compilación falla, se queda la versión anterior y no lo reintenta hasta el siguiente commit. Registro en `~/Library/Logs/ClaudeUsage-update.log`.

## Datos

Lee el uso con las credenciales de Claude Code guardadas en el Llavero o, opcionalmente, con la cookie `sessionKey` de claude.ai (clic derecho › Configurar sessionKey). Ninguna credencial sale del Mac salvo hacia los servidores de Anthropic.
