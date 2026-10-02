import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import { Link, type UINode } from "ts-native-ui";

// RN (AccountList.emptyState): centralizado na area livre, sem cartao.
export function EmptyState(): UINode {
  return (
    <section id="empty-state">
      <h2 id="empty-title">No accounts yet</h2>
      <p id="empty-copy">
        Add accounts manually, paste an otpauth URI, or import a Google Authenticator export.
      </p>
      <Link id="empty-add" className="toolbar-button toolbar-button-primary" href="/add">
        Add your first account
      </Link>
    </section>
  );
}
