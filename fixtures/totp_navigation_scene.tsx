import { console } from "native:console";
import { Fragment, jsx, jsxs } from "ts-native-ui/jsx-runtime";
import { push, usePathname, type UINode } from "ts-native-ui";
import { describeScene } from "ts-native-ui-test/scene-api";

function NavigationProbe(): UINode {
  const pathname = usePathname();
  return (
    <div id="nav-root">
      <button id="go-add" value="Add" onClick={goAdd} />
      <button id="go-settings" value="Prefs" onClick={goSettings} />
      <span id="pathname">{pathname}</span>
    </div>
  );
}

function goAdd(): void {
  push("/add");
}

function goSettings(): void {
  push("/settings");
}

describeScene("TotpNavigationScene", scene => {
  scene.env({
    platform: "android",
    viewport: { width: 220, height: 80, density: 1 },
    backend: "software-reference",
    inset: 0,
  });

  scene.css(`
    #nav-root {
      display: flex;
      flex-direction: row;
      width: 220px;
      height: 80px;
      background-color: #0b0d10;
    }
    #go-add, #go-settings {
      width: 70px;
      height: 36px;
      background-color: #2563eb;
      color: #ffffff;
      font-size: 12px;
      line-height: 18px;
    }
    #pathname {
      width: 80px;
      height: 36px;
      color: #f5f7fb;
      font-size: 12px;
      line-height: 18px;
    }
  `);

  scene.root(() => <NavigationProbe />);
  scene.expectText("#pathname").toHaveLines([{ text: "/", height: 18 }]);
  scene.action("navigate add", action => {
    action.click("#go-add");
    action.expectDispatch().toMatch({ handled: true, handler: "onClick", target: "#go-add", currentTarget: "#go-add" });
    action.expectText("#pathname").toHaveLines([{ text: "/add", height: 18 }]);
  });
});

console.log("TS_NATIVE_TOTP_NAVIGATION_SCENE_DONE");
