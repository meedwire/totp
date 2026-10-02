# TOTP

Autenticador de dois fatores (códigos TOTP/HOTP) escrito em TypeScript e compilado para código nativo pelo
[native-ts-compiler](https://github.com/meedwire/native-ts-compiler), com a UI em `ts-native-ui` (JSX + CSS).

A primeira versão era um app React Native. Ela foi substituída por esta, e o React Native saiu do projeto.

## Estrutura

| Caminho                          | O quê                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| `ui.tsx`, `ui-router.tsx`        | Entrada do app e rotas                                                               |
| `app/`                           | Telas: lista (`index`), adicionar, editar, configurações                             |
| `src/crypto/`                    | Base32, SHA-1, HMAC-SHA1 e TOTP/HOTP, sem dependências                               |
| `src/domain/`, `src/state/`      | Contas e estado das telas                                                            |
| `src/platform/`                  | Relógio por plataforma (`wall-clock.macos.ts`, `wall-clock.android.ts`)             |
| `src/ui/`, `app.css`, `styles/`  | Componentes e estilos                                                                |
| `fixtures/`                      | Cenas e contratos compilados pelo `scripts/check-ts-native-totp.ts`                  |
| `macos/`                         | Host macOS (CMake + Swift sobre a dylib do app, desenho via Metal)                   |
| `scripts/`                       | `check-ts-native-totp.ts` (fixtures) e `run-ts-native-totp.ts` (compila e abre)      |

## Requisitos

- O `native-ts-compiler` clonado ao lado deste repositório (`../native-ts-compiler`), ou o caminho dele em
  `NATIVE_TS_COMPILER_ROOT`. O `tsconfig.json`, os `.d.ts`, o `package.json` (workspaces) e o CMake apontam para lá.
- bun; no macOS, CMake ≥ 3.22 e Xcode.

## Uso

```bash
bun scripts/check-ts-native-totp.ts        # compila e executa as fixtures
bun scripts/run-ts-native-totp.ts --platform=macos   # compila o app, gera o .app e abre
```

## Estado (02/10/2026)

- **Fixtures:** a `totp_crypto_contract` compila e passa. A `totp_account_card_scene` não compila: há erros de tipo
  dentro dos pacotes do compilador (`ts-native-ui`, `ts-native-ui-web`, `ts-native-ui-layout`), no estado atual do
  ramo `feat/native-link-and-module-scope` do native-ts-compiler, e erros de JSX (TS7026) nos componentes do app.
  Era assim antes da saída do React Native.
- **Android:** o `run-ts-native-totp.ts --platform=android` espera um projeto em `android/`, que não está neste repositório.
