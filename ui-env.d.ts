/// <reference path="../native-ts-compiler/packages/native-types/index.d.ts" />

declare namespace JSX {
  interface Element {}
  interface IntrinsicElements {
    [elementName: string]: any;
  }
}

declare module "ts-native-ui/jsx-runtime" {
  export const Fragment: any;
  export function jsx(...args: any[]): any;
  export function jsxs(...args: any[]): any;
}

declare module "*.css" {
  const css: string;
  export default css;
}
