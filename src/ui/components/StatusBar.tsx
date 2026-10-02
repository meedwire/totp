import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import type { UINode } from "ts-native-ui";
import { advanceClock, statusMessage } from "../../state/app-state";

export function StatusBar(): UINode {
  return (
    <section id="status-bar">
      <span id="status-label">{statusMessage}</span>
      <button id="refresh-codes" className="toolbar-button" value="Refresh" onClick={advanceClock} />
    </section>
  );
}
