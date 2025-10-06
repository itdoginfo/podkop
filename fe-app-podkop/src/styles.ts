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

#cbi-podkop-main-_status > div {
    width: 100%;
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

/*@media (max-width: 440px) {*/
/*    .pdk_dashboard-page {*/
/*        --dashboard-grid-columns: 1;*/
/*    }*/
/*}*/

.pdk_dashboard-page__title-section {
    display: flex;
    align-items: center;
    justify-content: space-between;
    border: 2px var(--background-color-low) solid;
    border-radius: 4px;
    padding: 0 10px;
}

.pdk_dashboard-page__title-section__title {
    color: var(--text-color-high);
    font-weight: 700;
}

.pdk_dashboard-page__widgets-section {
    margin-top: 10px;
    display: grid;
    grid-template-columns: repeat(var(--dashboard-grid-columns), 1fr);
    grid-gap: 10px;
}

.pdk_dashboard-page__widgets-section__item {
    border: 2px var(--background-color-low) solid;
    border-radius: 4px;
    padding: 10px;
}

.pdk_dashboard-page__widgets-section__item__title {
    
}

.pdk_dashboard-page__widgets-section__item__row {

}

.pdk_dashboard-page__widgets-section__item__row--success .pdk_dashboard-page__widgets-section__item__row__value {
    color: var(--success-color-medium);
}

.pdk_dashboard-page__widgets-section__item__row--error .pdk_dashboard-page__widgets-section__item__row__value {
    color: var(--error-color-medium);
}

.pdk_dashboard-page__widgets-section__item__row__key {
    
}

.pdk_dashboard-page__widgets-section__item__row__value {

}

.pdk_dashboard-page__outbound-section {
    margin-top: 10px;
    border: 2px var(--background-color-low) solid;
    border-radius: 4px;
    padding: 10px;
}

.pdk_dashboard-page__outbound-section__title-section {
    display: flex;
    align-items: center;
    justify-content: space-between;
}

.pdk_dashboard-page__outbound-section__title-section__title {
    color: var(--text-color-high);
    font-weight: 700;
}

.pdk_dashboard-page__outbound-grid {
    margin-top: 5px;
    display: grid;
    grid-template-columns: repeat(var(--dashboard-grid-columns), 1fr);
    grid-gap: 10px;
}

.pdk_dashboard-page__outbound-grid__item {
    border: 2px var(--background-color-low) solid;
    border-radius: 4px;
    padding: 10px;
    transition: border 0.2s ease;
}

.pdk_dashboard-page__outbound-grid__item--selectable {
    cursor: pointer;
}

.pdk_dashboard-page__outbound-grid__item--selectable:hover {
    border-color: var(--primary-color-high);
}

.pdk_dashboard-page__outbound-grid__item--active {
    border-color: var(--success-color-medium);
}

.pdk_dashboard-page__outbound-grid__item__footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-top: 10px;
}

.pdk_dashboard-page__outbound-grid__item__type {
    
}

.pdk_dashboard-page__outbound-grid__item__latency--empty {
    color: var(--primary-color-low);
}

.pdk_dashboard-page__outbound-grid__item__latency--green {
    color: var(--success-color-medium);
}

.pdk_dashboard-page__outbound-grid__item__latency--yellow {
    color: var(--warn-color-medium);
}

.pdk_dashboard-page__outbound-grid__item__latency--red {
    color: var(--error-color-medium);
}

.centered {
    display: flex;
    align-items: center;
    justify-content: center;
}

/* Skeleton styles*/
.skeleton {
    background-color: var(--background-color-low, #e0e0e0);
    border-radius: 4px;
    position: relative;
    overflow: hidden;
}

.skeleton::after {
    content: '';
    position: absolute;
    top: 0;
    left: -150%;
    width: 150%;
    height: 100%;
    background: linear-gradient(
            90deg,
            transparent,
            rgba(255, 255, 255, 0.4),
            transparent
    );
    animation: skeleton-shimmer 1.6s infinite;
}

@keyframes skeleton-shimmer {
    100% {
        left: 150%;
    }
}
`;
