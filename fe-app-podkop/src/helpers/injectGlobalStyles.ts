import { GlobalStyles } from '../styles';

export function injectGlobalStyles() {
  document.head.insertAdjacentHTML(
    'beforeend',
    `
        <style>
          ${GlobalStyles}
        </style>
    `,
  );
}
