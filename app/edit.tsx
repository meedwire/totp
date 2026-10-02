import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import type { UINode } from "ts-native-ui";

// Espelha src/screens/EditAccount.tsx do RN. O segredo TOTP nao aparece aqui de
// proposito — a tela so renomeia, reagrupa ou apaga.
export default function EditAccountPage(): UINode {
  return (
    <main id="edit-page">
      <section className="screen-body">
        <span className="field-label">ISSUER *</span>
        <input id="edit-issuer" className="field-input" placeholder="GitHub, Google, AWS..." />

        <span className="field-label">ACCOUNT NAME</span>
        <input id="edit-account-name" className="field-input" placeholder="user@example.com" />

        <span className="field-label">GROUP</span>
        <input id="edit-group" className="field-input" placeholder="Work, Personal, Finance..." />

        <span className="field-hint field-hint-strong">
          The TOTP secret stays unchanged. Use this screen to rename, regroup or delete the entry.
        </span>

        <button id="edit-save" className="primary-button" value="Save changes" />
        <button id="edit-delete" className="danger-button" value="Delete account" />
      </section>
    </main>
  );
}
