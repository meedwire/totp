import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import type { UINode } from "ts-native-ui";
import {
  screensExportBlockClass,
  screensExportChevron,
  screensImportBlockClass,
  screensImportChevron,
  screensToggleExport,
  screensToggleImport,
} from "../src/state/screens-state";

// Espelha src/screens/Settings.tsx do RN: secao Backup com exportar/importar que
// abrem e fecham, cartao de dica do Google Authenticator, secao App e o botao de sair.
// Abrir e fechar ja funciona (signal + classe); os campos de senha ainda nao aceitam
// digitacao porque o framework nao tem evento de tecla.
export default function SettingsPage(): UINode {
  return (
    <main id="settings-page">
      <section className="screen-body">
        <span className="section-title">BACKUP</span>

        <section id="settings-export-item" className="menu-item" onClick={screensToggleExport}>
          <span className="menu-content">
            <span className="menu-label">Export backup</span>
            <span className="menu-hint">Save an encrypted copy of all accounts</span>
          </span>
          <span id="settings-export-chevron" className="menu-chevron">{screensExportChevron}</span>
        </section>

        <section id="settings-export-block" className={screensExportBlockClass}>
          <section className="expanded-section">
            <span className="field-label field-label-first">ENCRYPTION PASSWORD</span>
            <input id="settings-export-password" className="field-input" placeholder="Minimum 4 characters" />
            <button id="settings-export-run" className="primary-button" value="Export backup" />
          </section>
        </section>

        <section id="settings-import-item" className="menu-item" onClick={screensToggleImport}>
          <span className="menu-content">
            <span className="menu-label">Import backup</span>
            <span className="menu-hint">Restore accounts from an encrypted backup file</span>
          </span>
          <span id="settings-import-chevron" className="menu-chevron">{screensImportChevron}</span>
        </section>

        <section id="settings-import-block" className={screensImportBlockClass}>
          <section className="expanded-section">
            <span className="field-label field-label-first">DECRYPTION PASSWORD</span>
            <input id="settings-import-password" className="field-input" placeholder="Enter backup password" />
            <button id="settings-import-run" className="primary-button" value="Select file and import" />
          </section>
        </section>

        <section className="info-card">
          <span className="info-card-title">Google Authenticator</span>
          <span className="info-card-text">
            Open Add Account and switch to the Google tab to import an export QR image or a migration URI.
          </span>
        </section>

        <span className="section-title section-title-spaced">APP</span>

        <section className="about-card">
          <span className="about-name">TOTP Authenticator</span>
          <span className="about-version">Version 1.0.0</span>
          <span className="about-desc">Lightweight menu bar app for time-based authentication codes.</span>
        </section>

        <button id="settings-quit" className="danger-button" value="Quit application" />
      </section>
    </main>
  );
}
