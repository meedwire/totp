import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import type { UINode } from "ts-native-ui";
import {
  screensDigits6Class,
  screensDigits8Class,
  screensGoogleBlockClass,
  screensGoogleTabClass,
  screensManualBlockClass,
  screensManualTabClass,
  screensPeriod30Class,
  screensPeriod60Class,
  screensSelectGoogleMode,
  screensSelectManualMode,
  screensSelectUriMode,
  screensSetDigits6,
  screensSetDigits8,
  screensSetPeriod30,
  screensSetPeriod60,
  screensUriBlockClass,
  screensUriTabClass,
} from "../src/state/screens-state";

// Espelha src/screens/AddAccount.tsx do RN: tres modos (URI / Manual / Google),
// campo de grupo comum, e por modo os campos, segmentos e botoes.
//
// Os <input> ACEITAM digitacao: foco por toque, cursor, selecao por Shift+Seta e
// teclado nativo com IME, no macOS e no Android. As abas de modo e os segmentos de
// digitos/periodo continuam funcionando por signal.
export default function AddAccountPage(): UINode {
  return (
    <main id="add-page">
      <section className="screen-body">
        <div id="mode-switcher">
          <button id="mode-uri" className={screensUriTabClass} value="URI" onClick={screensSelectUriMode} />
          <button id="mode-manual" className={screensManualTabClass} value="Manual" onClick={screensSelectManualMode} />
          <button id="mode-google" className={screensGoogleTabClass} value="Google" onClick={screensSelectGoogleMode} />
        </div>

        <span className="field-label">GROUP</span>
        <input id="add-group" className="field-input" placeholder="Work, Personal, Finance..." />

        <section id="add-uri-block" className={screensUriBlockClass}>
          <span className="field-label">OTPAUTH:// URI</span>
          <input
            id="add-uri"
            className="field-input field-input-multiline"
            placeholder="otpauth://totp/Example:user@example.com?secret=..."
          />
          <span className="field-hint">Paste a standard TOTP URI from your service provider.</span>
          <button id="add-uri-submit" className="primary-button" value="Add account" />
        </section>

        <section id="add-manual-block" className={screensManualBlockClass}>
          <span className="field-label">ISSUER *</span>
          <input id="add-issuer" className="field-input" placeholder="GitHub, Google, AWS..." />

          <span className="field-label">ACCOUNT NAME</span>
          <input id="add-account-name" className="field-input" placeholder="user@example.com" />

          <span className="field-label">SECRET KEY *</span>
          <input id="add-secret" className="field-input" placeholder="JBSWY3DPEHPK3PXP" />

          <span className="field-label">DIGITS</span>
          <div className="segment-row">
            <button id="add-digits-6" className={screensDigits6Class} value="6" onClick={screensSetDigits6} />
            <button id="add-digits-8" className={screensDigits8Class} value="8" onClick={screensSetDigits8} />
          </div>

          <span className="field-label">PERIOD</span>
          <div className="segment-row">
            <button id="add-period-30" className={screensPeriod30Class} value="30s" onClick={screensSetPeriod30} />
            <button id="add-period-60" className={screensPeriod60Class} value="60s" onClick={screensSetPeriod60} />
          </div>

          <section id="add-preview">
            <span id="add-preview-label">PREVIEW</span>
            <span id="add-preview-code">000 000</span>
          </section>

          <button id="add-manual-submit" className="primary-button" value="Save account" />
        </section>

        <section id="add-google-block" className={screensGoogleBlockClass}>
          <section className="info-card">
            <span className="info-card-title">Google Authenticator import</span>
            <span className="info-card-text">
              Use a screenshot or image of the export QR, or paste the migration link directly.
            </span>
          </section>

          <button id="add-google-pick" className="secondary-button" value="Choose QR image" />

          <span className="field-label">MIGRATION URI</span>
          <input
            id="add-migration-uri"
            className="field-input field-input-multiline"
            placeholder="otpauth-migration://offline?data=..."
          />

          <span className="field-hint">Imports all compatible TOTP entries from the Google export.</span>
          <button id="add-google-submit" className="primary-button" value="Import accounts" />
        </section>
      </section>
    </main>
  );
}
