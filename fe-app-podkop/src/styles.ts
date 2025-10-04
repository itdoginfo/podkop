// language=CSS
export const GlobalStyles = `
.cbi-value {
    margin-bottom: 10px !important;
}

#diagnostics-status .table > div {
    background: var(--background-color-primary);
    border: 1px solid var(--border-color-medium);
    border-radius: var(--border-radius);
}

#diagnostics-status .table > div pre,
#diagnostics-status .table > div div[style*="monospace"] {
    color: var(--color-text-primary);
}

#diagnostics-status .alert-message {
    background: var(--background-color-primary);
    border-color: var(--border-color-medium);
}

#cbi-podkop:has(.cbi-tab-disabled[data-tab="basic"]) #cbi-podkop-extra {
    display: none;
}
`;
