// language=CSS
export const styles = `
#cbi-netshift-manager-_mount_node > div {
    width: 100%;
}

#cbi-netshift-manager > h3 {
    display: none;
}

.pdk_manager-page {
    width: 100%;
}

.pdk_manager-page__components {
    display: grid;
    grid-template-columns: repeat(2, minmax(240px, 1fr));
    grid-gap: 10px;
}

@media (max-width: 760px) {
    .pdk_manager-page__components {
        grid-template-columns: 1fr;
    }
}

.pdk_manager-page__component {
    display: grid;
    grid-template-columns: 1fr;
    grid-row-gap: 10px;
}

.pdk_manager-page__component__header {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, auto);
    align-items: start;
    gap: 8px;
    min-width: 0;
}

.pdk_manager-page__component__title {
    color: var(--text-color-high);
    line-height: 1.25;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.pdk_manager-page__component__status {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 6px;
    min-width: 0;
    max-width: 180px;
    overflow: hidden;
}

.pdk_manager-page__component__version {
    display: grid;
    grid-template-columns: auto 1fr;
    grid-column-gap: 6px;
    align-items: baseline;
    min-width: 0;
}

.pdk_manager-page__component__version__label {
    color: var(--text-color-medium);
}

.pdk_manager-page__component__version__value {
    min-width: 0;
    overflow-wrap: anywhere;
}

.pdk_manager-page__component__tag {
    flex: 0 0 auto;
    padding: 2px 5px;
    border: 1px var(--background-color-high, gray) solid;
    border-radius: 4px;
    color: var(--text-color-medium, gray);
    line-height: 1.2;
}

.pdk_manager-page__component__tag--success {
    border-color: var(--success-color-medium, green);
    color: var(--success-color-medium, green);
}

.pdk_manager-page__component__tag--warning {
    border-color: var(--warn-color-medium, orange);
    color: var(--warn-color-medium, orange);
}

.pdk_manager-page__component__actions {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
}

.pdk_manager-page__component__actions > .pdk-partial-button {
    margin-left: 0;
}
`;
