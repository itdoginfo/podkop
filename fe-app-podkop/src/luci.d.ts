type HtmlTag = keyof HTMLElementTagNameMap;

type HtmlElement<T extends HtmlTag> = HTMLElementTagNameMap[T];

type HtmlAttributes<T extends HtmlTag = 'div'> = Partial<
  Omit<HtmlElement<T>, 'style' | 'children'> & {
    style?: string | Partial<CSSStyleDeclaration>;
    class?: string;
    onclick?: (event: MouseEvent) => void;
  }
>;

declare global {
  const fs: {
    exec(
      command: string,
      args?: string[],
      env?: Record<string, string>,
    ): Promise<{
      stdout: string;
      stderr: string;
      code?: number;
    }>;
  };

  const E: <T extends HtmlTag>(
    type: T,
    attr?: HtmlAttributes<T> | null,
    children?: (Node | string)[] | Node | string,
  ) => HTMLElementTagNameMap[T];

  const uci: {
    load: (packages: string | string[]) => Promise<string>;
    sections: (conf: string, type?: string, cb?: () => void) => Promise<T>;
  };
}

export {};
