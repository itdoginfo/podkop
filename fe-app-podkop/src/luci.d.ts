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

  const _ = (_key: string) => string;

  const ui = {
    showModal: (_title: stirng, _content: HtmlElement) => undefined,
    hideModal: () => undefined,
    addNotification: (
      _title: string,
      _children: HtmlElement | HtmlElement[],
      _className?: string,
    ) => undefined,
  };
}

export {};
