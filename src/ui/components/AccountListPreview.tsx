import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import type { UINode } from "ts-native-ui";
import { DEMO_ACCOUNTS } from "../../domain/accounts";
import {
  demoCode0, demoCode1, demoCode2,
  demoCodeClass0, demoCodeClass1, demoCodeClass2,
  demoFillClass0, demoFillClass1, demoFillClass2,
  demoRemaining0, demoRemaining1, demoRemaining2,
  demoValueClass0, demoValueClass1, demoValueClass2,
} from "../../state/app-state";
import { AccountCard } from "./AccountCard";

export function AccountListPreview(): UINode {
  return (
    <section id="account-list">
      <AccountCard
        account={DEMO_ACCOUNTS[0]}
        code={demoCode0}
        remaining={demoRemaining0}
        codeClass={demoCodeClass0}
        fillClass={demoFillClass0}
        valueClass={demoValueClass0}
      />
      <AccountCard
        account={DEMO_ACCOUNTS[1]}
        code={demoCode1}
        remaining={demoRemaining1}
        codeClass={demoCodeClass1}
        fillClass={demoFillClass1}
        valueClass={demoValueClass1}
      />
      <AccountCard
        account={DEMO_ACCOUNTS[2]}
        code={demoCode2}
        remaining={demoRemaining2}
        codeClass={demoCodeClass2}
        fillClass={demoFillClass2}
        valueClass={demoValueClass2}
      />
    </section>
  );
}
