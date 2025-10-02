// eslint.config.js
import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import prettier from 'eslint-config-prettier';

export default [
    js.configs.recommended,
    ...tseslint.configs.recommended,
    {
        ignores: ['dist', 'node_modules'],
    },
    {
        rules: {
            'no-console': 'warn',
        },
    },
    prettier,
];
