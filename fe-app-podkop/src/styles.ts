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

#cbi-podkop-dashboard-_mount_node > div {
    width: 100%;
}

#cbi-podkop-dashboard > h3 {
    display: none;
}

#cbi-podkop-settings > h3 {
    display: none;
}

#cbi-podkop-section > h3:nth-child(1) {
    display: none;
}

#cbi-podkop-diagnostic > h3 {
    display: none;
}

.cbi-section-remove {
    margin-bottom: -32px;
}

.cbi-value {
    margin-bottom: 20px !important;
}

/* Dashboard styles */

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
    grid-template-columns: repeat(var(--dashboard-grid-columns), 1fr);
    grid-gap: 10px;
}

.pdk_dashboard-page__widgets-section__item {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
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

.pdk_dashboard-page__outbound-section {
    margin-top: 10px;
    border: 2px var(--background-color-low, lightgray) solid;
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
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    padding: 10px;
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

/* Lucide spinner animate */
.lucide-rotate {
    animation: spin 1s linear infinite;
}

@keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
}

#cbi-podkop-diagnostic-_mount_node > div {
    width: 100%;
}

.pdk_diagnostic-page__checks {
    display: grid;
    grid-template-columns: 1fr;
    grid-row-gap: 10px;
}

.pdk_diagnostic_alert {
    border: 2px var(--background-color-low, lightgray) solid;
    border-radius: 4px;
    
    display: grid;
    grid-template-columns: 24px 1fr;    
    grid-column-gap: 10px;
    align-items: center;
    padding: 10px;
}

.pdk_diagnostic_alert--loading {
    border: 2px var(--primary-color-high, dodgerblue) solid;
}

.pdk_diagnostic_alert--warning {
    border: 2px var(--warn-color-medium, orange) solid;
    color: var(--warn-color-medium, orange);
}

.pdk_diagnostic_alert--error {
    border: 2px var(--error-color-medium, red) solid;
    color: var(--error-color-medium, red);
}

.pdk_diagnostic_alert--success {
    border: 2px var(--success-color-medium, green) solid;
    color: var(--success-color-medium, green);
}

.pdk_diagnostic_alert--skipped {}

.pdk_diagnostic_alert__icon {}

.pdk_diagnostic_alert__content {}

.pdk_diagnostic_alert__title {
    display: block;
}

.pdk_diagnostic_alert__description {}

.pdk_diagnostic_alert__summary {
    margin-top: 10px;
}

.pdk_diagnostic_alert__summary__item {
    display: grid;
    grid-template-columns: auto 1fr;
    grid-column-gap: 10px;
}

.pdk_diagnostic_alert__summary__item--error {
    color: var(--error-color-medium, red);
}

.pdk_diagnostic_alert__summary__item--warning {
    color: var(--warn-color-medium, orange);
}

.pdk_diagnostic_alert__summary__item--success {
    color: var(--success-color-medium, green);
}

`;
