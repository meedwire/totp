import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import { Link, type Signal, type UINode } from "ts-native-ui";
import {
  getAccountInitials,
  getAccountTone,
  type TotpAccount,
} from "../../domain/accounts";
import { copyPrimaryCode } from "../../state/app-state";

// Espelha src/components/TOTPCode.tsx do RN apos o refactor monocromatico:
// avatar 30px em cinza, issuer/conta a esquerda, codigo alinhado a direita numa
// coluna de 84px, trilha de 40x3 e botao "..." no lugar do antigo link "Edit".
//
// Todo valor que muda por segundo chega como Signal (code, remaining e as tres
// classes de urgencia). Derivar essas strings aqui dentro congelaria a tela — o
// compilador so torna reativa a expressao JSX que contem `.get()` literalmente.
export function AccountCard(props: {
  account: TotpAccount;
  code: Signal<string>;
  remaining: Signal<string>;
  codeClass: Signal<string>;
  fillClass: Signal<string>;
  valueClass: Signal<string>;
}): UINode {
  const tone = getAccountTone(props.account);
  const initials = getAccountInitials(props.account);
  return (
    <section id={props.account.id} className="account-card">
      <button
        id={props.account.id + "-copy"}
        className="account-copy-area"
        value=""
        onClick={copyPrimaryCode}
      >
        <span id={props.account.id + "-avatar"} className={"account-avatar tone-" + tone}>{initials}</span>
        <span className="account-meta">
          <span id={props.account.id + "-issuer"} className="account-issuer">{props.account.issuer}</span>
          <span id={props.account.id + "-name"} className="account-name">{props.account.accountName}</span>
        </span>
        <span className="account-code-block">
          <span id={props.account.id + "-code"} className={props.codeClass}>
            {props.code}
          </span>
          <span className="timer-row">
            <span className="timer-track">
              <span id={props.account.id + "-timer-fill"} className={props.fillClass} />
            </span>
            <span id={props.account.id + "-timer-value"} className={props.valueClass}>
              {props.remaining}
            </span>
          </span>
        </span>
      </button>
      {/* RN usa "•••"; o atlas assado nao tem o bullet, entao ASCII. */}
      <Link id={props.account.id + "-edit"} className="card-menu" href="/edit">
        ...
      </Link>
    </section>
  );
}
