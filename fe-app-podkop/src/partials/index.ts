import { styles as ButtonStyles } from './button/styles';
import { styles as ModalStyles } from './modal/styles';

export * from './button/renderButton';
export * from './modal/renderModal';

export const PartialStyles = `
${ButtonStyles}
${ModalStyles}
`;
