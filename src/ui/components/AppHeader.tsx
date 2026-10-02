import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import { Link, type UINode } from "ts-native-ui";

// RN (AccountList.header): tres colunas — Prefs a esquerda, titulo ao centro,
// Add a direita, com uma regua de 1px embaixo.
//
// NAO devolver Fragment com 2+ nos aqui. Um Fragment filho de container flex e
// tratado como UM item flex (nao e transparente): os filhos empilham dentro de um
// slot so e o PRIMEIRO descendente e forcado a altura do grupo inteiro — era isso
// que fazia o cabecalho medir 59 com `height: 58`. A regua e irma direta, em
// app/index.tsx.
export function AppHeader(): UINode {
  return (
    <section id="totp-header">
      <Link id="settings-link" className="toolbar-button" href="/settings">
        Prefs
      </Link>
      <span id="totp-title">Authenticator</span>
      <Link id="add-link" className="toolbar-button toolbar-button-primary" href="/add">
        Add
      </Link>
    </section>
  );
}
