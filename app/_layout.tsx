import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import { Link, usePathname, type UINode } from "ts-native-ui";

type LayoutProps = {
  children: UINode;
};

function titleFromPath(pathname: string): string {
  if (pathname === "/add") return "Add Account";
  if (pathname === "/edit") return "Manage Account";
  if (pathname === "/settings") return "Settings";
  return "Accounts";
}

// RN (App.tsx): container com respiro de 10px e um shell arredondado de 24 que
// recorta a tela inteira. A lista de contas traz o proprio cabecalho (AppHeader);
// as telas secundarias usam o cabecalho Back | titulo | espacador, que os tres
// arquivos do RN (AddAccount/EditAccount/Settings) declaram identico.
export default function RootLayout(props: LayoutProps): UINode {
  const pathname = usePathname();
  return (
    <div id="totp-app">
      <div id="totp-shell">
        {pathname === "/" ? null : (
          <section id="top-strip">
            <Link id="route-back" className="back-button" href="/">
              Back
            </Link>
            <span id="route-title">{titleFromPath(pathname)}</span>
            <span id="route-spacer" />
          </section>
        )}
        {pathname === "/" ? null : <div className="rule" />}
        {props.children}
      </div>
    </div>
  );
}
