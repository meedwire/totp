/// <reference path="../native-ts-compiler/packages/native-types/index.d.ts" />

declare namespace JSX {
  type Element = import("ts-native-ui").UINode;
  interface IntrinsicElements {
    [elementName: string]: any;
  }
}

declare module "*.css" {
  const css: string;
  export default css;
}

declare module "ts-native-ui" {
  export type Href = string;
  export type Pathname = string;
  export type RouterParams = Record<string, string>;
  export type UINode = UIElement | UIFragment | string | number | Signal<unknown>;

  export interface UIElement {
    readonly kind: "element";
  }

  export interface UIFragment {
    readonly kind: "fragment";
  }

  export interface Signal<T> {
    get(): T;
    set(value: T): void;
    update(updater: (value: T) => T): void;
    subscribe(listener: (value: T) => void): () => void;
  }

  export interface UIPointerEvent {
    readonly type: "click" | "press";
    readonly x: number;
    readonly y: number;
    readonly target: UIElement;
    readonly currentTarget: UIElement;
  }

  export type UIEventHandler = (event: UIPointerEvent) => unknown;

  export interface UIProps {
    children?: UINode | UINode[] | null | undefined | boolean;
    id?: string;
    className?: string;
    value?: string | number | Signal<unknown>;
    onClick?: UIEventHandler;
    onPress?: UIEventHandler;
  }

  export interface LinkProps extends UIProps {
    href: Href;
    replace?: boolean;
    preload?: boolean;
  }

  export function signal<T>(initialValue: T): Signal<T>;
  export function push(pathname: Pathname): void;
  export function back(): void;
  export function usePathname(): Pathname;
  export function Link(props: LinkProps): UINode;
}

declare module "ts-native-ui/jsx-runtime" {
  import type { UINode } from "ts-native-ui";

  export namespace JSX {
    type Element = UINode;
    interface IntrinsicElements {
      [elementName: string]: any;
    }
  }

  export function Fragment(props?: { children?: UINode | UINode[] | null | undefined | boolean }): UINode;
  export function jsx(type: unknown, props: Record<string, unknown> | null, key?: unknown): UINode;
  export function jsxs(type: unknown, props: Record<string, unknown> | null, key?: unknown): UINode;
}
