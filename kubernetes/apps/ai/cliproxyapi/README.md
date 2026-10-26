# cliproxyapi

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) serves the ChatGPT
subscription to `llm-gateway` as `chatgpt/*` models. Clients never call it
directly: they use their `llm-gateway` key, and the network policy admits only
the gateway.

## Login

Requests use the Sign in with ChatGPT (SIWC) partition of a Codex credential,
so a fresh volume needs two logins. Both run in the live pod and write to
`/data/auths`, which the proxy watches, so no restart is needed. The volume is
backed up by kopiur, so this is only for a lost credential.

1. Codex device login. Open the printed URL, enter the code, and wait for the
   credential file to be saved:

   ```sh
   kubectl -n ai exec -it deploy/cliproxyapi -- ./CLIProxyAPI -config /config/config.yaml -codex-device-login
   ```

2. Bind SIWC to that file (`ls /data/auths` for its name). Open the printed
   URL and sign in. The browser then fails to load `http://127.0.0.1:1455/...`;
   copy that whole URL from the address bar and paste it at the prompt, which
   appears after 15 seconds. You have 5 minutes.

   ```sh
   kubectl -n ai exec -it deploy/cliproxyapi -- ./CLIProxyAPI -config /config/config.yaml -no-browser -siwc-bind <file>.json
   ```
