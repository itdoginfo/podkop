// language=CSS
export const styles = `
#cbi-netshift-dashboard-_mount_node > div {
    width: 100%;
}

#cbi-netshift-dashboard > h3 {
    display: none;
}
    
.pdk_dashboard-page {
    width: 100%;
    --dashboard-grid-columns: 4;
}

@media (max-width: 900px) {
    .pdk_dashboard-page {
        --dashboard-grid-columns: 2;
    }
}

.pdk_dashboard-page__widgets-section {
    margin-top: 10px;
    display: grid;
    grid-template-columns: repeat(var(--dashboard-grid-columns), minmax(0, 1fr));
    grid-gap: 10px;
}

.pdk_dashboard-page__widgets-section__item {
}

.pdk_dashboard-page__widgets-section__item__title {}

.pdk_dashboard-page__widgets-section__item__row {}

.pdk_dashboard-page__widgets-section__item__row--success .pdk_dashboard-page__widgets-section__item__row__value {
    color: var(--success-color-medium, green);
}

.pdk_dashboard-page__widgets-section__item__row--error .pdk_dashboard-page__widgets-section__item__row__value {
    color: var(--error-color-medium, red);
}

.pdk_dashboard-page__widgets-section__item__row__key {}

.pdk_dashboard-page__widgets-section__item__row__value {}

.pdk_dashboard-page__sections-toolbar {
    margin-top: 10px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
}

.pdk_dashboard-page__sections-toolbar__title {
    color: var(--text-color-high);
    font-weight: 700;
}

.pdk_dashboard-page__outbound-section {
    margin-top: 10px;
}

.pdk_dashboard-page__outbound-section {
    min-width: 0;
}

.pdk_dashboard-page__outbound-section__title-section {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
}

.pdk_dashboard-page__outbound-section__title-section__title {
    color: var(--text-color-high);
    font-weight: 700;
}

.pdk_dashboard-page__outbound-grid {
    margin-top: 5px;
    display: grid;
    grid-template-columns: repeat(var(--dashboard-grid-columns), minmax(0, 1fr));
    grid-gap: 10px;
}

.pdk_dashboard-page__outbound-section__controls {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
}

/* A pressed toggle must not recolor the text: themes paint .btn with a solid
   primary background, so a primary-colored label would vanish. Mark it with a
   check and an outline in the current text color instead. */
.pdk_dashboard-page__control--on {
    font-weight: 700;
    outline: 2px solid currentColor;
    outline-offset: 1px;
}

.pdk_dashboard-page__control--on > span::before {
    content: '\\2713\\00a0';
}

.pdk_dashboard-page__outbound-list {
    margin-top: 5px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    max-height: 520px;
    overflow-y: auto;
    padding-right: 4px;
}

.pdk_dashboard-page__outbound-row {
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 12px;
    border: var(--ns-card-border-width) solid var(--ns-card-border);
    border-radius: 8px;
    transition: border 0.2s ease;
}

.pdk_dashboard-page__outbound-row--selectable {
    cursor: pointer;
}

.pdk_dashboard-page__outbound-row--selectable:hover {
    border-color: var(--primary-color-high, dodgerblue);
}

.pdk_dashboard-page__outbound-row--active {
    border-color: var(--success-color-medium, green);
}

.pdk_dashboard-page__outbound-row__name {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.pdk_dashboard-page__outbound-row__type {
    flex: none;
    font-size: 0.85em;
    padding: 1px 8px;
    border-radius: 6px;
    opacity: 0.75;
    border: var(--ns-card-border-width) solid var(--ns-card-border);
}

.pdk_dashboard-page__outbound-row__latency {
    margin-left: auto;
    flex: none;
}

.pdk_dashboard-page__outbound-row__badge,
.pdk_dashboard-page__outbound-row__badge-space {
    flex: none;
    width: 76px;
    text-align: center;
}

.pdk_dashboard-page__outbound-row__badge {
    font-size: 0.85em;
    padding: 2px 0;
    border-radius: 6px;
    color: var(--success-color-medium, green);
    border: var(--ns-card-border-width) solid var(--success-color-medium, green);
}

.pdk_dashboard-page__outbound-subgroup {
    margin-top: 15px;
    padding-top: 10px;
    border-top: var(--ns-card-border-width) solid var(--ns-card-border);
}

.pdk_dashboard-page__outbound-subgroup__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
}

.pdk_dashboard-page__outbound-subgroup__title {
    color: var(--text-color-high);
    font-weight: 600;
}

.pdk_dashboard-page__outbound-grid__item {
    transition: border 0.2s ease;
}

.pdk_dashboard-page__outbound-grid__item--selectable {
    cursor: pointer;
}

.pdk_dashboard-page__outbound-grid__item--selectable:hover {
    border-color: var(--primary-color-high, dodgerblue);
}

.pdk_dashboard-page__outbound-grid__item--active {
    border-color: var(--success-color-medium, green);
}

.pdk_dashboard-page__outbound-grid__item__footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-top: 10px;
}

.pdk_dashboard-page__outbound-grid__item__type {}

.pdk_dashboard-page__outbound-grid__item__latency--empty {
    color: var(--primary-color-low, lightgray);
}

.pdk_dashboard-page__outbound-grid__item__latency--green {
    color: var(--success-color-medium, green);
}

.pdk_dashboard-page__outbound-grid__item__latency--yellow {
    color: var(--warn-color-medium, orange);
}

.pdk_dashboard-page__outbound-grid__item__latency--red {
    color: var(--error-color-medium, red);
}

@media (max-width: 600px) {
    .pdk_dashboard-page__outbound-section__title-section__title {
        flex: 1 0 100%;
    }

    .pdk_dashboard-page__outbound-section__controls {
        flex: 1 0 100%;
    }

    .pdk_dashboard-page__outbound-section__controls > * {
        flex: 1 1 auto;
        min-width: 0;
    }

    .pdk_dashboard-page__outbound-list {
        max-height: 70vh;
    }

    .pdk_dashboard-page__outbound-row {
        flex-wrap: wrap;
        gap: 4px 6px;
        padding: 8px;
    }

    .pdk_dashboard-page__outbound-row__name {
        flex: 1 0 100%;
    }

    .pdk_dashboard-page__outbound-row__badge,
    .pdk_dashboard-page__outbound-row__badge-space {
        width: auto;
        min-width: 0;
        padding-left: 6px;
        padding-right: 6px;
    }

    .pdk_dashboard-page__outbound-row__badge-space {
        display: none;
    }
}

.pdk_dashboard-page__update-notice {
.pdk_dashboard-page__pin-guard {
    margin-top: 10px;
    display: grid;
    grid-row-gap: 4px;
    border: 2px var(--warn-color-medium, orange) solid;
}

.pdk_dashboard-page__update-notice__hint {
    opacity: 0.75;
    font-size: 0.9em;
}

.pdk_dashboard-page__subscription-info {
    margin-top: 6px;
    display: grid;
    grid-row-gap: 4px;
    font-size: 0.9em;
}

.pdk_dashboard-page__subscription-info__row {
    display: grid;
    grid-row-gap: 3px;
}

.pdk_dashboard-page__subscription-info__text {
    opacity: 0.85;
    overflow-wrap: anywhere;
}

.pdk_dashboard-page__subscription-info__text--exhausted {
    color: var(--error-color-medium, red);
    opacity: 1;
}

.pdk_dashboard-page__subscription-info__bar {
    height: 4px;
    border-radius: 2px;
    background: var(--ns-card-border, rgba(128, 128, 128, 0.3));
    overflow: hidden;
}

.pdk_dashboard-page__subscription-info__bar__fill {
    height: 100%;
    background: var(--success-color-medium, green);
}

.pdk_dashboard-page__subscription-info__bar__fill--high {
    background: var(--warn-color-medium, orange);
}
`;
