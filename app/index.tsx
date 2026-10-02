import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import type { UINode } from "ts-native-ui";
import { AccountListPreview, AppHeader, GroupTabs } from "../src/ui/components";
import { armClock } from "../src/state/app-state";

// Espelha src/screens/AccountList.tsx do RN: cabecalho, busca, chips de grupo e a
// lista. O RN nao tem barra de status — o retorno de "copiado" la e silencioso —
// entao o StatusBar do porte saiu junto com o botao Refresh (o relogio agora e real).
export default function AccountListPage(): UINode {
  armClock();
  return (
    <main id="account-list-page">
      <AppHeader />
      <div className="rule" />
      <section id="search-placeholder">
        {/* O RN pinta um "⌕" antes do placeholder. O atlas A8 assado nao tem esse
            glifo (sai como "?"), entao aqui fica so o recuo equivalente. */}
        <span id="search-label">Search accounts...</span>
      </section>
      <GroupTabs />
      <AccountListPreview />
    </main>
  );
}
