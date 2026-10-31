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

## Gastos del mes

Si en el Mac está el cerebro de Moni (`~/.config/companero/token`), el widget añade una sección «Gastos del mes»: lo gastado de verdad (APIs, suscripciones y luz), lo previsto a fin de mes, el gasto de las APIs frente al presupuesto y los tokens del mes de Claude Code, Codex, Hermes y cada API. Lo lee de `http://127.0.0.1:8765/gastos`, sin salir del Mac. Clic derecho › «Abrir panel de gastos» abre el panel completo.

## Datos

Lee el uso con las credenciales de Claude Code guardadas en el Llavero o, opcionalmente, con la cookie `sessionKey` de claude.ai (clic derecho › Configurar sessionKey). Ninguna credencial sale del Mac salvo hacia los servidores de Anthropic.
