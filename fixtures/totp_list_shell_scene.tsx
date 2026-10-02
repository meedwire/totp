import { console } from "native:console";
import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import { describeScene } from "ts-native-ui-test/scene-api";
import AccountListPage from "../app/index";
import { freezeClockForTest } from "../src/state/app-state";

// AccountListPage chama armClock() no render: sem congelar, a cena pegaria o relogio
// de parede (golden mutavel) e o setInterval pendente seguraria o processo vivo.
freezeClockForTest(45000);

describeScene("TotpListShellScene", scene => {
  scene.env({
    platform: "android",
    viewport: { width: 380, height: 600, density: 1 },
    backend: "software-reference",
    inset: 0,
    tolerance: 0.5,
  });

  // Copia do CSS do app (styles/*.css) recortada para o que esta cena desenha.
  // Se divergir, o golden mente — mantenha em sincronia com styles/components.css.
  scene.css(`
    #account-list-page { display: flex; flex-direction: column; width: 100%; min-height: 480px; background-color: #050505; color: #f5f5f5; }
    .rule { display: block; width: 100%; height: 1px; background-color: #191919; }
    #totp-header { display: flex; flex-direction: row; align-items: center; justify-content: space-between; width: 100%; height: 58px; padding: 16px 18px 12px 18px; box-sizing: border-box; }
    #totp-title { display: block; color: #f5f5f5; font-size: 14px; line-height: 18px; text-align: center; }
    .toolbar-button { display: block; width: 54px; height: 30px; box-sizing: border-box; border-radius: 10px; background-color: #151515; border-width: 1px; border-style: solid; border-color: rgba(255,255,255,0.08); color: #d4d4d4; font-size: 11px; line-height: 28px; text-align: center; }
    .toolbar-button-primary { background-color: #e5e5e5; border-color: #e5e5e5; color: #090909; }
    #search-placeholder { display: flex; flex-direction: row; align-items: center; width: 100%; height: 38px; margin: 12px 18px 0 18px; box-sizing: border-box; border-radius: 10px; background-color: #101010; border-width: 1px; border-style: solid; border-color: #282828; }
    #search-label { display: block; flex: 1; margin-left: 12px; color: #5f5f5f; font-size: 12px; line-height: 18px; }
    #group-tabs { display: flex; flex-direction: row; align-items: center; width: 100%; height: 36px; margin: 8px 18px 0 18px; box-sizing: border-box; gap: 6px; }
    .group-tab { display: block; height: 28px; padding: 0 12px; box-sizing: border-box; border-radius: 999px; background-color: #151515; border-width: 1px; border-style: solid; border-color: rgba(255,255,255,0.08); color: #9ca3af; font-size: 11px; line-height: 26px; text-align: center; }
    .group-tab-active { background-color: #e5e5e5; border-color: #e5e5e5; color: #090909; }
    #account-list { display: flex; flex-direction: column; width: 100%; margin: 10px 18px 22px 18px; gap: 10px; }
    .account-card { display: flex; flex-direction: row; align-items: center; width: 100%; height: 56px; padding: 10px 12px; box-sizing: border-box; border-radius: 14px; background-color: #151515; border-width: 1px; border-style: solid; border-color: #212121; }
    .account-copy-area { display: flex; flex-direction: row; align-items: center; flex: 1; height: 100%; padding: 0; box-sizing: border-box; background-color: transparent; color: #f5f5f5; }
    .account-avatar { display: block; width: 30px; height: 30px; border-radius: 8px; color: #f5f5f5; font-size: 13px; line-height: 30px; text-align: center; background-color: #232323; }
    .account-meta { display: flex; flex-direction: column; flex: 1; margin-left: 9px; margin-right: 6px; }
    .account-issuer { display: block; color: #f5f5f5; font-size: 13px; line-height: 17px; }
    .account-name { display: block; margin-top: 2px; color: #9ca3af; font-size: 10px; line-height: 14px; }
    .account-code-block { display: flex; flex-direction: column; align-items: flex-end; width: 84px; margin-right: 6px; }
    .account-code { display: block; width: 84px; color: #e5e5e5; font-size: 16px; line-height: 20px; text-align: right; }
    .timer-row { display: flex; flex-direction: row; align-items: center; justify-content: flex-end; width: 84px; height: 12px; margin-top: 4px; gap: 5px; }
    .timer-track { display: block; width: 40px; height: 3px; border-radius: 999px; background-color: #0b0b0b; }
    .timer-fill { display: block; width: 40px; height: 3px; border-radius: 999px; background-color: #e5e5e5; }
    .timer-fill-w20 { width: 20px; }
    .timer-value { display: block; color: #9ca3af; font-size: 9px; line-height: 12px; text-align: right; }
    .card-menu { display: block; width: 22px; height: 22px; border-radius: 8px; background-color: #1c1c1c; color: #d4d4d4; font-size: 10px; line-height: 20px; text-align: center; }
  `);

  scene.root(() => <AccountListPage />);

  // 58 = o valor declarado. Chegou a medir 59 enquanto o AppHeader devolvia um
  // Fragment: Fragment filho de flex vira UM item e o primeiro descendente absorve a
  // altura do grupo. Com a regua como irma direta, a caixa volta ao correto.
  scene.expectLayout("#totp-header").toMatchBox({ x: 0, y: 0, width: 380, height: 58 });
  scene.expectText("#totp-title").toHaveLines([{ text: "Authenticator", height: 18 }]);
  scene.expectText("#group-all").toHaveLines([{ text: "All", height: 26 }]);
  scene.expectText("#group-work").toHaveLines([{ text: "Work", height: 26 }]);
  // Vetor RFC 6238 com 8 digitos em T=59s (freezeClockForTest(45000) -> counter 1).
  scene.expectText("#demo-rfc-sha1-code").toHaveLines([{ text: "9428 7082", height: 20 }]);
  // O RN so mostra o contador nos ultimos 10s. Em 15s restantes o computed devolve
  // string vazia e o no fica com largura zero — nao ha comando de texto para casar.
  scene.expectLayout("#demo-rfc-sha1-timer-value").toMatchBox({ x: 321, y: 199.5, width: 0, height: 9 });
  scene.expectHitTest({ x: 345, y: 24 }).toBe("#add-link");
});



console.log("TS_NATIVE_TOTP_LIST_SHELL_SCENE_DONE");
