import { console } from "native:console";
import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import { signal } from "ts-native-ui";
import { describeScene } from "ts-native-ui-test/scene-api";
import { DEMO_ACCOUNTS } from "../src/domain/accounts";
import { AccountCard } from "../src/ui/totp-components";

describeScene("TotpAccountCardScene", scene => {
  scene.env({
    platform: "android",
    viewport: { width: 380, height: 120, density: 1 },
    backend: "software-reference",
    inset: 0,
    tolerance: 0.5,
  });

  // Copia do recorte de cartao de styles/components.css.
  scene.css(`
    .account-card { display: flex; flex-direction: row; align-items: center; width: 100%; height: 56px; padding: 10px 12px; box-sizing: border-box; border-radius: 14px; background-color: #151515; border-width: 1px; border-style: solid; border-color: #212121; }
    .account-copy-area { display: flex; flex-direction: row; align-items: center; flex: 1; height: 100%; padding: 0; box-sizing: border-box; background-color: transparent; color: #f5f5f5; }
    .account-avatar { display: block; width: 30px; height: 30px; border-radius: 8px; color: #f5f5f5; font-size: 13px; line-height: 30px; text-align: center; background-color: #232323; }
    .account-meta { display: flex; flex-direction: column; flex: 1; margin-left: 9px; margin-right: 6px; }
    .account-issuer { display: block; color: #f5f5f5; font-size: 13px; line-height: 17px; }
    .account-name { display: block; margin-top: 2px; color: #9ca3af; font-size: 10px; line-height: 14px; }
    .account-code-block { display: flex; flex-direction: column; align-items: flex-end; width: 84px; margin-right: 6px; }
    .account-code { display: block; width: 84px; color: #e5e5e5; font-size: 16px; line-height: 20px; text-align: right; }
    .account-code-urgent { color: #ef4444; }
    .timer-row { display: flex; flex-direction: row; align-items: center; justify-content: flex-end; width: 84px; height: 12px; margin-top: 4px; gap: 5px; }
    .timer-track { display: block; width: 40px; height: 3px; border-radius: 999px; background-color: #0b0b0b; }
    .timer-fill { display: block; width: 40px; height: 3px; border-radius: 999px; background-color: #e5e5e5; }
    .timer-fill-w4 { width: 4px; }
    .timer-fill-urgent { background-color: #ef4444; }
    .timer-value { display: block; color: #9ca3af; font-size: 9px; line-height: 12px; text-align: right; }
    /* Especificidade empata entre classes simples: a regra de ESTADO tem que vir
       DEPOIS da base, senao a base sobrescreve (foi o que aconteceu aqui). */
    .timer-value-urgent { color: #ef4444; }
    .card-menu { display: block; width: 22px; height: 22px; border-radius: 8px; background-color: #1c1c1c; color: #d4d4d4; font-size: 10px; line-height: 20px; text-align: center; }
  `);

  // Na cena os valores por segundo sao Signals fixos, so para casar com os goldens.
  // No app eles vem de computed() sobre nowMs — ver src/state/app-state.ts.
  //
  // Esta cena cobre o ESTADO DE URGENCIA (RN: remaining <= 5s pinta codigo, barra e
  // contador de vermelho). O estado normal esta coberto na cena da lista.
  const codeSignal = signal<string>("9428 7082");
  const remainingSignal = signal<string>("3s");
  const codeClassSignal = signal<string>("account-code account-code-urgent");
  const fillClassSignal = signal<string>("timer-fill timer-fill-w4 timer-fill-urgent");
  const valueClassSignal = signal<string>("timer-value timer-value-urgent");

  scene.root(() => (
    <AccountCard
      account={DEMO_ACCOUNTS[0]}
      code={codeSignal}
      remaining={remainingSignal}
      codeClass={codeClassSignal}
      fillClass={fillClassSignal}
      valueClass={valueClassSignal}
    />
  ));

  scene.expectLayout("#demo-rfc-sha1").toMatchBox({ x: 0, y: 0, width: 380, height: 56 });
  scene.expectText("#demo-rfc-sha1-code").toHaveLines([{ text: "9428 7082", height: 20 }]);
  scene.expectText("#demo-rfc-sha1-issuer").toHaveLines([{ text: "RFC 6238", height: 17 }]);
  // Inicial UNICA e em maiuscula, como o getInitials do RN.
  scene.expectText("#demo-rfc-sha1-avatar").toHaveLines([{ text: "R", height: 30 }]);
  scene.expectHitTest({ x: 28, y: 26 }).toBe("#demo-rfc-sha1-avatar");
  // A regra composta (.account-code.urgent) tem que vencer a base (.account-code).
  scene.expectComputedStyle("#demo-rfc-sha1-code").toMatch({ color: "#ef4444" });
  scene.expectComputedStyle("#demo-rfc-sha1-timer-value").toMatch({ color: "#ef4444" });
  scene.expectComputedStyle("#demo-rfc-sha1-timer-fill").toMatch({ backgroundColor: "#ef4444", width: 4 });
});

console.log("TS_NATIVE_TOTP_ACCOUNT_CARD_SCENE_DONE");
