'use strict';
'require view';
'require form';
'require network';
'require view.podkop.networkUtils as networkUtils';
'require view.podkop.sections.config as config';
'require view.podkop.sections.diagnostic as diagnostic';
'require view.podkop.sections.additional as additional';

return view.extend({
    async render() {
        document.head.insertAdjacentHTML('beforeend', `
            <style>
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
            </style>
        `);

        const m = new form.Map('podkop', _(''), null, ['main', 'extra']);

        // Main Section
        const mainSection = m.section(form.TypedSection, 'main');
        mainSection.anonymous = true;
        config.createConfigSection(mainSection, m, network);

        // Extra Section
        const extraSection = m.section(form.TypedSection, 'extra', _('Extra configurations'));
        extraSection.anonymous = false;
        extraSection.addremove = true;
        extraSection.addbtntitle = _('Add Section');
        extraSection.multiple = true;
        config.createConfigSection(extraSection, m, network);

        // Additional Settings Tab (main section)
        additional.createAdditionalSection(mainSection, network);

        // Diagnostics Tab (main section)
        diagnostic.createDiagnosticsSection(mainSection);

        const map_promise = m.render().then(node => diagnostic.setupDiagnosticsEventHandlers(node));

        return map_promise;
    }
});