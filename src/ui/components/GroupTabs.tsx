import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import { computed, type UINode } from "ts-native-ui";
import {
  selectAllAccounts,
  selectWorkAccounts,
  selectedGroup,
} from "../../state/app-state";

// RN (AccountList.filterChip): pilula; a ativa inverte para fundo claro e texto escuro.
// A classe TEM que ser um Signal — string derivada no corpo do componente congela.
const allTabClass = computed(() =>
  selectedGroup.get() === "All" ? "group-tab group-tab-active" : "group-tab",
);
const workTabClass = computed(() =>
  selectedGroup.get() === "Work" ? "group-tab group-tab-active" : "group-tab",
);

export function GroupTabs(): UINode {
  return (
    <div id="group-tabs">
      <button id="group-all" className={allTabClass} value="All" onClick={selectAllAccounts} />
      <button id="group-work" className={workTabClass} value="Work" onClick={selectWorkAccounts} />
    </div>
  );
}
